#!/bin/sh
# Tests of scripts/install-checks.sh, the three decisions scripts/install-driver.sh takes from it:
# whether the installed app has the configured bundle ID (installed_id_line), which listed driver
# versions have no kept app (missing_kept_apps), and the line about the running driver
# (running_line). The listings under fixtures/ are in `systemextensionsctl list` format. Run by
# `make script-test`; it installs nothing and reads nothing of the system's.
set -u

cd "$(dirname "$0")/../.." || exit 1
FIX=tests/scripts/fixtures
ID=io.rmnetdriver.RMNet.driver

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

[ -f scripts/install-checks.sh ] || {
  echo "test-install-checks: FAIL: scripts/install-checks.sh does not exist" >&2
  exit 1
}
. ./scripts/install-checks.sh

KEEP=$(mktemp -d "${TMPDIR:-/tmp}/install-checks.XXXXXX") || exit 1
EMPTY_KEEP=$(mktemp -d "${TMPDIR:-/tmp}/install-checks.XXXXXX") || exit 1
trap 'rm -rf "$KEEP" "$EMPTY_KEEP"' EXIT
mkdir "$KEEP/RMNet-317.18.40.app"

# --- installed_id_line <installed app's bundle ID> <configured bundle ID> ---

# The line and the return status: "<line>|<status>".
id_line() {
  il=$(installed_id_line "$1" "$2")
  echo "$il|$?"
}
REFUSAL_END='as configured (config.local or the environment): replacing it would leave its driver with no app that can deactivate it; see docs/reference.md, Removing the driver; nothing was changed'
check "no installed app" "|0" "$(id_line '' io.rmnetdriver.RMNet)"
check "the installed app has the configured bundle ID" "|0" "$(id_line io.rmnetdriver.RMNet io.rmnetdriver.RMNet)"
check "the installed app has another bundle ID: refused, naming both" \
  "the installed app's bundle ID is io.rmnetdriver.RMNet, not io.rmnetdriver.RMnet $REFUSAL_END|1" \
  "$(id_line io.rmnetdriver.RMNet io.rmnetdriver.RMnet)"
check "the installed app's bundle ID could not be read: refused" \
  "the installed app's bundle ID is (none readable), not com.example.RMNet $REFUSAL_END|1" \
  "$(id_line '(none readable)' com.example.RMNet)"

# --- missing_kept_apps ---

check "an activated enabled entry with a kept app is not printed" \
  "" "$(missing_kept_apps "$FIX/listing-one-enabled.txt" "$KEEP" "$ID")"
check "an activated enabled entry without a kept app is printed" \
  "317.18.40" "$(missing_kept_apps "$FIX/listing-one-enabled.txt" "$EMPTY_KEEP" "$ID")"
check "an activated waiting for user entry without a kept app is printed" \
  "317.19.2" "$(missing_kept_apps "$FIX/listing-waiting-for-user.txt" "$KEEP" "$ID")"
check "a terminated waiting to uninstall on reboot entry without a kept app is not printed" \
  "" "$(missing_kept_apps "$FIX/listing-uninstalling.txt" "$KEEP" "$ID")"
check "with no kept app at all, only the uninstalling entry is left out" \
  "317.18.40" "$(missing_kept_apps "$FIX/listing-uninstalling.txt" "$EMPTY_KEEP" "$ID")"
check "several entries: every one without a kept app, in listing order, but the uninstalling one and another driver's" \
  "$(printf '%s\n' 317.16.8 317.19.2)" "$(missing_kept_apps "$FIX/listing-several.txt" "$KEEP" "$ID")"
check "several entries, none kept" \
  "$(printf '%s\n' 317.18.40 317.16.8 317.19.2)" "$(missing_kept_apps "$FIX/listing-several.txt" "$EMPTY_KEEP" "$ID")"
check "a listing without the driver prints nothing" \
  "" "$(missing_kept_apps "$FIX/listing-none.txt" "$EMPTY_KEEP" "$ID")"
missing_kept_apps "$FIX/listing-several.txt" "$KEEP" "$ID" >/dev/null
check "missing_kept_apps succeeds when it prints versions" "0" "$?"
missing_kept_apps "$FIX/listing-none.txt" "$KEEP" "$ID" >/dev/null
check "missing_kept_apps succeeds when it prints nothing" "0" "$?"
missing_kept_apps "$FIX/no-such-listing.txt" "$KEEP" "$ID" >/dev/null 2>&1
check "missing_kept_apps fails when the listing cannot be read" "1" "$?"

# --- running_line <new-cdhash> <running-cdhash> <version> ---

check "the new build's CDHash equals the running one's" \
  "version 317.18.41 is the running driver" "$(running_line 1f2e3d 1f2e3d 317.18.41)"
check "the running CDHash differs from the new build's" \
  "$(printf '%s\n' 'an older build is still running; version 317.18.41 loads when the modem re-enumerates' \
    '(unplug it, or send AT+CFUN=1,1)')" "$(running_line 1f2e3d 4c5b6a 317.18.41)"
check "no running driver" \
  "no RMNetDriver attached (modem not attached in QMI mode?)" "$(running_line 1f2e3d '' 317.18.41)"
check "the new build's CDHash cannot be read" \
  "cannot read the CDHash of version 317.18.41; whether it is the running driver is not known" \
  "$(running_line '' 4c5b6a 317.18.41)"
check "neither CDHash: no running driver is the answer" \
  "no RMNetDriver attached (modem not attached in QMI mode?)" "$(running_line '' '' 317.18.41)"

echo "test-install-checks: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
