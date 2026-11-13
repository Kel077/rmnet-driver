#!/bin/sh
# Follows the driver's log lines (every one starts with "RMNet:") until interrupted.
exec /usr/bin/log stream --style compact --level info --predicate 'eventMessage BEGINSWITH "RMNet:"'
