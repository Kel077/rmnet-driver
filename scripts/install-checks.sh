# The three checks of scripts/install-driver.sh that can be tested without an install, sourced by it
# and by tests/scripts/test-install-checks.sh (`make script-test`). Functions only: sourcing this file
# runs nothing. Their variables start with ic_, so they do not change the caller's.

# installed_id_line <installed app's bundle ID> <configured bundle ID>
# Succeeds, printing nothing, when there is no installed app (the first argument is empty) or it has
# the configured bundle ID. Otherwise prints the refusal line, naming both, and fails: the kept-app
# checks below and the driver version read from the app go by the configured driver ID, so an app
# (and its listed driver) under another ID would be replaced without a kept copy, and a second driver
# with the same personalities activated beside it. The caller passes "(none readable)" for an app
# whose bundle ID cannot be read, which is refused like any other.
installed_id_line() {
  if [ -z "$1" ] || [ "$1" = "$2" ]; then
    return 0
  fi
  echo "the installed app's bundle ID is $1, not $2 as configured (config.local or the environment):" \
    "if systemextensionsctl list still shows its driver, remove that first with this app" \
    "(docs/reference.md, Removing the driver); then delete the app and run again; nothing was changed"
  return 1
}

# missing_kept_apps <listing-text-file> <keep-dir> <driver-id>
# Prints, one per line in listing order, every version listed for <driver-id> in the file (the output
# of `systemextensionsctl list`) whose state does not contain "uninstall" and for which
# <keep-dir>/RMNet-<version>.app does not exist: each of them could not be deactivated without that
# app (docs/reference.md, "Removing the driver"). An entry's version is the one after the "/" in
# "<driver-id> (<short version>/<version>)". Fails if the file cannot be read.
missing_kept_apps() {
  ic_versions=$(awk -F '\t' -v id="$3" '
    index($4, id " (") == 1 && $NF !~ /uninstall/ && match($4, /\/[0-9.]+\)$/) {
      v = substr($4, RSTART + 1, RLENGTH - 2)
      if (!(v in seen)) { seen[v] = 1; print v }
    }' "$1") || return 1
  for ic_v in $ic_versions; do
    [ -d "$2/RMNet-$ic_v.app" ] || echo "$ic_v"
  done
  return 0
}

# running_line <new-cdhash> <running-cdhash> <version>
# What the script says about the running driver: <new-cdhash> is the CDHash of the driver it just
# installed (version <version>), <running-cdhash> the one of the RMNetDriver in the registry (empty
# when none is attached). An empty <new-cdhash> means the new build could not be read, which says
# nothing about which build is running.
running_line() {
  if [ -z "$2" ]; then
    echo "no RMNetDriver attached (modem not attached in QMI mode?)"
  elif [ -z "$1" ]; then
    echo "cannot read the CDHash of version $3; whether it is the running driver is not known"
  elif [ "$2" = "$1" ]; then
    echo "version $3 is the running driver"
  else
    echo "an older build is still running; version $3 loads when the modem re-enumerates"
    echo "(unplug it, or send AT+CFUN=1,1)"
  fi
}
