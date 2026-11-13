#!/bin/sh
# Measures throughput on one network port, from the port's own byte counters, under a data budget.
#
#   scripts/measure.sh <interface> down|up
#   scripts/measure.sh --analyse down|up <samples file>    (re-prints the figures of a saved run)
#
# down: 4 parallel downloads from mensura.cdn-apple.com/api/v1/gm/large, stopped when 50,000,000
#       bytes have arrived on the port since the start, or after 8 s, whichever is first.
# up:   4 parallel uploads to .../gm/slurp, stopped when 10,000,000 bytes have left the port,
#       or after 6 s. Each upload sends one 4,000,000-byte body, so 16 MB is the most it can send.
#
# Nothing is resolved through the system resolver: every transfer is bound to the port with
# --interface and pinned to one server address with --resolve. Proxies are bypassed (--noproxy),
# and /usr/bin/curl is used because the shell's default curl does not bind.
#
# A watchdog samples `netstat -I <interface> -b -n` every 0.25 s into build/logs/measure-<time>.samples
# ("seconds since start, bytes in, bytes out"). The figures:
#   gate figure  the mean rate from 1.0 s after traffic starts (the first sample with more than
#                100,000 bytes moved in the measured direction) to the last sample before the stop;
#   best 1 s     the highest rate over any span of at least 1.0 s between two samples.
#
# The cellular data is metered. Every run appends "time direction bytes-in bytes-out" to the usage
# file (build/installed/measure-usage.log, which `make clean` keeps; MEASURE_USAGE_FILE overrides
# it). A run refuses to start if the recorded total plus this run's reservation (its stop threshold
# plus 10,000,000 bytes for what arrives after the stop) would pass 300,000,000 bytes, and warns
# when a run moved more than 60,000,000 bytes. The run fails if fewer than 1,000,000 bytes crossed
# the port in the measured direction (curl did not go through it).
set -u

cd "$(dirname "$0")/.." || exit 1

BUDGET=300000000
MARGIN=10000000
WARN_BYTES=60000000
MIN_BYTES=1000000
HOST=mensura.cdn-apple.com
ADDR=111.132.43.41
PORT=443
# For testing the script with no network: MEASURE_TEST_PORT=<port> sends every transfer to
# 127.0.0.1:<port> instead (use it with the interface lo0).
if [ -n "${MEASURE_TEST_PORT:-}" ]; then
  ADDR=127.0.0.1
  PORT=$MEASURE_TEST_PORT
fi
USAGE=${MEASURE_USAGE_FILE:-build/installed/measure-usage.log}

die() {
  echo "measure: $*" >&2
  exit 1
}

# Prints the figures for a samples file. $1 is the direction, $2 the file. The first line of the
# file is the baseline at time 0, the last line the last sample before the stop.
analyse() {
  awk -v dir="$1" '
    BEGIN { n = 0 }
    { t[n] = $1; m[n] = (dir == "down") ? $2 : $3; n++ }
    END {
      if (n < 2) { print "gate figure:      n/a (fewer than two samples)"; exit }
      m0 = m[0]
      for (i = 0; i < n; i++) m[i] -= m0
      s = -1
      for (i = 0; i < n; i++) if (m[i] > 100000) { s = i; break }
      if (s < 0) {
        print "gate figure:      n/a (traffic never passed 100,000 bytes)"
      } else {
        a = -1
        for (i = s; i < n; i++) if (t[i] >= t[s] + 1.0) { a = i; break }
        b = n - 1
        printf "traffic started:  %.2f s (first sample over 100,000 bytes)\n", t[s]
        if (a < 0 || a >= b) {
          print "gate figure:      n/a (no sample after the 1.0 s mark: the part after 1.0 s is shorter than 1.0 s)"
        } else {
          span = t[b] - t[a]
          printf "gate figure:      %.1f Mbit/s (%d bytes from %.2f s to %.2f s, %.2f s)\n",
            (m[b] - m[a]) * 8 / span / 1e6, m[b] - m[a], t[a], t[b], span
          if (span < 1.0) print "                  NOTE: the part after 1.0 s is shorter than 1.0 s"
        }
      }
      best = -1
      for (i = 0; i < n; i++)
        for (j = i + 1; j < n; j++)
          if (t[j] - t[i] >= 1.0) {
            r = (m[j] - m[i]) * 8 / (t[j] - t[i]) / 1e6
            if (r > best) { best = r; bi = i; bj = j }
            break
          }
      if (best < 0) print "best 1 s window:  n/a (the run is shorter than 1.0 s)"
      else printf "best 1 s window:  %.1f Mbit/s (%.2f s to %.2f s)\n", best, t[bi], t[bj]
    }' "$2"
}

if [ "${1:-}" = "--analyse" ]; then
  [ $# -eq 3 ] || die "usage: $0 --analyse down|up <samples file>"
  case $2 in down | up) ;; *) die "direction must be down or up" ;; esac
  [ -r "$3" ] || die "cannot read $3"
  analyse "$2" "$3"
  exit 0
fi

[ $# -eq 2 ] || die "usage: $0 <interface> down|up"
IFACE=$1
DIR=$2
case $DIR in
  down) STOP_BYTES=50000000 STOP_SECS=8 URL="https://$HOST:$PORT/api/v1/gm/large" ;;
  up) STOP_BYTES=10000000 STOP_SECS=6 URL="https://$HOST:$PORT/api/v1/gm/slurp" ;;
  *) die "direction must be down or up" ;;
esac

# "bytes-in bytes-out" of the interface, from its link-level line. Counted from the end of the line
# (Ibytes Opkts Oerrs Obytes Coll), because an interface with no link address (lo0) has no Address column.
counters() {
  netstat -I "$IFACE" -b -n 2>/dev/null |
    awk -v i="$IFACE" '$1 == i && $3 ~ /^<Link#/ { print $(NF - 4), $(NF - 1); found = 1; exit } END { if (!found) exit 1 }'
}

now() {
  date +%s.%N
}

# The budget check, before anything touches the network.
mkdir -p "$(dirname "$USAGE")" || die "cannot create the directory of $USAGE"
[ -e "$USAGE" ] || : >"$USAGE" || die "cannot create $USAGE"
used=$(awk '$1 !~ /^#/ && NF >= 4 { s += $3 + $4 } END { printf "%d", s }' "$USAGE") ||
  die "cannot read $USAGE"
reserve=$((STOP_BYTES + MARGIN))
echo "usage file: $USAGE, recorded total $used bytes; this run reserves $reserve; budget $BUDGET"
if [ $((used + reserve)) -gt $BUDGET ]; then
  echo "measure: REFUSED: $used recorded + $reserve for this run would pass $BUDGET bytes" >&2
  exit 2
fi

base=$(counters) || die "no interface $IFACE (netstat -I $IFACE -b -n shows no link line)"

mkdir -p build/logs
stamp=$(date +%Y%m%d-%H%M%S)
SAMPLES="build/logs/measure-$stamp-$DIR.samples"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/measure.XXXXXX") || die "cannot create a temporary directory"

pids=
recorded=0
started=0

stop_transfers() {
  for p in $pids; do kill "$p" 2>/dev/null; done
  for p in $pids; do wait "$p" 2>/dev/null; done
  pids=
}

# Appends this run to the usage file once, from the counters now.
record() {
  [ "$recorded" -eq 0 ] && [ "$started" -eq 1 ] || return 0
  recorded=1
  after=$(counters) || after=$base
  set -- $base $after
  in_moved=$(($3 - $1))
  out_moved=$(($4 - $2))
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $DIR $in_moved $out_moved" >>"$USAGE"
}

cleanup() {
  if [ -n "$pids" ]; then
    stop_transfers
    sleep 1 # as below: let what was in flight arrive before the usage record
  fi
  record
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'echo "measure: interrupted" >&2; exit 130' INT TERM HUP

if [ "$DIR" = up ]; then
  dd if=/dev/zero of="$WORK/body" bs=1000000 count=4 2>/dev/null || die "cannot write the upload body"
fi

CURL="/usr/bin/curl --noproxy * --interface $IFACE --resolve $HOST:$PORT:$ADDR -s -o /dev/null --max-time $STOP_SECS"
set -f # keep the * in $CURL from being expanded
started=1
t_start=$(now)
echo "0 $base" >"$SAMPLES"
for k in 1 2 3 4; do
  if [ "$DIR" = down ]; then
    $CURL "$URL" &
  else
    $CURL -H 'Content-Type: application/octet-stream' --data-binary "@$WORK/body" "$URL" &
  fi
  pids="$pids $!"
done
set +f

set -- $base
base_in=$1
base_out=$2
reason=
t=0
while :; do
  sleep 0.25
  c=$(counters) || {
    reason="the interface disappeared"
    break
  }
  t=$(awk -v a="$t_start" -v b="$(now)" 'BEGIN { printf "%.3f", b - a }')
  echo "$t $c" >>"$SAMPLES"
  set -- $c
  if [ "$DIR" = down ]; then moved=$(($1 - base_in)); else moved=$(($2 - base_out)); fi
  if [ "$moved" -ge "$STOP_BYTES" ]; then
    reason="byte cap ($STOP_BYTES)"
    break
  fi
  if awk -v t="$t" -v s="$STOP_SECS" 'BEGIN { exit !(t >= s) }'; then
    reason="time limit (${STOP_SECS} s)"
    break
  fi
  alive=0
  for p in $pids; do kill -0 "$p" 2>/dev/null && alive=1; done
  if [ "$alive" -eq 0 ]; then
    reason="all transfers ended"
    break
  fi
done
stop_transfers
duration=$t
sleep 1 # let what was in flight at the stop arrive, so the usage record includes it
after=$(counters) || after=$base
record

set -- $base $after
in_moved=$(($3 - $1))
out_moved=$(($4 - $2))
echo "interface:        $IFACE ($DIR)"
echo "before:           in $1 bytes, out $2 bytes"
echo "after:            in $3 bytes, out $4 bytes (1 s after the stop)"
echo "moved:            in $in_moved bytes, out $out_moved bytes"
echo "duration:         $duration s to the last sample; stopped by $reason"
echo "samples:          $SAMPLES"
analyse "$DIR" "$SAMPLES"
total=$(awk '$1 !~ /^#/ && NF >= 4 { s += $3 + $4 } END { printf "%d", s }' "$USAGE")
echo "recorded total:   $total of $BUDGET bytes"

if [ $((in_moved + out_moved)) -gt $WARN_BYTES ]; then
  echo "" >&2
  echo "measure: WARNING: this run moved $((in_moved + out_moved)) bytes, more than $WARN_BYTES" >&2
  echo "" >&2
fi
if [ "$DIR" = down ]; then measured=$in_moved; else measured=$out_moved; fi
if [ "$measured" -lt $MIN_BYTES ]; then
  die "FAILED: only $measured bytes crossed $IFACE in the measured direction; curl did not go through it"
fi
exit 0
