#!/usr/bin/python3
"""Sends a burst of UDP datagrams out of one network port, as fast as the system takes them.

    scripts/uplink-burst.py <interface> [datagrams] [bytes-each] [--usage-file <file>]

The datagrams (default 1,500 of 1,200 bytes) go to 192.0.2.1 port 9, a documentation address
(RFC 5737) that answers nothing, from a socket bound to the interface with IP_BOUND_IF. It exists
to fill the driver's uplink buffers: a burst larger than the buffers hold shows whether the driver
keeps the frames it cannot send at once (RMNetTxHolds) or drops them (RMNetTxDropBusy).

The cellular data is metered. The limit is on what the cellular link carries: datagrams x
(bytes-each + 28 bytes of IPv4 and UDP headers) must be at most 2,000,000, or the request is
refused before anything is sent. The usage file (build/installed/measure-usage.log, shared with
scripts/measure.sh) must exist, end with a newline, and every line other than a comment must be
"<time> <down|up> <bytes in> <bytes out>"; otherwise the run is refused. The run is also refused if
the recorded total plus this run's datagrams x (bytes-each + 28) would pass 6,300,000,000 bytes (the
budget scripts/measure.sh checks too), or if the usage file cannot be opened for appending; it is
opened before the sends and stays open until the line is written. After the burst, one line
"<UTC time> up <bytes in> <bytes out>" is appended, from the interface's own byte counters
(`netstat -I <interface> -b -n`) read before and 1 s after the burst. If the counters cannot be read
at the end, or went backwards (the interface was recreated), the run is charged its payload plus
headers instead, and that is said.

An interrupt (SIGINT, SIGTERM or SIGHUP) during the sends stops them; from the end of the sends
(the send loop's last step) until the usage line is written, these signals are ignored, so what was
sent is recorded.

--usage-file replaces the usage file for a test. It is accepted only with the interface lo0, and
lo0 requires it, so a loopback run never writes to the real usage file.
Exit status: 0 done, 2 refused (nothing sent, nothing recorded), 130 interrupted (recorded).
"""

import datetime
import errno
import os
import re
import signal
import socket
import subprocess
import sys
import time

DEST = ("192.0.2.1", 9)
MAX_TOTAL = 2_000_000
BUDGET = 6_300_000_000  # all recorded use, as in scripts/measure.sh
DEFAULT_COUNT = 1500
DEFAULT_SIZE = 1200
IP_BOUND_IF = 25  # <netinet/in.h>; Python's socket module does not name it
IP_UDP_HEADERS = 20 + 8  # what the cellular link carries besides the payload; counted in the limit
HEADERS = 14 + IP_UDP_HEADERS  # what the port's counters add to each datagram (with Ethernet)
SIGNALS = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
USAGE_DEFAULT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build", "installed",
                             "measure-usage.log")
LINE = re.compile(r"^\S+ (down|up) [0-9]+ [0-9]+$")


def refuse(msg):
    print("uplink-burst: REFUSED: " + msg, file=sys.stderr)
    sys.exit(2)


def parse_args(argv):
    usage_file = None
    rest = []
    i = 0
    while i < len(argv):
        if argv[i] == "--usage-file":
            if i + 1 >= len(argv):
                refuse("--usage-file needs a file")
            usage_file = argv[i + 1]
            i += 2
        else:
            rest.append(argv[i])
            i += 1
    if not 1 <= len(rest) <= 3:
        refuse("usage: uplink-burst.py <interface> [datagrams] [bytes-each] [--usage-file <file>]")
    iface = rest[0]
    try:
        count = int(rest[1]) if len(rest) > 1 else DEFAULT_COUNT
        size = int(rest[2]) if len(rest) > 2 else DEFAULT_SIZE
    except ValueError:
        refuse("datagrams and bytes-each must be whole numbers")
    if count < 1 or size < 1 or size > 1472:
        refuse("datagrams must be at least 1, and bytes-each from 1 to 1472 (one unfragmented frame)")
    carried = count * (size + IP_UDP_HEADERS)
    if carried > MAX_TOTAL:
        refuse("%d datagrams x (%d + %d) bytes is %d bytes on the link, above the %d-byte limit" %
               (count, size, IP_UDP_HEADERS, carried, MAX_TOTAL))
    if usage_file is not None and iface != "lo0":
        refuse("--usage-file is accepted only with the interface lo0")
    if usage_file is None and iface == "lo0":
        refuse("lo0 needs --usage-file (a test run must not write to the real usage file)")
    return iface, count, size, usage_file or USAGE_DEFAULT


def check_usage(path):
    """The recorded total of the usage file; refuses if it is missing or malformed."""
    if not os.path.isfile(path):
        refuse("the usage file %s does not exist" % path)
    with open(path, "rb") as f:
        data = f.read()
    if data and not data.endswith(b"\n"):
        refuse("the usage file %s does not end with a newline; an appended line would join its last line" %
               path)
    total = 0
    bad = []
    with open(path) as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if line.startswith("#"):
                continue
            if not LINE.match(line):
                bad.append("line %d: %r" % (n, line))
                continue
            fields = line.split()
            total += int(fields[2]) + int(fields[3])
    if bad:
        refuse("the usage file %s is malformed (%s)" % (path, "; ".join(bad)))
    return total


def counters(iface):
    """(bytes in, bytes out) from the interface's link-level line, or None."""
    try:
        out = subprocess.run(["/usr/sbin/netstat", "-I", iface, "-b", "-n"], capture_output=True,
                             text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    for line in out.splitlines():
        f = line.split()
        # Counted from the end (Ibytes Opkts Oerrs Obytes Coll): lo0 has no Address column.
        if len(f) >= 7 and f[0] == iface and f[2].startswith("<Link#"):
            try:
                return int(f[-5]), int(f[-2])
            except ValueError:
                return None
    return None


def main():
    iface, count, size, usage = parse_args(sys.argv[1:])
    used = check_usage(usage)
    try:
        index = socket.if_nametoindex(iface)
    except OSError:
        refuse("no interface named %s" % iface)
    before = counters(iface)
    if before is None:
        refuse("the byte counters of %s cannot be read" % iface)
    carried = count * (size + IP_UDP_HEADERS)
    if used + carried > BUDGET:
        refuse("the recorded total %d plus this run's %d bytes would pass the %d-byte budget" %
               (used, carried, BUDGET))
    try:
        record = open(usage, "a")  # before the sends: a run that cannot be recorded is not made
    except OSError as e:
        refuse("the usage file %s cannot be opened for appending (%s)" % (usage, e))
    print("usage file: %s, recorded total %d bytes" % (usage, used))
    print("burst: %d datagrams of %d bytes to %s port %d from %s: %d x (%d + %d) = %d bytes on the link, "
          "limit %d" % (count, size, DEST[0], DEST[1], iface, count, size, IP_UDP_HEADERS,
                        count * (size + IP_UDP_HEADERS), MAX_TOTAL))
    print("%s before: in %d, out %d" % (iface, before[0], before[1]))

    sent = refused = other = 0
    first_error = None
    interrupted = False

    def stop_sending(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop_sending)  # SIGINT already raises KeyboardInterrupt
    signal.signal(signal.SIGHUP, stop_sending)
    payload = b"\0" * size
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    started = time.monotonic()
    try:
        sock.setsockopt(socket.IPPROTO_IP, IP_BOUND_IF, index)
        for _ in range(count):
            try:
                sock.sendto(payload, DEST)
                sent += 1
            except OSError as e:
                if e.errno == errno.ENOBUFS:
                    refused += 1
                else:
                    other += 1
                    if first_error is None:
                        first_error = e
        # The last step of the sends: a signal after it must not reach the handler, which would
        # raise inside finally and skip the record. One before it lands in the except below.
        for sig in SIGNALS:
            signal.signal(sig, signal.SIG_IGN)
    except KeyboardInterrupt:
        for sig in SIGNALS:
            signal.signal(sig, signal.SIG_IGN)
        interrupted = True
    finally:
        # From here until the usage line is written, an interrupt must not cut the record short.
        for sig in SIGNALS:
            signal.signal(sig, signal.SIG_IGN)
        elapsed = time.monotonic() - started
        sock.close()
        time.sleep(1)  # what was in flight is counted before the record
        after = counters(iface)
        if after is not None and after[0] >= before[0] and after[1] >= before[1]:
            rec_in, rec_out = after[0] - before[0], after[1] - before[1]
            note = ""
        else:
            rec_in, rec_out = 0, count * (size + HEADERS)
            note = " (counters unreadable or reset; charged the payload plus headers)"
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with record:
            record.write("%s up %d %d\n" % (stamp, rec_in, rec_out))

    if interrupted:
        print("uplink-burst: interrupted during the sends; what was sent is recorded", file=sys.stderr)
    print("sent %d, refused by the system (ENOBUFS) %d, other errors %d%s in %.3f s" %
          (sent, refused, other, " (first: %s)" % first_error if first_error else "", elapsed))
    if after is not None:
        print("%s after:  in %d, out %d" % (iface, after[0], after[1]))
    print("recorded: in %d, out %d%s; usage file total now %d bytes" %
          (rec_in, rec_out, note, used + rec_in + rec_out))
    return 130 if interrupted else 0


if __name__ == "__main__":
    sys.exit(main())
