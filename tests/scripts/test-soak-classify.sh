#!/bin/sh
# Tests of the status classes scripts/soak.sh gives a sample of `RMNet status --json`, through
# `soak.sh --classify <file> [<exit status>]`, which runs the same code as a soak's samples and sends
# nothing. The status files are under fixtures/. Run by `make script-test`.
set -u

cd "$(dirname "$0")/../.." || exit 1
FIX=tests/scripts/fixtures

pass=0
fail=0
# check <name> <expected> <actual>
check() {
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: %s\n  expected: "%s"\n  actual:   "%s"\n' "$1" "$2" "$3" >&2
  fi
}

# The class soak.sh prints for a status file, then its exit status: "<class> <status>".
class_of() {
  c=$(./scripts/soak.sh --classify "$@" 2>/dev/null)
  echo "$c $?"
}

check "up" "up 0" "$(class_of "$FIX/status-up.json")"
check "attached, state not up" "not-up 0" "$(class_of "$FIX/status-not-up.json")"
check "not attached (empty properties)" "not-attached 0" "$(class_of "$FIX/status-not-attached.json")"
check "no properties object" "unreadable 0" "$(class_of "$FIX/status-no-properties.json")"
check "an error key with registry properties saying up" "up 0" "$(class_of "$FIX/status-error-up.json")"
check "an error key with registry properties saying up, exit status 1 (how RMNet reports no listing)" \
  "up 0" "$(class_of "$FIX/status-error-up.json" 1)"
check "an error key with registry properties not up, exit status 1" \
  "not-up 0" "$(class_of "$FIX/status-error-not-up.json" 1)"
check "an error key, exit status 124 (the soak's time limit)" \
  "unreadable 0" "$(class_of "$FIX/status-error-up.json" 124)"
check "no error key, exit status 1 (the command failed)" "unreadable 0" "$(class_of "$FIX/status-up.json" 1)"
check "output that is not JSON" "unreadable 0" "$(class_of "$FIX/status-not-json.txt")"
check "empty output" "unreadable 0" "$(class_of "$FIX/status-empty.txt")"
check "a missing file" "unreadable 0" "$(class_of "$FIX/no-such-status.json")"
check "a path relative to the caller's directory" "up 0" \
  "$(cd tests/scripts && c=$(../../scripts/soak.sh --classify fixtures/status-up.json 2>/dev/null); echo "$c $?")"
./scripts/soak.sh --classify >/dev/null 2>&1
check "--classify without a file is refused" "2" "$?"
./scripts/soak.sh --classify "$FIX/status-up.json" one >/dev/null 2>&1
check "--classify with an exit status that is not a number is refused" "2" "$?"

echo "test-soak-classify: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
