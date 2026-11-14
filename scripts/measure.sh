#!/bin/sh
# Measures throughput on one network port, from the port's own byte counters, under a data budget.
#
#   scripts/measure.sh <interface> down|up|down-long|up-long|both
#   scripts/measure.sh --analyse down|up|down-long|up-long|both <samples file>
#                                         (re-prints the figures of a saved run)
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
# down-long: the down transfer, stopped when 320,000,000 bytes have arrived on the port, or after
#       8 s. The watchdog's samples are about 0.28 s apart in practice, so at 50 MB a second a run
#       can pass the threshold by about 14,000,000 bytes at the sample that stops it, and up to about
#       16,000,000 more is still in flight after the stop: about 350,000,000 in all. Each download
#       stops itself at 90,000,000 bytes, so a run cannot pass 360,000,000 bytes of payload even if
#       the watchdog dies (about 390,000,000 to 400,000,000 at the port: curl reads past `head -c` by
#       up to its socket buffer, and headers add 3 to 4 percent); streams that end at that limit are
#       counted as in down.
# up-long: the up transfer, stopped when 60,000,000 bytes have left the port, or after 8 s. Each
#       upload sends one 20,000,000-byte body, so 80 MB of payload is the most it can send (about
#       83 MB at the port).
# both: the down and up transfers at the same time under one watchdog, to show whether a busy
#       uplink slows a download: 4 downloads, each stopping itself at 40,000,000 bytes, and 4
#       uploads, each sending one 15,000,000-byte body, stopped when 150,000,000 bytes have arrived
#       on the port, or 50,000,000 bytes have left it, or after 8 s, whichever is first. At this
#       link's rates (about 20 MB a second in, 7 out), a run can pass 150,000,000 in by about
#       6,000,000 at the sample that stops it, and up to about 16,000,000 more can still be in
#       flight after the stop (as in down-long): about 172,000,000 in. Out, the uploads cannot pass
#       their four bodies (60,000,000 bytes of payload, about 63,000,000 at the port), and the
#       bytes out also carry the download's acknowledgements (about 1 to 2 percent of the bytes
#       in, up to about 3,500,000) and any retransmissions: about 67,000,000 out. That is about
#       239,000,000 in all, under the reservation (250,000,000, below). If the watchdog dies, the
#       streams' own limits hold a run to about 160,000,000 bytes of payload in (more at the port,
#       as in down-long) and 60,000,000 out (plus the acknowledgements). Downloads that end at
#       their limit are counted as in down.
#
# Nothing is resolved through the system resolver: every transfer is bound to the port with
# --interface and pinned to one server address with --resolve. Proxies are bypassed (--noproxy),
# and /usr/bin/curl is used because the shell's default curl does not bind.
#
# A watchdog samples `netstat -I <interface> -b -n` every 0.25 s. The bytes moved are accumulated
# from sample to sample: a counter that goes down (the interface was recreated and its counters
# restarted) counts as a reset, and what it shows after the reset is added. The samples file,
# build/logs/measure-<time>-<mode>.samples, holds "seconds since start, bytes in, bytes out" moved
# since the start. The figures:
#   gate figure  the mean rate from 1.0 s after traffic starts (the first sample with more than
#                100,000 bytes moved in the measured direction) to the last sample before the stop;
#   best 1 s     the highest rate over any span of at least 1.0 s between two samples.
# both measures each direction: it prints these figures for the download, from the bytes in, and
# then for the upload, from the bytes out, each with its own start of traffic, from the same
# samples. Each direction's bytes include the other direction's acknowledgements: the bytes in
# carry the upload's (about 3 percent of the bytes out), the bytes out the download's (about 1 to
# 2 percent of the bytes in); the label line above each set of figures says so.
#
# The cellular data is metered. Every run appends "time direction bytes-in bytes-out" to the usage
# file (build/installed/measure-usage.log, which `make clean` keeps; MEASURE_USAGE_FILE overrides
# it on lo0 only), also when it fails or is interrupted; the direction is down or up (down-long is
# recorded as down, up-long as up, both as down, with its real bytes in and out). After the stop,
# the counters are sampled every 0.25 s until the measured direction (for both, each of the two)
# moves less than 100,000 bytes between two samples, for at most 6 s (data in an upload's send
# buffers keeps leaving for seconds after curl is killed), and only then read for the usage line;
# an interrupted run waits the same way. If the counters cannot be read at the end, the run is
# charged at least its reservation in the measured direction (both: at least 200,000,000 in, its
# in threshold plus the margin, and 50,000,000 out, its out threshold, which is its reservation in
# all). A run refuses to start (exit 2) if a line of the usage file is not
# "<time> <down|up> <bytes in> <bytes out>" with non-negative whole numbers, or if the recorded
# total plus this run's reservation (its stop threshold plus a margin for what arrives after the
# stop: 10,000,000 bytes for down and up, 40,000,000 for down-long, 25,000,000 for up-long; for
# both, its two stop thresholds plus 50,000,000, so 250,000,000) would pass 1,300,000,000 bytes.
# It warns when a run moved more than 60,000,000 bytes (down and up), 384,000,000 (down-long),
# 72,000,000 (up-long; for the long modes, the stop threshold plus 20 percent) or 250,000,000
# (both: its reservation), in and out together. The run fails if fewer than 1,000,000 bytes
# crossed the port in the measured direction (curl did not go through it). both checks each side
# on its own, since one direction's acknowledgements alone can pass 1,000,000 bytes in the other:
# the download fails if its four streams together delivered fewer than 1,000,000 bytes (their own
# counts), the upload if fewer than 1,000,000 bytes plus 3 percent of the bytes in left the port;
# the message names the side. A run killed outright (SIGKILL) records nothing and leaves its
# temporary directory (${TMPDIR:-/tmp}/measure.*) behind, with the upload body in it for up,
# up-long and both (up to 20,000,000 bytes).
#
# For testing with no network: MEASURE_TEST_PORT=<port> sends every transfer to 127.0.0.1:<port>
# over plain HTTP, MEASURE_NETSTAT=<program> replaces netstat, and MEASURE_USAGE_FILE=<file> replaces
# the usage file. Each is accepted only with the interface lo0 (any other interface: exit 2 before
# anything is touched), and the script prints a line naming each one that is active.
set -u

cd "$(dirname "$0")/.." || exit 1

BUDGET=1300000000
SETTLE_BYTES=100000 # after the stop: the counters have settled when they move less than this...
SETTLE_SECS=6       # ...between two samples 0.25 s apart, or after this long
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
USAGE=${MEASURE_USAGE_FILE:-build/installed/measure-usage.log}

die() {
  echo "measure: $*" >&2
  exit 1
}

# Prints the figures for a samples file. $1 is the direction (both: the download's figures, from
# the bytes in, then the upload's, from the bytes out, each under a label), $2 the file. The first
# line of the file is the baseline at time 0, the last line the last sample before the stop.
analyse() {
  if [ "$1" = both ]; then
    echo "download:         figures from the bytes in, which include the upload's acknowledgements (about 3 percent of the bytes out)"
    analyse down "$2"
    echo "upload:           figures from the bytes out, which include the download's acknowledgements (about 1 to 2 percent of the bytes in)"
    analyse up "$2"
    return
  fi
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

MODES="down|up|down-long|up-long|both"

if [ "${1:-}" = "--analyse" ]; then
  [ $# -eq 3 ] || die "usage: $0 --analyse $MODES <samples file>"
  case $2 in
    down | down-long) adir=down ;;
    up | up-long) adir=up ;;
    both) adir=both ;;
    *) die "mode must be one of $MODES" ;;
  esac
  [ -r "$3" ] || die "cannot read $3"
  analyse "$adir" "$3"
  exit 0
fi

[ $# -eq 2 ] || die "usage: $0 <interface> $MODES"
IFACE=$1
MODE=$2
# Per mode: the measured direction (DIR: down, up, or both for the two at once; also the usage
# line's direction word, except that both is recorded as down), the stop threshold (STOP_BYTES, on
# the bytes in for down and both, out for up; both also stops on STOP_OUT_BYTES out) and time limit,
# the margin added to the stop thresholds for the reservation, the warning threshold, and the
# per-stream limits: each download's byte limit (STREAM_BYTES) and each upload's body in millions
# of bytes (BODY_MB).
case $MODE in
  down) DIR=down STOP_BYTES=50000000 STOP_SECS=8 MARGIN=10000000 WARN_BYTES=60000000 STREAM_BYTES=15000000 ;;
  up) DIR=up STOP_BYTES=10000000 STOP_SECS=6 MARGIN=10000000 WARN_BYTES=60000000 BODY_MB=4 ;;
  down-long) DIR=down STOP_BYTES=320000000 STOP_SECS=8 MARGIN=40000000 WARN_BYTES=384000000 STREAM_BYTES=90000000 ;;
  up-long) DIR=up STOP_BYTES=60000000 STOP_SECS=8 MARGIN=25000000 WARN_BYTES=72000000 BODY_MB=20 ;;
  both) DIR=both STOP_BYTES=150000000 STOP_OUT_BYTES=50000000 STOP_SECS=8 MARGIN=50000000 WARN_BYTES=250000000 STREAM_BYTES=40000000 BODY_MB=15 ;;
  *) die "mode must be one of $MODES" ;;
esac
DOWN_URL="$SCHEME://$HOST:$PORT/api/v1/gm/large"
UP_URL="$SCHEME://$HOST:$PORT/api/v1/gm/slurp"

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
[ "$DIR" != both ] || reserve=$((STOP_BYTES + STOP_OUT_BYTES + MARGIN))
echo "usage file: $USAGE, recorded total $used bytes; this run reserves $reserve; budget $BUDGET"
if [ $((used + reserve)) -gt $BUDGET ]; then
  echo "measure: REFUSED: $used recorded + $reserve for this run would pass $BUDGET bytes" >&2
  exit 2
fi

base=$(counters) || die "no interface $IFACE ($NETSTAT -I $IFACE -b -n shows no link line)"

mkdir -p build/logs
stamp=$(date +%Y%m%d-%H%M%S)
SAMPLES="build/logs/measure-$stamp-$MODE.samples"
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

# Waits after the stop until the counters settle: samples them every 0.25 s until the measured
# direction (for both, each of the two) moves less than SETTLE_BYTES between two samples, for at
# most SETTLE_SECS, so that what was in flight (above all an upload's send buffers, which drain
# after curl is killed) is counted. Sets waited (seconds since the call) and settled (1 if they
# settled, 0 if not).
settle() {
  s_start=$(now)
  settled=0
  while :; do
    sleep 0.25
    s_in=$acc_in
    s_out=$acc_out
    advance || break
    # what the measured direction moved since the last sample; for both, the larger of the two
    case $DIR in
      down) s_moved=$((acc_in - s_in)) ;;
      up) s_moved=$((acc_out - s_out)) ;;
      both)
        s_moved=$((acc_in - s_in))
        [ $((acc_out - s_out)) -le $s_moved ] || s_moved=$((acc_out - s_out))
        ;;
    esac
    if [ $s_moved -lt $SETTLE_BYTES ]; then
      settled=1
      break
    fi
    awk -v a="$s_start" -v b="$(now)" -v m="$SETTLE_SECS" 'BEGIN { exit !(b - a >= m) }' && break
  done
  waited=$(awk -v a="$s_start" -v b="$(now)" 'BEGIN { printf "%.2f", b - a }')
}

# Appends this run to the usage file once, from a final reading of the counters. If that reading
# fails, the run is charged at least its reservation in the measured direction (both: at least its
# in threshold plus the margin in, and its out threshold out, which together are its reservation),
# since the bytes after the last good sample are unknown. The usage file's direction words are down
# and up: both is recorded as down, with its real bytes in and out. Signals are ignored from here
# on: once recorded is set,
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
    if [ "$DIR" = both ] && [ "$rec_in" -lt $((STOP_BYTES + MARGIN)) ]; then rec_in=$((STOP_BYTES + MARGIN)); fi
    if [ "$DIR" = both ] && [ "$rec_out" -lt "$STOP_OUT_BYTES" ]; then rec_out=$STOP_OUT_BYTES; fi
    echo "measure: WARNING: the counters could not be read at the end; charging in $rec_in, out $rec_out" >&2
  fi
  if [ "$DIR" = both ]; then rec_dir=down; else rec_dir=$DIR; fi
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $rec_dir $rec_in $rec_out" >>"$USAGE"
}

cleanup() {
  trap '' INT TERM HUP # a second signal must not cut the usage record short
  if [ "$started" -eq 1 ]; then
    stop_transfers
    [ "$recorded" -eq 1 ] || settle # let what was in flight arrive before the usage record
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

if [ "$DIR" != down ]; then
  dd if=/dev/zero of="$WORK/body" bs=1000000 count=$BODY_MB 2>/dev/null || die "cannot write the upload body"
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
  if [ "$DIR" != up ]; then
    ($CURL --stderr "$WORK/curl$k.err" -o - "$DOWN_URL" | head -c $STREAM_BYTES | wc -c >"$WORK/stream$k") &
    pids="$pids $!"
  fi
  if [ "$DIR" != down ]; then
    ($CURL --stderr "$WORK/curl-up$k.err" -o /dev/null -H 'Content-Type: application/octet-stream' \
      --data-binary "@$WORK/body" "$UP_URL") &
    pids="$pids $!"
  fi
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
  if [ "$DIR" = up ]; then moved=$acc_out; else moved=$acc_in; fi
  if [ "$moved" -ge "$STOP_BYTES" ]; then
    if [ "$DIR" = both ]; then reason="byte cap in ($STOP_BYTES)"; else reason="byte cap ($STOP_BYTES)"; fi
    break
  fi
  if [ "$DIR" = both ] && [ "$acc_out" -ge "$STOP_OUT_BYTES" ]; then
    reason="byte cap out ($STOP_OUT_BYTES)"
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
delivered=0 # what the four download streams delivered, from their own counts
if [ "$DIR" != up ]; then
  for k in 1 2 3 4; do
    n=$(cat "$WORK/stream$k" 2>/dev/null | tr -d ' ')
    [ "${n:-0}" -ge $STREAM_BYTES ] && at_limit=$((at_limit + 1))
    delivered=$((delivered + ${n:-0}))
  done
fi
settle # let what was in flight at the stop arrive, so the usage record includes it
record

set -- $base
echo "interface:        $IFACE ($MODE)"
echo "before:           in $1 bytes, out $2 bytes"
if [ "$last_ok" -eq 1 ]; then
  if [ "$settled" -eq 1 ]; then
    echo "after:            in $prev_in bytes, out $prev_out bytes ($waited s after the stop, once settled)"
  else
    echo "after:            in $prev_in bytes, out $prev_out bytes ($waited s after the stop, not settled)"
  fi
else
  echo "after:            counters unreadable; last good reading in $prev_in bytes, out $prev_out bytes"
fi
[ "$resets" -eq 0 ] || echo "counter resets:   $resets (the interface was recreated during the run)"
echo "moved:            in $acc_in bytes, out $acc_out bytes"
echo "recorded:         in $rec_in bytes, out $rec_out bytes"
echo "duration:         $duration s to the last sample; stopped by $reason"
if [ "$DIR" != up ]; then
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
# both: each side on its own, since one direction's acknowledgements alone can pass MIN_BYTES in
# the other. The download from what its streams delivered; the upload from the bytes out beyond what
# the download's acknowledgements make (about 1 to 2 percent of the bytes in; 3 percent allowed).
if [ "$DIR" = both ]; then
  failed=0
  if [ "$delivered" -lt $MIN_BYTES ]; then
    echo "measure: FAILED: download: the four streams delivered only $delivered bytes, fewer than $MIN_BYTES" >&2
    failed=1
  fi
  up_min=$((MIN_BYTES + acc_in * 3 / 100))
  if [ "$acc_out" -lt "$up_min" ]; then
    echo "measure: FAILED: upload: only $acc_out bytes left $IFACE, fewer than $up_min ($MIN_BYTES plus 3 percent of the $acc_in bytes in, for the download's acknowledgements)" >&2
    failed=1
  fi
  exit $failed
fi
if [ "$DIR" = down ]; then measured=$acc_in; else measured=$acc_out; fi
if [ "$measured" -lt $MIN_BYTES ]; then
  die "FAILED: only $measured bytes crossed $IFACE in the measured direction; curl did not go through it"
fi
exit 0
