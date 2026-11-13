#!/bin/sh
# Follows the driver's log lines until interrupted, and keeps them in build/logs/driver-<time>.log.
#
# A dext's os_log lines are kernel messages (process "kernel", sender the dext's executable). On this
# Mac `log show` cannot return them afterwards, so the saved file is the only record: start this
# before installing or re-enumerating. Use the default level: `--level info` or `debug` makes the
# kernel stream far more, and the driver's lines were then lost around a load.
set -eu

cd "$(dirname "$0")/.." || exit 1
mkdir -p build/logs
file="build/logs/driver-$(date +%Y%m%d-%H%M%S).log"
echo "saving to $file" >&2
/usr/bin/log stream --style compact \
  --predicate 'senderImagePath ENDSWITH "/io.rmnetdriver.RMNet.driver" OR eventMessage BEGINSWITH "RMNet:"' |
  tee "$file"
