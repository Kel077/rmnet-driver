#!/bin/sh
# Measures throughput on one network port, from the port's own byte counters, under a data budget.
#
#   scripts/measure.sh <interface> down|up
#   scripts/measure.sh --analyse down|up <samples file>    (re-prints the figures of a saved run)
#
# down: 4 parallel downloads from mensura.cdn-apple.com/api/v1/gm/large, stopped when 50,000,000
#       bytes have arrived on the port since the start, or after 8 s, whichever is first. Each
#       download also stops itself at 15,000,000 bytes (curl's output goes through `head -c`), so
#       a run cannot pass 60,000,000 bytes of payload even if the watchdog dies. A stream that
#       reaches its own limit before the watchdog stops the run ends early, and the run then carries
#       fewer streams; the script prints how many streams ended that way, so a figure affected by it
#       can be recognised.
# up:   4 parallel uploads to .../gm/slurp, stopped when 10,000,000 bytes have left the port,
#       or after 6 s. Each upload sends one 4,000,000-byte body, so 16 MB is the most it can send.
#
# Nothing is resolved through the system resolver: every transfer is bound to the port with
# --interface and pinned to one server address with --resolve. Proxies are bypassed (--noproxy),
# and /usr/bin/curl is used because the shell's default curl does not bind.
#
# A watchdog samples `netstat -I <interface> -b -n` every 0.25 s. The bytes moved are accumulated
# from sample to sample: a counter that goes down (the interface was recreated and its counters
# restarted) counts as a reset, and what it shows after the reset is added. The samples file,
# build/logs/measure-<time>-<dir>.samples, holds "seconds since start, bytes in, bytes out" moved
# since the start. The figures:
#   gate figure  the mean rate from 1.0 s after traffic starts (the first sample with more than
#                100,000 bytes moved in the measured direction) to the last sample before the stop;
#   best 1 s     the highest rate over any span of at least 1.0 s between two samples.
#
# The cellular data is metered. Every run appends "time direction bytes-in bytes-out" to the usage
# file (build/installed/measure-usage.log, which `make clean` keeps; MEASURE_USAGE_FILE overrides
# it on lo0 only), also when it fails or is interrupted. If the counters cannot be read at the end, the run is
# charged at least its reservation in the measured direction. A run refuses to start (exit 2) if a
# line of the usage file is not "<time> <down|up> <bytes in> <bytes out>" with non-negative whole
# numbers, or if the recorded total plus this run's reservation (its stop threshold plus 10,000,000
# bytes for what arrives after the stop) would pass 300,000,000 bytes. It warns when a run moved more
# than 60,000,000 bytes. The run fails if fewer than 1,000,000 bytes crossed the port in the
# measured direction (curl did not go through it).
#
# For testing with no network: MEASURE_TEST_PORT=<port> sends every transfer to 127.0.0.1:<port>
# over plain HTTP, MEASURE_NETSTAT=<program> replaces netstat, and MEASURE_USAGE_FILE=<file> replaces
# the usage file. Each is accepted only with the interface lo0 (any other interface: exit 2 before
# anything is touched), and the script prints a line naming each one that is active.
set -u

cd "$(dirname "$0")/.." || exit 1

BUDGET=300000000
MARGIN=10000000
WARN_BYTES=60000000
MIN_BYTES=1000000
HOST=mensura.cdn-apple.com
ADDR=111.132.43.41
PORT=443
SCHEME=https
if [ -n "${MEASURE_TEST_PORT:-}" ]; then
  ADDR=127.0.0.1
  PORT=$MEASURE_TEST_PORT
  SCHEME=http
fi
NETSTAT=${MEASURE_NETSTAT:-/usr/sbin/netstat}
STREAM_BYTES=15000000
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
  down) STOP_BYTES=50000000 STOP_SECS=8 URL="$SCHEME://$HOST:$PORT/api/v1/gm/large" ;;
  up) STOP_BYTES=10000000 STOP_SECS=6 URL="$SCHEME://$HOST:$PORT/api/v1/gm/slurp" ;;
  *) die "direction must be down or up" ;;
esac

# The test settings change where the bytes are counted, sent or recorded, so they are refused on any
# interface but lo0, before the usage file is touched or anything is sent.
for v in MEASURE_NETSTAT MEASURE_TEST_PORT MEASURE_USAGE_FILE; do
  eval "val=\${$v:-}"
  [ -n "$val" ] || continue
  if [ "$IFACE" != lo0 ]; then
    echo "measure: REFUSED: $v is set ($v=$val); test settings are accepted only with the interface lo0" >&2
    exit 2
  fi
  echo "test setting:     $v=$val"
done

# "bytes-in bytes-out" of the interface, from its link-level line. Counted from the end of the line
# (Ibytes Opkts Oerrs Obytes Coll), because an interface with no link address (lo0) has no Address column.
counters() {
  "$NETSTAT" -I "$IFACE" -b -n 2>/dev/null |
    awk -v i="$IFACE" '$1 == i && $3 ~ /^<Link#/ { print $(NF - 4), $(NF - 1); found = 1; exit } END { if (!found) exit 1 }'
}

now() {
  date +%s.%N
}

# The recorded total of a usage file, on stdout. Fails, naming the lines, if any line other than a
# comment (starting with #) is not "<time> <down|up> <bytes in> <bytes out>" with non-negative
# whole numbers.
usage_total() {
  awk '
    /^#/ { next }
    {
      if (NF != 4 || ($2 != "down" && $2 != "up") || $3 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/) {
        printf "measure: %s line %d is malformed: \"%s\"\n", FILENAME, NR, $0 > "/dev/stderr"
        bad = 1
        next
      }
      s += $3 + $4
    }
    END { if (bad) exit 3; printf "%.0f\n", s }' "$1"
}

# The budget check, before anything touches the network.
mkdir -p "$(dirname "$USAGE")" || die "cannot create the directory of $USAGE"
if [ ! -e "$USAGE" ]; then
  echo "" >&2
  echo "measure: NOTE: the usage file $USAGE does not exist; creating it EMPTY, so the recorded" >&2
  echo "measure: total starts at 0. If measurements were recorded before, restore the file first." >&2
  echo "" >&2
  : >"$USAGE" || die "cannot create $USAGE"
fi
if ! used=$(usage_total "$USAGE"); then
  echo "measure: REFUSED: the usage file $USAGE cannot be trusted (see above); fix it by hand" >&2
  exit 2
fi
reserve=$((STOP_BYTES + MARGIN))
echo "usage file: $USAGE, recorded total $used bytes; this run reserves $reserve; budget $BUDGET"
if [ $((used + reserve)) -gt $BUDGET ]; then
  echo "measure: REFUSED: $used recorded + $reserve for this run would pass $BUDGET bytes" >&2
  exit 2
fi

base=$(counters) || die "no interface $IFACE ($NETSTAT -I $IFACE -b -n shows no link line)"

mkdir -p build/logs
stamp=$(date +%Y%m%d-%H%M%S)
SAMPLES="build/logs/measure-$stamp-$DIR.samples"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/measure.XXXXXX") || die "cannot create a temporary directory"

pids=
recorded=0
started=0
signalled=0

# The bytes moved since the start, accumulated from the last good sample (prev_*). A counter that
# goes down was reset (the interface was recreated): what it shows now was all moved since.
set -- $base
prev_in=$1
prev_out=$2
acc_in=0
acc_out=0
resets=0
last_ok=1 # whether the latest attempt to read the counters succeeded

advance() {
  c=$(counters) || {
    last_ok=0
    return 1
  }
  last_ok=1
  set -- $c
  if [ "$1" -lt "$prev_in" ] || [ "$2" -lt "$prev_out" ]; then
    resets=$((resets + 1))
    acc_in=$((acc_in + $1))
    acc_out=$((acc_out + $2))
  else
    acc_in=$((acc_in + $1 - prev_in))
    acc_out=$((acc_out + $2 - prev_out))
  fi
  prev_in=$1
  prev_out=$2
  return 0
}

# Kills this run's transfers: every curl whose arguments name the run's own temporary directory
# (this also catches one started just before a signal, before its pid was kept), then waits for
# the subshells that ran them.
stop_transfers() {
  pkill -TERM -f "$WORK/" 2>/dev/null
  for p in $pids; do wait "$p" 2>/dev/null; done
  pids=
}

# Appends this run to the usage file once, from a final reading of the counters. If that reading
# fails, the run is charged at least its reservation in the measured direction, since the bytes
# after the last good sample are unknown. Signals are ignored from here on: once recorded is set,
# a signal before the append would exit through cleanup, whose record() would then return early
# and leave the run unrecorded.
record() {
  [ "$recorded" -eq 0 ] && [ "$started" -eq 1 ] || return 0
  trap '' INT TERM HUP
  recorded=1
  advance
  rec_in=$acc_in
  rec_out=$acc_out
  if [ "$last_ok" -eq 0 ]; then
    if [ "$DIR" = down ] && [ "$rec_in" -lt "$reserve" ]; then rec_in=$reserve; fi
    if [ "$DIR" = up ] && [ "$rec_out" -lt "$reserve" ]; then rec_out=$reserve; fi
    echo "measure: WARNING: the counters could not be read at the end; charging in $rec_in, out $rec_out" >&2
  fi
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $DIR $rec_in $rec_out" >>"$USAGE"
}

cleanup() {
  trap '' INT TERM HUP # a second signal must not cut the usage record short
  if [ "$started" -eq 1 ]; then
    stop_transfers
    sleep 1 # let what was in flight arrive before the usage record
  fi
  record
  rm -rf "$WORK"
}
trap cleanup EXIT
# A signal ends the run with 128 plus its number: INT 130, TERM 143, HUP 129.
interrupted() {
  echo "measure: interrupted" >&2
  exit "$1"
}
on_signals() {
  trap 'interrupted 130' INT
  trap 'interrupted 143' TERM
  trap 'interrupted 129' HUP
}
on_signals

if [ "$DIR" = up ]; then
  dd if=/dev/zero of="$WORK/body" bs=1000000 count=4 2>/dev/null || die "cannot write the upload body"
fi

CURL="/usr/bin/curl --noproxy * --interface $IFACE --resolve $HOST:$PORT:$ADDR -s --max-time $STOP_SECS"
set -f # keep the * in $CURL from being expanded
# A signal while the transfers start is held until all of them are known.
trap 'signalled=130' INT
trap 'signalled=143' TERM
trap 'signalled=129' HUP
started=1
t_start=$(now)
echo "0 0 0" >"$SAMPLES"
for k in 1 2 3 4; do
  if [ "$DIR" = down ]; then
    ($CURL --stderr "$WORK/curl$k.err" -o - "$URL" | head -c $STREAM_BYTES | wc -c >"$WORK/stream$k") &
  else
    ($CURL --stderr "$WORK/curl$k.err" -o /dev/null -H 'Content-Type: application/octet-stream' \
      --data-binary "@$WORK/body" "$URL") &
  fi
  pids="$pids $!"
done
set +f
on_signals
[ "$signalled" -eq 0 ] || interrupted "$signalled"

reason=
t=0
while :; do
  sleep 0.25
  advance || {
    reason="the interface disappeared"
    break
  }
  t=$(awk -v a="$t_start" -v b="$(now)" 'BEGIN { printf "%.3f", b - a }')
  echo "$t $acc_in $acc_out" >>"$SAMPLES"
  if [ "$DIR" = down ]; then moved=$acc_in; else moved=$acc_out; fi
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
at_limit=0
if [ "$DIR" = down ]; then
  for k in 1 2 3 4; do
    n=$(cat "$WORK/stream$k" 2>/dev/null | tr -d ' ')
    [ "${n:-0}" -ge $STREAM_BYTES ] && at_limit=$((at_limit + 1))
  done
fi
sleep 1 # let what was in flight at the stop arrive, so the usage record includes it
record

set -- $base
echo "interface:        $IFACE ($DIR)"
echo "before:           in $1 bytes, out $2 bytes"
if [ "$last_ok" -eq 1 ]; then
  echo "after:            in $prev_in bytes, out $prev_out bytes (1 s after the stop)"
else
  echo "after:            counters unreadable; last good reading in $prev_in bytes, out $prev_out bytes"
fi
[ "$resets" -eq 0 ] || echo "counter resets:   $resets (the interface was recreated during the run)"
echo "moved:            in $acc_in bytes, out $acc_out bytes"
echo "recorded:         in $rec_in bytes, out $rec_out bytes"
echo "duration:         $duration s to the last sample; stopped by $reason"
if [ "$DIR" = down ]; then
  echo "streams at limit: $at_limit of 4 ended at their own $STREAM_BYTES-byte limit before the stop"
fi
echo "samples:          $SAMPLES"
analyse "$DIR" "$SAMPLES"
total=$(usage_total "$USAGE") || total="unreadable"
echo "recorded total:   $total of $BUDGET bytes"

if [ $((rec_in + rec_out)) -gt $WARN_BYTES ]; then
  echo "" >&2
  echo "measure: WARNING: this run moved $((rec_in + rec_out)) bytes, more than $WARN_BYTES" >&2
  echo "" >&2
fi
if [ "$DIR" = down ]; then measured=$acc_in; else measured=$acc_out; fi
if [ "$measured" -lt $MIN_BYTES ]; then
  die "FAILED: only $measured bytes crossed $IFACE in the measured direction; curl did not go through it"
fi
exit 0
