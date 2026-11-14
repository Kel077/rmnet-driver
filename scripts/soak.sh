#!/bin/sh
# A soak of the RMNet port: light, steady traffic for a set time while the driver's state and its
# error and drop counters are sampled, ending in a pass or fail verdict.
#
#   scripts/soak.sh <interface> <minutes>
#   scripts/soak.sh lo0 <minutes> --usage-file <file> [--status-cmd <program>] [--period <seconds>]
#                                 [--pid-cmd <program>] [--route-cmd <program>]
#
# <minutes> may have a fraction (0.5 is 30 s); the run lasts that many minutes rounded to the second.
#
# Traffic, for the whole run, bound to the port:
#   ping  -i 0.5 -s 1000 -b <interface> 223.5.5.5
#   ping6 -i 0.5 -s 1000 -B <interface> 2400:3200::1
# about 8 KB a second in all. Each ping is given a count that matches the run's length, but the
# script stops both at the end (with INT, so they print their summaries): on the real port a ping
# started a moment after the clock does not reach its count by then. On lo0 the targets are
# 127.0.0.1 and ::1; on any other interface they are the two above and no argument changes them.
# Their output goes to build/logs/.
#
# Before anything is sent it refuses (exit 2) if the default route of either family goes out
# through the soaked interface (`route -n get default`, `route -n get -inet6 default`; a family with
# no default route is fine): the soak must carry only its own pings. Skipped on lo0 unless
# --route-cmd is given.
#
# Every 10 seconds one line is appended to build/logs/soak-<time>.csv: the time, the seconds since
# the start, the port's byte counters (as netstat shows them, and moved since the start), the status
# class, RMNetState, the counters listed in COUNTERS below (empty when the driver does not publish
# one), and driver_pid, the process ID of the driver (`pgrep -f io.rmnetdriver.RMNet.driver`; several
# are joined with ";"). The status comes from `RMNet status --json` and is one of three things, kept
# apart:
#   up            the status was read and properties.RMNetState is "up";
#   not-up        the status was read and the driver is attached but its state is not "up"
#                 (not-attached: the status was read and properties is empty, the driver is not attached);
#   unreadable    the command failed (exit status not 0), hung for STATUS_TIMEOUT seconds, printed no
#                 JSON object, printed an "error" key, or printed no "properties" object.
# Anything but up counts as "not up" for the early stop, and fails the verdict. After the pings have
# stopped one more sample is taken (not after a signal), in which RMNetPacketsHeld is judged.
#
# The data guard reads the port's counters about once a second, also while a status read is
# waiting. The run stops early, stopping both pings, when they show more than GUARD_BYTES moved since
# the start (in plus out), when the port's counters cannot be read (the interface went away, so the
# guard cannot work), when the status is not up for three samples in a row, or on INT, TERM or HUP.
#
# The verdict, one line "soak: PASS" or "soak: FAIL" and then each reason for a failure on its own
# line. PASS only if all of these hold:
#   - the run reached its full length;
#   - the status was up in every sample;
#   - every counter in COUNTERS but RMNetPacketsHeld, in every sample where the driver is attached and
#     the counter is present, has its value from the first sample;
#   - RMNetPacketsHeld (a gauge, not a counter) is 0 or absent in the sample after the pings stopped;
#   - driver_pid is the same in every sample (a driver restart fails even with every counter at 0);
#   - the port's byte counters never went down (the interface was never recreated);
#   - no two samples are more than twice PERIOD apart (the Mac did not sleep, nothing stalled);
#   - each ping lost at most 1 percent by its own summary, and sent at least 90 percent of the
#     packets its running time allows (one every 0.5 s);
#   - no new crash report whose name starts with io.rmnetdriver.RMNet.driver appeared in
#     /Library/Logs/DiagnosticReports or ~/Library/Logs/DiagnosticReports;
#   - the usage line was written.
# Exit 0 on PASS, 1 on FAIL, 2 when it refused to start.
#
# Data: the cellular data is metered. Before anything is sent it reads the usage file
# (build/installed/measure-usage.log, the file scripts/measure.sh keeps) with the same strict reader
# as measure.sh, and refuses (exit 2) if the file is missing or malformed, or if its recorded total
# plus GUARD_BYTES would pass BUDGET. Once the pings have started it appends exactly one line,
# "<UTC time> up <bytes in> <bytes out>", also when it stops early or is interrupted. If the counters
# cannot be read at the end, the line is raised to at least GUARD_BYTES in all. If the line cannot be
# written, it is printed to be added by hand, and the verdict fails.
#
# Testing with no network, each accepted only with the interface lo0 (any other interface: exit 2
# before the usage file is read or anything is sent), and each printed when active:
#   --usage-file <file>   the usage file to read and append to (required on lo0, so a test never
#                         writes into the real one; it must exist);
#   --status-cmd <prog>   run instead of the RMNet app, as `<prog> status --json`;
#   --period <seconds>    the sampling period instead of 10 (a whole number of seconds);
#   --pid-cmd <prog>      run instead of the pgrep, prints the driver's process IDs one per line;
#   --route-cmd <prog>    run instead of /sbin/route for the default-route check, which then also
#                         runs on lo0.
set -u

cd "$(dirname "$0")/.." || exit 1

# The owner's whole allowance for testing on the metered SIM, in bytes. This script has its own
# ceiling because measure.sh's 300,000,000 is nearly reached by what is recorded already.
BUDGET=400000000
GUARD_BYTES=40000000 # the most one soak may move; also its reservation against BUDGET
PERIOD=10            # seconds between samples
STATUS_TIMEOUT=15    # seconds before a status command that has not answered is killed
NOT_UP_STOP=3        # samples in a row not up that stop the run
MAX_LOSS=1           # percent, for each ping
MIN_SENT=90          # percent of the packets a ping's running time allows
STATUS_CMD=/Applications/RMNet.app/Contents/MacOS/RMNet
USAGE=build/installed/measure-usage.log
TARGET4=223.5.5.5
TARGET6=2400:3200::1
DRIVER_PROC=io.rmnetdriver.RMNet.driver
CRASH_PREFIX=io.rmnetdriver.RMNet.driver
CRASH_DIRS="/Library/Logs/DiagnosticReports $HOME/Library/Logs/DiagnosticReports"
NETSTAT=/usr/sbin/netstat
ROUTE=/sbin/route
PYTHON=/usr/bin/python3
COUNTERS="RMNetUsbBulkInErrors RMNetUsbBulkOutErrors RMNetUsbBulkOutTimeouts RMNetUsbRecoveries
RMNetRxDropNoPacket RMNetRxDropBadQmap RMNetTxDropBusy RMNetTxDropUsb RMNetTxDropRecovering
RMNetTimerArmFailures RMNetPacketsHeld"
COUNTERS=$(echo $COUNTERS) # one line, separated by single spaces
GAUGE=RMNetPacketsHeld     # judged only after the pings have stopped, not across the run

refuse() {
  echo "soak: REFUSED: $*" >&2
  exit 2
}

# --- Arguments. Every test option is refused off lo0 before anything is read or sent. ---

[ $# -ge 2 ] || refuse "usage: $0 <interface> <minutes> (and on lo0: --usage-file <file> [--status-cmd <program>] [--period <seconds>] [--pid-cmd <program>] [--route-cmd <program>])"
IFACE=$1
MINUTES=$2
shift 2
opt_usage= opt_status= opt_period= opt_pid= opt_route=
while [ $# -gt 0 ]; do
  case $1 in
    --usage-file | --status-cmd | --period | --pid-cmd | --route-cmd)
      [ $# -ge 2 ] || refuse "$1 needs a value"
      [ "$IFACE" = lo0 ] || refuse "$1 is a test option and is accepted only with the interface lo0"
      case $1 in
        --usage-file) opt_usage=$2 ;;
        --status-cmd) opt_status=$2 ;;
        --period) opt_period=$2 ;;
        --pid-cmd) opt_pid=$2 ;;
        --route-cmd) opt_route=$2 ;;
      esac
      shift 2
      ;;
    *) refuse "unknown argument: $1" ;;
  esac
done
case $IFACE in
  '' | -* | *[!A-Za-z0-9]*) refuse "not an interface name: '$IFACE'" ;;
esac
case $MINUTES in
  '' | *[!0-9.]* | *.*.* | .) refuse "minutes must be a number such as 30 or 0.5: '$MINUTES'" ;;
esac
DURATION=$(awk -v m="$MINUTES" 'BEGIN { printf "%d", m * 60 + 0.5 }')
[ "$DURATION" -ge 1 ] || refuse "the run must last at least one second"

check_routes=1
if [ "$IFACE" = lo0 ]; then
  [ -n "$opt_usage" ] || refuse "on lo0 --usage-file is required, so a test never writes into $USAGE"
  USAGE=$opt_usage
  TARGET4=127.0.0.1
  TARGET6=::1
  check_routes=0
  echo "test setting:   --usage-file $opt_usage"
  if [ -n "$opt_status" ]; then
    STATUS_CMD=$opt_status
    echo "test setting:   --status-cmd $opt_status"
  fi
  if [ -n "$opt_period" ]; then
    case $opt_period in '' | *[!0-9]* | 0*) refuse "--period must be a whole number of seconds, at least 1" ;; esac
    PERIOD=$opt_period
    echo "test setting:   --period $opt_period"
  fi
  [ -z "$opt_pid" ] || echo "test setting:   --pid-cmd $opt_pid"
  if [ -n "$opt_route" ]; then
    ROUTE=$opt_route
    check_routes=1
    echo "test setting:   --route-cmd $opt_route"
  fi
fi

# --- The data budget, before anything is sent. ---

# The recorded total of a usage file, on stdout; fails, naming the lines, if any line other than a
# comment (starting with #) is not "<time> <down|up> <bytes in> <bytes out>" with whole numbers.
# The same reader as scripts/measure.sh.
usage_total() {
  awk '
    /^#/ { next }
    {
      if (NF != 4 || ($2 != "down" && $2 != "up") || $3 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/) {
        printf "soak: %s line %d is malformed: \"%s\"\n", FILENAME, NR, $0 > "/dev/stderr"
        bad = 1
        next
      }
      s += $3 + $4
    }
    END { if (bad) exit 3; printf "%.0f\n", s }' "$1"
}

# A missing usage file is never created: on the real port it means the script runs from a checkout
# that does not hold the record.
[ -f "$USAGE" ] || refuse "the usage file $USAGE does not exist (is this the checkout that holds the record?)"
[ -w "$USAGE" ] || refuse "the usage file $USAGE cannot be written"
used=$(usage_total "$USAGE") || refuse "the usage file $USAGE cannot be trusted (see above); fix it by hand"
echo "usage file:     $USAGE, recorded total $used bytes; this run reserves $GUARD_BYTES; ceiling $BUDGET"
[ $((used + GUARD_BYTES)) -le $BUDGET ] ||
  refuse "$used recorded + $GUARD_BYTES for this run would pass $BUDGET bytes"

# --- The port, the routes and the status, still before anything is sent. ---

# "bytes-in bytes-out" of the interface, from its link-level line, counted from the end of the line
# (Ibytes Opkts Oerrs Obytes Coll), because lo0 has no Address column.
counters() {
  "$NETSTAT" -I "$IFACE" -b -n 2>/dev/null |
    awk -v i="$IFACE" '$1 == i && $3 ~ /^<Link#/ { print $(NF - 4), $(NF - 1); found = 1; exit } END { if (!found) exit 1 }'
}
base=$(counters) || refuse "no interface $IFACE ($NETSTAT -I $IFACE -b -n shows no link line)"

# The interface of a family's default route ($1 is empty for IPv4, -inet6 for IPv6), or nothing when
# that family has no default route.
default_route_iface() {
  "$ROUTE" -n get $1 default 2>/dev/null | awk '$1 == "interface:" { print $2; exit }'
}
if [ "$check_routes" -eq 1 ]; then
  for fam in "" -inet6; do
    ri=$(default_route_iface "$fam")
    if [ "$fam" = "" ]; then name=IPv4; else name=IPv6; fi
    echo "default route:  $name ${ri:-none}"
    [ "$ri" != "$IFACE" ] ||
      refuse "the $name default route goes out through $IFACE, so other traffic would cross it; nothing was sent"
  done
fi

[ -x "$STATUS_CMD" ] || refuse "the status command $STATUS_CMD is not an executable file"
[ -x "$PYTHON" ] || refuse "$PYTHON is missing; it reads the status JSON"

mkdir -p build/logs || refuse "cannot create build/logs"
stamp=$(date +%Y%m%d-%H%M%S)
CSV="build/logs/soak-$stamp.csv"
PING4_LOG="build/logs/soak-$stamp-ping.log"
PING6_LOG="build/logs/soak-$stamp-ping6.log"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/soak.XXXXXX") || refuse "cannot create a temporary directory"
# Until the pings start nothing is sent and nothing is recorded; a signal just tidies up.
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP

# The crash reports already there, so only new ones count.
crash_list() {
  for d in $CRASH_DIRS; do
    ls -1 "$d" 2>/dev/null | grep "^$CRASH_PREFIX" | sed "s|^|$d/|"
  done | sort
}
crash_list >"$WORK/crash-before"

# The driver's process IDs, joined with ";" (empty when it is not running).
driver_pids() {
  if [ -n "$opt_pid" ]; then "$opt_pid"; else pgrep -f "$DRIVER_PROC"; fi 2>/dev/null |
    sort -n | paste -sd ';' -
}

# --- The data guard and sampling. ---

# The bytes moved since the start, accumulated from the last good reading (prev_*). A counter that
# goes down was reset (the interface was recreated): what it shows now was all moved since.
set -- $base
prev_in=$1
prev_out=$2
acc_in=0
acc_out=0
resets=0
reset_at=
last_ok=1
advance() {
  c=$(counters) || {
    last_ok=0
    return 1
  }
  last_ok=1
  set -- $c
  if [ "$1" -lt "$prev_in" ] || [ "$2" -lt "$prev_out" ]; then
    resets=$((resets + 1))
    [ -n "$reset_at" ] || reset_at="$(($(date +%s) - t_start)) s ($(date -u +%H:%M:%SZ))"
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

# One reading of the guard while the pings run: sets reason and fails when the run must stop.
guarding=0
reason=
guard_check() {
  if ! advance; then
    reason="the counters of $IFACE could not be read (the interface went away)"
    return 1
  fi
  if [ $((acc_in + acc_out)) -gt $GUARD_BYTES ]; then
    reason="the data guard: $((acc_in + acc_out)) bytes moved, more than $GUARD_BYTES, at $(($(date +%s) - t_start)) s ($(date -u +%H:%M:%SZ))"
    return 1
  fi
  return 0
}

status_pid=
kill_status() {
  [ -n "$status_pid" ] || return 0
  pkill -KILL -P "$status_pid" 2>/dev/null
  kill -KILL "$status_pid" 2>/dev/null
}
# Runs the status command with a time limit and writes one CSV fragment to $WORK/st: class,
# RMNetState, then each of COUNTERS (empty when absent). Class is up, not-up, not-attached or
# unreadable. It runs in this shell (not in $(...)) so that cleanup knows the command's pid. While
# the pings run (guarding=1) the data guard is read about once a second during the wait; if it
# trips, or a signal arrives, the command is killed and read_status fails without a result.
read_status() {
  rm -f "$WORK/status.json"
  "$STATUS_CMD" status --json >"$WORK/status.json" 2>"$WORK/status.err" &
  status_pid=$!
  n=0
  aborted=0
  while kill -0 "$status_pid" 2>/dev/null; do
    if [ $n -ge $((STATUS_TIMEOUT * 10)) ]; then
      kill_status
      break
    fi
    sleep 0.1
    n=$((n + 1))
    if [ "$guarding" -eq 1 ]; then
      if [ "$signalled" -eq 1 ] || { [ $((n % 10)) -eq 0 ] && ! guard_check; }; then
        kill_status
        aborted=1
        break
      fi
    fi
  done
  wait "$status_pid" 2>/dev/null
  rc=$?
  status_pid=
  [ "$aborted" -eq 0 ] || return 1
  [ $n -lt $((STATUS_TIMEOUT * 10)) ] || rc=124
  "$PYTHON" -I -c '
import json, sys
rc, path, names = int(sys.argv[1]), sys.argv[2], sys.argv[3].split()
try:
    with open(path) as f:
        o = json.load(f)
except Exception:
    o = None
def clean(v):
    return str(v).replace(",", ";").replace("\n", " ").replace("\r", " ")
if rc != 0 or not isinstance(o, dict) or "error" in o or not isinstance(o.get("properties"), dict):
    print(",".join(["unreadable", ""] + [""] * len(names)))
    sys.exit(0)
p = o["properties"]
state = p.get("RMNetState")
cls = "not-attached" if not p else ("up" if state == "up" else "not-up")
print(",".join([cls, clean(state if state is not None else "")] + [clean(p[n]) if n in p else "" for n in names]))
' "$rc" "$WORK/status.json" "$COUNTERS" >"$WORK/st" 2>/dev/null ||
    echo "unreadable,$(echo "$COUNTERS" | sed 's/[^ ]*//g; s/ /,/g')," >"$WORK/st"
  return 0
}

t_start=$(date +%s)
samples=0
not_up_run=0
last_line=
signalled=0
# One CSV line from the latest counters, a fresh status and the driver's process ID. Fails, writing
# nothing, when read_status was cut short by the guard or a signal.
sample() {
  t=$(($(date +%s) - t_start))
  utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  read_status || return 1
  st=$(cat "$WORK/st")
  last_line="$utc,$t,$prev_in,$prev_out,$acc_in,$acc_out,$st,$(driver_pids)"
  echo "$last_line" >>"$CSV"
  samples=$((samples + 1))
  case $st in
    up,*) not_up_run=0 ;;
    *) not_up_run=$((not_up_run + 1)) ;;
  esac
  return 0
}

echo "time,seconds,if_bytes_in,if_bytes_out,moved_in,moved_out,status,RMNetState,$(echo "$COUNTERS" | tr ' ' ','),driver_pid" >"$CSV"

# The first sample, before anything is sent: a driver that is not up is not soaked.
sample
case $st in
  up,*) ;;
  *)
    echo "first sample:   $last_line" >&2
    refuse "the status is not up before the start (see the line above; is the installed app new enough for status --json?); nothing was sent"
    ;;
esac

# --- The run. From here every way out records the usage once and stops the pings. ---

pids=
started=0
recorded=0
usage_ok=1
rec_in=0
rec_out=0

stop_pings() {
  [ -n "$pids" ] || return 0
  kill -INT $pids 2>/dev/null # ping prints its summary on INT
  n=0
  while [ $n -lt 30 ]; do
    alive=0
    for p in $pids; do kill -0 "$p" 2>/dev/null && alive=1; done
    [ $alive -eq 1 ] || break
    sleep 0.1
    n=$((n + 1))
  done
  kill -KILL $pids 2>/dev/null
  for p in $pids; do wait "$p" 2>/dev/null; done
  pids=
}

# Appends this run to the usage file once. Signals are ignored from here on, so the line is written.
# If the write fails, the line is printed to be added by hand and usage_ok is cleared.
record() {
  [ "$recorded" -eq 0 ] && [ "$started" -eq 1 ] || return 0
  trap '' INT TERM HUP
  recorded=1
  advance
  rec_in=$acc_in
  rec_out=$acc_out
  if [ "$last_ok" -eq 0 ] && [ $((rec_in + rec_out)) -lt $GUARD_BYTES ]; then
    rec_in=$((GUARD_BYTES - rec_out))
    echo "soak: WARNING: the counters could not be read at the end; charging in $rec_in, out $rec_out" >&2
  fi
  usage_line="$(date -u +%Y-%m-%dT%H:%M:%SZ) up $rec_in $rec_out"
  if ! { echo "$usage_line" >>"$USAGE"; } 2>/dev/null; then
    usage_ok=0
    echo "soak: ERROR: the usage line could not be appended to $USAGE; add this line to it by hand:" >&2
    echo "$usage_line" >&2
  fi
}

# The backstop for any exit: nothing is left running and the usage is recorded.
cleanup() {
  trap '' INT TERM HUP
  kill_status
  if [ "$started" -eq 1 ]; then
    stop_pings
    [ "$recorded" -eq 1 ] || sleep 1 # let what was in flight arrive before the usage record
  fi
  record
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'signalled=1' INT TERM HUP

COUNT=$((DURATION * 2))
t_start=$(date +%s) # the run's length counts from the pings' start
started=1
(
  trap - INT
  exec ping -i 0.5 -s 1000 -c "$COUNT" -b "$IFACE" "$TARGET4"
) >"$PING4_LOG" 2>&1 &
pids="$!"
(
  trap - INT
  exec ping6 -i 0.5 -s 1000 -c "$COUNT" -B "$IFACE" "$TARGET6"
) >"$PING6_LOG" 2>&1 &
pids="$pids $!"
guarding=1
echo "soak:           $IFACE for $DURATION s, a sample every $PERIOD s, pinging $TARGET4 and $TARGET6"
echo "csv:            $CSV"

next=$PERIOD
while :; do
  sleep 1
  if [ "$signalled" -eq 1 ]; then
    reason="a signal (INT, TERM or HUP)"
    break
  fi
  guard_check || break
  el=$(($(date +%s) - t_start))
  if [ "$el" -ge "$next" ] || [ "$el" -ge "$DURATION" ]; then
    next=$((el + PERIOD))
    if ! sample; then
      [ -n "$reason" ] || reason="a signal (INT, TERM or HUP)"
      break
    fi
    if [ "$signalled" -eq 1 ]; then
      reason="a signal (INT, TERM or HUP)"
      break
    fi
    if [ "$not_up_run" -ge "$NOT_UP_STOP" ]; then
      reason="the status was not up for $NOT_UP_STOP samples in a row"
      break
    fi
  fi
  if [ "$el" -ge "$DURATION" ]; then
    break
  fi
done
guarding=0
trap '' INT TERM HUP # a second signal must not cut the finish short; cleanup still runs on exit

# At the full length a ping may just have reached its count; give them a moment, then stop both.
if [ -z "$reason" ]; then
  n=0
  while [ $n -lt 50 ]; do
    alive=0
    for p in $pids; do kill -0 "$p" 2>/dev/null && alive=1; done
    [ $alive -eq 1 ] || break
    sleep 0.1
    n=$((n + 1))
  done
fi
stop_pings
ping_secs=$(($(date +%s) - t_start))
sleep 1 # let what was in flight arrive, so the usage record includes it
# One more sample with the pings stopped, where RMNetPacketsHeld must be 0 (not after a signal).
final_sample=0
if [ "$signalled" -eq 0 ]; then
  sample && final_sample=1
fi
record
crash_list >"$WORK/crash-after"
elapsed=$(($(date +%s) - t_start))

# --- The verdict. ---

# "transmitted loss" from a ping log's summary line, or nothing if it has none.
ping_summary() {
  awk '/packets transmitted/ { tx = $1; for (i = 1; i <= NF; i++) if ($i ~ /%$/) { sub(/%/, "", $i); v = $i } } END { if (v != "") print tx, v }' "$1"
}
set -- $(ping_summary "$PING4_LOG")
sent4=${1:-} loss4=${2:-}
set -- $(ping_summary "$PING6_LOG")
sent6=${1:-} loss6=${2:-}

: >"$WORK/reasons"
[ -z "$reason" ] || echo "the run stopped early: $reason" >>"$WORK/reasons"
[ "$resets" -eq 0 ] ||
  echo "the port's byte counters went down $resets time(s), first at $reset_at: the interface was recreated" >>"$WORK/reasons"
[ "$usage_ok" -eq 1 ] ||
  echo "the usage line could not be written to $USAGE; add by hand: $usage_line" >>"$WORK/reasons"
# Every sample up; every counter in every attached sample equal to the first; the driver's process ID
# unchanged; no gap between samples longer than twice the period; RMNetPacketsHeld 0 or absent in the
# sample after the pings stopped (the last line, when final is 1).
awk -F, -v names="$COUNTERS" -v gauge="$GAUGE" -v period="$PERIOD" -v final="$final_sample" \
  -v reasons="$WORK/reasons" '
  NR == 1 { next }
  {
    n++
    k = split(names, nm, " ")
    pidcol = 9 + k
    if ($7 != "up") { bad[$7]++; if (!(($7) in first_bad)) first_bad[$7] = $2 " s (" $1 ")" }
    if (n == 1) firstpid = $pidcol
    else if ($pidcol != firstpid && !pid_changed) {
      pid_changed = 1
      printf "driver_pid changed from \"%s\" to \"%s\" at %s s (%s): the driver restarted\n", firstpid, $pidcol, $2, $1 >> reasons
    }
    if (n > 1 && $2 - prev_t > 2 * period) {
      gaps++
      if (gaps == 1) printf "a gap of %d s between the samples at %s s and %s s (more than %d s; did the Mac sleep?)\n", $2 - prev_t, prev_t, $2, 2 * period >> reasons
    }
    prev_t = $2
    last_status = $7
    last_held = ""
    if ($7 == "unreadable" || $7 == "not-attached") next # no counters to compare
    for (i = 1; i <= k; i++) {
      v = $(8 + i)
      if (nm[i] == gauge) { last_held = v; continue }
      if (!seen) { f[i] = v; continue }
      if (v != "" && v != f[i] && !(i in moved)) {
        moved[i] = 1
        printf "%s was \"%s\" in the first sample and \"%s\" at %s s (%s)\n", nm[i], f[i], v, $2, $1 >> reasons
      }
    }
    seen = 1
  }
  END {
    split("not-up not-attached unreadable", cls, " ")
    words["not-up"] = "the driver was attached but its state was not up"
    words["not-attached"] = "the driver was not attached"
    words["unreadable"] = "the status could not be read"
    for (j = 1; j <= 3; j++) {
      c = cls[j]
      if (bad[c] > 0)
        printf "%s in %d of %d samples (first at %s)\n", words[c], bad[c], n, first_bad[c] >> reasons
    }
    if (gaps > 1) printf "%d gaps in all longer than %d s between samples\n", gaps, 2 * period >> reasons
    if (final == 1) {
      if (last_status == "unreadable")
        printf "%s could not be judged: the status after the pings stopped could not be read\n", gauge >> reasons
      else if (last_held != "" && last_held != "0")
        printf "%s was %s after the pings stopped, not 0\n", gauge, last_held >> reasons
    }
  }' "$CSV"
expected=$((ping_secs * 2))
for fam in 4 6; do
  if [ "$fam" = 4 ]; then v=$loss4 s=$sent4 log=$PING4_LOG name=ping; else v=$loss6 s=$sent6 log=$PING6_LOG name=ping6; fi
  if [ -z "$v" ]; then
    echo "$name printed no summary ($log)" >>"$WORK/reasons"
    continue
  fi
  if awk -v v="$v" -v m="$MAX_LOSS" 'BEGIN { exit !(v > m) }'; then
    echo "$name lost $v% of its packets, more than $MAX_LOSS%" >>"$WORK/reasons"
  fi
  if [ $((s * 100)) -lt $((expected * MIN_SENT)) ]; then
    echo "$name sent $s packets in $ping_secs s, fewer than $MIN_SENT% of $expected" >>"$WORK/reasons"
  fi
done
comm -13 "$WORK/crash-before" "$WORK/crash-after" | sed 's/^/new crash report: /' >>"$WORK/reasons"

echo "last sample:    $last_line"
[ "$final_sample" -eq 1 ] || echo "                (no sample after the pings stopped: $GAUGE not judged)"
echo "duration:       $elapsed s of $DURATION s; pings ran $ping_secs s; $samples samples"
echo "moved:          in $acc_in bytes, out $acc_out bytes"
# Reporting only: a counter already above 0 at the start passes if it stays there, so say so.
nonzero=$(awk -F, -v names="$COUNTERS" 'NR == 2 {
    k = split(names, nm, " ")
    for (i = 1; i <= k; i++) if ($(8 + i) != "" && $(8 + i) != "0") s = s " " nm[i] "=" $(8 + i)
    print (s == "" ? " none" : s); exit }' "$CSV")
echo "nonzero at start:$nonzero"
[ "$resets" -eq 0 ] || echo "counter resets: $resets (the interface was recreated during the run)"
if [ "$usage_ok" -eq 1 ]; then
  echo "recorded:       in $rec_in bytes, out $rec_out bytes, in $USAGE"
else
  echo "recorded:       NOT RECORDED; add by hand to $USAGE: $usage_line"
fi
echo "pings:          IPv4 sent ${sent4:-unknown}, lost ${loss4:-unknown}%; IPv6 sent ${sent6:-unknown}, lost ${loss6:-unknown}%"
echo "ping logs:      $PING4_LOG $PING6_LOG"
total=$(usage_total "$USAGE") || total=unreadable
echo "recorded total: $total of $BUDGET bytes"
if [ -s "$WORK/reasons" ]; then
  echo "soak: FAIL"
  sed 's/^/  /' "$WORK/reasons"
  exit 1
fi
echo "soak: PASS"
exit 0
