#!/bin/sh
# Tests of scripts/config.sh, which gives the build its team and bundle IDs from config.local or the
# environment, and of gen.rb's --team and --bundle-id. The helper runs in a temporary directory laid
# out as the repository root (scripts/config.sh, and a config.local this test writes), and gen.rb in
# a copy there, so the checkout's own config.local and RMNet.xcodeproj are never read or written.
# config.local is data: the values that would run a command if it were sourced are checked to run
# nothing. Run by `make script-test`; it builds nothing and signs nothing.
set -u

cd "$(dirname "$0")/../.." || exit 1
unset RMNET_TEAM_ID RMNET_BUNDLE_ID

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

[ -f scripts/config.sh ] || {
  echo "test-config: FAIL: scripts/config.sh does not exist" >&2
  exit 1
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/test-config.XXXXXX") || exit 1
ERR=$(mktemp "${TMPDIR:-/tmp}/test-config-err.XXXXXX") || exit 1
trap 'rm -rf "$WORK" "$ERR"' EXIT
mkdir "$WORK/scripts"
cp scripts/config.sh "$WORK/scripts/config.sh"
cp gen.rb "$WORK/gen.rb"

HINT='; copy config.example to config.local and fill it in'

# config [<line>...]: writes $WORK/config.local with these lines; with none, removes it.
config() {
  if [ $# -eq 0 ]; then
    rm -f "$WORK/config.local"
  else
    printf '%s\n' "$@" >"$WORK/config.local"
  fi
}

# run <function>: sources the helper in $WORK, runs rmnet_config or rmnet_config_require, and prints
# "<return status>|<TEAM_ID>|<BUNDLE_ID>|<DRIVER_ID>". What it printed on stderr is left in $ERR.
run() {
  (
    cd "$WORK" || exit 1
    . ./scripts/config.sh
    "$1" 2>"$ERR"
    rc=$?
    printf '%s|%s|%s|%s\n' "$rc" "${TEAM_ID-}" "${BUNDLE_ID-}" "${DRIVER_ID-}"
  )
}

# status <function>: only the return status of run.
status() {
  run "$1" | cut -d '|' -f 1
}

# --- nothing set ---

config
check "nothing set: rmnet_config gives the default bundle ID and an empty team" \
  "0||io.rmnetdriver.RMNet|io.rmnetdriver.RMNet.driver" "$(run rmnet_config)"
check "nothing set: rmnet_config prints nothing" "" "$(cat "$ERR")"
check "nothing set: rmnet_config_require returns 2" "2" "$(status rmnet_config_require)"
check "nothing set: rmnet_config_require says what is missing, in one line" \
  "config: RMNET_TEAM_ID and RMNET_BUNDLE_ID are not set$HINT" "$(cat "$ERR")"

cp config.example "$WORK/config.local"
check "config.example copied as it is: rmnet_config gives the defaults" \
  "0||io.rmnetdriver.RMNet|io.rmnetdriver.RMNet.driver" "$(run rmnet_config)"
check "config.example copied as it is: rmnet_config_require refuses" "2" "$(status rmnet_config_require)"
check "config.example copied as it is: the refusal" \
  "config: RMNET_TEAM_ID and RMNET_BUNDLE_ID are not set$HINT" "$(cat "$ERR")"

# --- a valid file ---

config 'RMNET_TEAM_ID=ABCDE12345' 'RMNET_BUNDLE_ID=com.example.RMNet'
check "a valid file: rmnet_config" \
  "0|ABCDE12345|com.example.RMNet|com.example.RMNet.driver" "$(run rmnet_config)"
check "a valid file: rmnet_config_require" \
  "0|ABCDE12345|com.example.RMNet|com.example.RMNet.driver" "$(run rmnet_config_require)"
check "a valid file: nothing on stderr" "" "$(cat "$ERR")"

config 'RMNET_TEAM_ID=ABCDE12345'
check "only the team: rmnet_config gives the default bundle ID" \
  "0|ABCDE12345|io.rmnetdriver.RMNet|io.rmnetdriver.RMNet.driver" "$(run rmnet_config)"
check "only the team: rmnet_config_require returns 2" "2" "$(status rmnet_config_require)"
check "only the team: the refusal names the bundle ID" "config: RMNET_BUNDLE_ID is not set$HINT" "$(cat "$ERR")"

config 'RMNET_BUNDLE_ID=com.example.RMNet'
check "only the bundle ID: rmnet_config_require returns 2" "2" "$(status rmnet_config_require)"
check "only the bundle ID: the refusal names the team" "config: RMNET_TEAM_ID is not set$HINT" "$(cat "$ERR")"

# --- the environment ---

config 'RMNET_TEAM_ID=ABCDE12345' 'RMNET_BUNDLE_ID=com.example.RMNet'
check "the environment beats the file" \
  "0|ZYXWV98765|org.example.Other|org.example.Other.driver" \
  "$(export RMNET_TEAM_ID=ZYXWV98765 RMNET_BUNDLE_ID=org.example.Other; run rmnet_config_require)"
check "one variable in the environment, the other from the file" \
  "0|ZYXWV98765|com.example.RMNet|com.example.RMNet.driver" \
  "$(export RMNET_TEAM_ID=ZYXWV98765; run rmnet_config_require)"
check "an empty environment variable does not hide the file" \
  "0|ABCDE12345|com.example.RMNet|com.example.RMNet.driver" \
  "$(export RMNET_TEAM_ID=; run rmnet_config_require)"
config
check "the environment alone, no config.local" \
  "0|ZYXWV98765|org.example.Other|org.example.Other.driver" \
  "$(export RMNET_TEAM_ID=ZYXWV98765 RMNET_BUNDLE_ID=org.example.Other; run rmnet_config_require)"
config 'RMNET_TEAM_ID=lowercase1'
check "a bad team in the file is not checked when the environment's is used" \
  "0|ZYXWV98765|org.example.Other|org.example.Other.driver" \
  "$(export RMNET_TEAM_ID=ZYXWV98765 RMNET_BUNDLE_ID=org.example.Other; run rmnet_config_require)"

# --- comments, blank lines, quotes ---

config '# my IDs' '' '   ' '  # an indented comment' 'RMNET_TEAM_ID="ABCDE12345"' "RMNET_BUNDLE_ID='com.example.RMNet'"
check "comments, blank lines, and a pair of double or single quotes" \
  "0|ABCDE12345|com.example.RMNet|com.example.RMNet.driver" "$(run rmnet_config_require)"
printf 'RMNET_TEAM_ID=ABCDE12345\nRMNET_BUNDLE_ID=com.example.RMNet' >"$WORK/config.local"
check "a last line without a newline counts" \
  "0|ABCDE12345|com.example.RMNet|com.example.RMNet.driver" "$(run rmnet_config_require)"
config 'RMNET_TEAM_ID=ABCDE12345' 'RMNET_BUNDLE_ID=org.example.First' 'RMNET_BUNDLE_ID=com.example.RMNet'
check "a name given twice: the later line counts" \
  "0|ABCDE12345|com.example.RMNet|com.example.RMNet.driver" "$(run rmnet_config_require)"
config 'RMNET_TEAM_ID=' 'RMNET_BUNDLE_ID=""'
check "empty values count as not set" "2" "$(status rmnet_config_require)"
check "empty values: the refusal" "config: RMNET_TEAM_ID and RMNET_BUNDLE_ID are not set$HINT" "$(cat "$ERR")"
config "RMNET_BUNDLE_ID=\"'com.example.RMNet'\""
check "only one pair of quotes is removed" "2" "$(status rmnet_config)"
config "RMNET_BUNDLE_ID=\"com.example.RMNet'"
check "quotes that do not pair are not removed" "2" "$(status rmnet_config)"

# --- the team ---

for team in abcde12345 ABCDE1234 ABCDE123456 'ABCDE 1234' 'ABCD$(id)' "ABCDE12345'"; do
  config "RMNET_TEAM_ID=$team" 'RMNET_BUNDLE_ID=com.example.RMNet'
  check "team '$team' in the file: rmnet_config returns 2" "2" "$(status rmnet_config)"
  check "team '$team' in the file: rmnet_config_require returns 2" "2" "$(status rmnet_config_require)"
done
config 'RMNET_TEAM_ID=abcde12345' 'RMNET_BUNDLE_ID=com.example.RMNet'
run rmnet_config >/dev/null
check "a bad team in the file: the error" \
  "config: RMNET_TEAM_ID in config.local is not a team ID (10 capital letters and digits)$HINT" "$(cat "$ERR")"
config
check "a 9-character team in the environment returns 2" "2" \
  "$(export RMNET_TEAM_ID=ABCDE1234; status rmnet_config)"
check "a bad team in the environment: the error" \
  "config: RMNET_TEAM_ID from the environment is not a team ID (10 capital letters and digits)$HINT" "$(cat "$ERR")"

# --- the bundle ID ---

for bundle in com.example.RMNet com.example-1.RMNet-2 ab.c; do
  config 'RMNET_TEAM_ID=ABCDE12345' "RMNET_BUNDLE_ID=$bundle"
  check "bundle ID '$bundle' is accepted" "0|ABCDE12345|$bundle|$bundle.driver" "$(run rmnet_config_require)"
done
for bundle in RMNet 'com example.x' 'com.$(touch x).y' 'com.`id`.y' 'com.`touch x`.y' 'com.example.RMNet; touch x' \
  'com.example/RMNet' 'com..RMNet' '.com.example' 'com.example.' 'com.ex_ample.RMNet' 'com.example.RMNet ' \
  'com.exämple.RMNet'; do
  config 'RMNET_TEAM_ID=ABCDE12345' "RMNET_BUNDLE_ID=$bundle"
  check "bundle ID '$bundle' in the file is refused" "2" "$(status rmnet_config)"
  check "bundle ID '$bundle' in the environment is refused" "2" \
    "$(export RMNET_BUNDLE_ID="$bundle"; status rmnet_config)"
done
nl='
'
check "a bundle ID with a valid first line and a second line is refused" "2" \
  "$(export RMNET_BUNDLE_ID="com.example.RMNet${nl}x"; status rmnet_config)"
config 'RMNET_TEAM_ID=ABCDE12345' 'RMNET_BUNDLE_ID=com.$(touch x).y'
run rmnet_config >/dev/null
check "a bad bundle ID: the error" \
  "config: RMNET_BUNDLE_ID in config.local is not a bundle ID (letters, digits and hyphens, in two or more parts separated by dots)$HINT" \
  "$(cat "$ERR")"
check "no value ran a command: there is no file x" "no" "$(if [ -e "$WORK/x" ]; then echo yes; else echo no; fi)"

# --- lines that are not NAME=value for the two names ---

config 'RMNET_TEAM_ID=ABCDE12345' '# a comment' 'PATH=/tmp' 'RMNET_BUNDLE_ID=com.example.RMNet'
check "an unknown name: rmnet_config returns 2" "2" "$(status rmnet_config)"
check "an unknown name: the error names the line" \
  "config: config.local line 3 is not RMNET_TEAM_ID=<value>, RMNET_BUNDLE_ID=<value>, a comment or a blank line$HINT" \
  "$(cat "$ERR")"
check "an unknown name: PATH is unchanged" "$PATH" \
  "$(cd "$WORK" && . ./scripts/config.sh && { rmnet_config 2>/dev/null; printf '%s' "$PATH"; })"
for line in 'export RMNET_TEAM_ID=ABCDE12345' 'RMNET_TEAM_ID =ABCDE12345' ' RMNET_TEAM_ID=ABCDE12345' \
  'rmnet_team_id=ABCDE12345' 'RMNET_TEAM_IDX=ABCDE12345' 'RMNET_TEAM_ID' '$(touch x)' '`touch x`' 'touch x'; do
  config '# first' "$line"
  check "line '$line' is an error naming line 2" "2 line 2" \
    "$(status rmnet_config) $(sed -n 's/^config: config\.local \(line [0-9]*\) .*/\1/p' "$ERR")"
done
check "no line ran a command: there is no file x" "no" "$(if [ -e "$WORK/x" ]; then echo yes; else echo no; fi)"

# --- gen.rb, in the copy in $WORK (its project is written there) ---

# gen <argument>...: runs the copy of gen.rb; prints its exit status and the last line it printed on
# stderr (/usr/bin/ruby may print warnings about gems before it).
gen() {
  /usr/bin/ruby "$WORK/gen.rb" "$@" >/dev/null 2>"$ERR"
  printf '%s %s\n' "$?" "$(tail -n 1 "$ERR")"
}
USAGE='usage: /usr/bin/ruby gen.rb [--team TEAM_ID] [--bundle-id BUNDLE_ID]'

check "gen.rb: an unknown argument" "1 $USAGE" "$(gen --bogus)"
check "gen.rb: the team as a positional argument is refused" "1 $USAGE" "$(gen ABCDE12345)"
check "gen.rb: --team without a value" "1 $USAGE" "$(gen --team)"
check "gen.rb: --bundle-id without a value" "1 $USAGE" "$(gen --team ABCDE12345 --bundle-id)"
check "gen.rb: a lowercase team" "1 gen.rb: 'abcde12345' is not a team ID" "$(gen --team abcde12345)"
check "gen.rb: a bundle ID with a command in it" "1 gen.rb: 'com.\$(touch x).y' is not a bundle ID" \
  "$(gen --bundle-id 'com.$(touch x).y')"
check "gen.rb: a bundle ID of one part" "1 gen.rb: 'RMNet' is not a bundle ID" "$(gen --bundle-id RMNet)"
check "gen.rb wrote no project when it refused" "no" \
  "$(if [ -e "$WORK/RMNet.xcodeproj" ]; then echo yes; else echo no; fi)"

PBX=$WORK/RMNet.xcodeproj/project.pbxproj
# ids: the distinct bundle identifiers and teams in the project written last, one line.
ids() {
  sed -nE 's/^[[:space:]]*(PRODUCT_BUNDLE_IDENTIFIER|DEVELOPMENT_TEAM) = (.*);$/\1=\2/p' "$PBX" | sort -u | tr '\n' ' '
}
gen >/dev/null
check "gen.rb with no option: the default IDs, no team" \
  "PRODUCT_BUNDLE_IDENTIFIER=io.rmnetdriver.RMNet PRODUCT_BUNDLE_IDENTIFIER=io.rmnetdriver.RMNet.driver " "$(ids)"
gen --bundle-id com.example.RMNetTest --team ABCDE12345 >/dev/null
check "gen.rb --bundle-id and --team" \
  "DEVELOPMENT_TEAM=ABCDE12345 PRODUCT_BUNDLE_IDENTIFIER=com.example.RMNetTest PRODUCT_BUNDLE_IDENTIFIER=com.example.RMNetTest.driver " \
  "$(ids)"
check "gen.rb --bundle-id: the driver's product is <bundle ID>.driver.dext" "yes" \
  "$(if grep -q 'path = com\.example\.RMNetTest\.driver\.dext;' "$PBX"; then echo yes; else echo no; fi)"
check "gen.rb ran no command: there is no file x" "no" "$(if [ -e "$WORK/x" ] || [ -e x ]; then echo yes; else echo no; fi)"

echo "test-config: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
