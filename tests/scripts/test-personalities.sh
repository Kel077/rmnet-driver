#!/bin/sh
# Tests of the driver's personalities (driver/Info.plist) and of scripts/check-personalities.sh. The
# plist lints; the RM520N-GL's RMNetDriver personality prints exactly as it always has
# (fixtures/rmnetdriver-personality.txt); every RMNetDriver personality is a copy of it but for
# idProduct and bInterfaceNumber, named for its product; the RMNetDriver products and interfaces
# agree with the model list in scripts/check-personalities.sh and with quectelModels in
# app/StatusModel.swift; and check-personalities.sh passes the shipped plist (and the RM520N-GL's own
# three personalities with exactly the line it always printed) and refuses wrong ones. Run by
# `make script-test`; it writes only to a temporary directory and needs no hardware.
set -u

cd "$(dirname "$0")/../.." || exit 1
FIX=tests/scripts/fixtures
PLIST=driver/Info.plist
CHECK=scripts/check-personalities.sh
BUDDY=/usr/libexec/PlistBuddy

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

TMP=$(mktemp -d "${TMPDIR:-/tmp}/personalities.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

# The value of key $3 in personality $2 of plist $1, printed raw; nothing when it is missing or, with
# a fourth argument, not of that plist type.
value() {
  if [ $# -ge 4 ]; then
    plutil -extract "IOKitPersonalities.$2.$3" raw -expect "$4" -o - "$1" 2>/dev/null
  else
    plutil -extract "IOKitPersonalities.$2.$3" raw -o - "$1" 2>/dev/null
  fi
}

# --- the shipped plist ---

plutil -lint "$PLIST" >/dev/null 2>&1
check "plutil -lint $PLIST" 0 "$?"

check "the RMNetDriver personality prints exactly as the fixture" \
  "$(cat "$FIX/rmnetdriver-personality.txt")" "$("$BUDDY" -c 'Print :IOKitPersonalities:RMNetDriver' "$PLIST" 2>&1)"

names=$(plutil -extract IOKitPersonalities raw -expect dictionary -o - "$PLIST" 2>/dev/null)
check "the plist has personalities" 1 "$([ -n "$names" ] && echo 1)"

base_keys=$(plutil -extract IOKitPersonalities.RMNetDriver raw -expect dictionary -o - "$PLIST" 2>/dev/null | sort)
pairs=
plist_models=
for name in $names; do
  check "$name: idVendor 11388" 11388 "$(value "$PLIST" "$name" idVendor integer)"
  check "$name: IOProviderClass IOUSBHostInterface" IOUSBHostInterface "$(value "$PLIST" "$name" IOProviderClass string)"
  check "$name: bConfigurationValue 1" 1 "$(value "$PLIST" "$name" bConfigurationValue integer)"
  product=$(value "$PLIST" "$name" idProduct integer)
  ifn=$(value "$PLIST" "$name" bInterfaceNumber integer)
  check "$name: idProduct and bInterfaceNumber are integers" 1 "$([ -n "$product" ] && [ -n "$ifn" ] && echo 1)"
  pairs="$pairs$product $ifn
"
  class=$(value "$PLIST" "$name" IOUserClass string)
  case $name in
    RMNetDriver | RMNetDriver_*)
      check "$name: IOUserClass RMNetDriver" RMNetDriver "$class"
      ;;
  esac
  [ "$class" = RMNetDriver ] || continue

  hex=$(printf '%04x' "${product:-0}")
  if [ "$product" = 2049 ]; then
    check "the RM520N-GL's RMNetDriver personality keeps its name" RMNetDriver "$name"
  else
    check "an RMNetDriver personality is named for its product" "RMNetDriver_$hex" "$name"
  fi
  plist_models="$plist_models$hex $ifn
"
  check "$name: RMNetProfile 1" 1 "$(value "$PLIST" "$name" RMNetProfile integer)"
  check "$name: RMNetFlowControl 1" 1 "$(value "$PLIST" "$name" RMNetFlowControl integer)"

  # The same keys as RMNetDriver, with the same types and values but for idProduct and bInterfaceNumber.
  keys=$(plutil -extract "IOKitPersonalities.$name" raw -expect dictionary -o - "$PLIST" 2>/dev/null | sort)
  check "$name: the same keys as RMNetDriver" "$base_keys" "$keys"
  for key in $base_keys; do
    case $key in idProduct | bInterfaceNumber) continue ;; esac
    check "$name: $key as in RMNetDriver" \
      "$(plutil -extract "IOKitPersonalities.RMNetDriver.$key" xml1 -o - "$PLIST" 2>&1)" \
      "$(plutil -extract "IOKitPersonalities.$name.$key" xml1 -o - "$PLIST" 2>&1)"
  done
done

check "every personality has its own (idProduct, bInterfaceNumber) pair" "" \
  "$(printf '%s' "$pairs" | sort | uniq -d)"

# --- one model list: the script's, the app's and the plist's RMNetDriver personalities ---

script_models=$(sh "$CHECK" --models | sort)
# quectelModels lines in app/StatusModel.swift: "QuectelModel(product: 0x0801, qmiInterface: 4, ...".
app_models=$(sed -n 's/^ *QuectelModel(product: 0x\([0-9A-Fa-f]\{4\}\), qmiInterface: \([0-9]\{1,3\}\),.*/\1 \2/p' \
  app/StatusModel.swift | tr 'A-F' 'a-f' | sort)
app_tested=$(sed -n 's/^ *QuectelModel(product: 0x\([0-9A-Fa-f]\{4\}\),.* tested: true).*/\1/p' app/StatusModel.swift)
plist_models=$(printf '%s' "$plist_models" | sort)

check "the script's model list names the RM520N-GL's interface 4" 1 \
  "$(printf '%s\n' "$script_models" | grep -qx '0801 4' && echo 1)"
check "the script's model list has seven models, the RM520N-GL and six untested" 7 "$(printf '%s\n' "$script_models" | grep -c .)"
check "quectelModels in app/StatusModel.swift matches the script's model list" "$script_models" "$app_models"
check "the RMNetDriver personalities match the script's model list" "$script_models" "$plist_models"
check "only the RM520N-GL is marked tested in quectelModels" 0801 "$app_tested"

# --- scripts/check-personalities.sh ---

out=$(sh "$CHECK" "$PLIST" 2>&1)
check "the shipped plist passes" "0 personality check: 9 personalities ok" "$? $out"

# A new copy of the shipped plist, changed by PlistBuddy commands; prints its path.
variant() {
  v=$(mktemp "$TMP/variant.XXXXXX") || exit 1
  cp "$PLIST" "$v"
  for c in "$@"; do "$BUDDY" -c "$c" "$v" >/dev/null || echo "variant: '$c' failed" >&2; done
  echo "$v"
}
# check_refused <name> <expected lines> <plist>: the script exits 1 with exactly those lines and "failed".
check_refused() {
  out=$(sh "$CHECK" "$3" 2>&1)
  check "$1" "1 $2
personality check: failed" "$? $out"
}

rm520=$(variant 'Delete :IOKitPersonalities:RMNetDriver_0121' 'Delete :IOKitPersonalities:RMNetDriver_0191' \
  'Delete :IOKitPersonalities:RMNetDriver_0195' 'Delete :IOKitPersonalities:RMNetDriver_0296' \
  'Delete :IOKitPersonalities:RMNetDriver_030e' 'Delete :IOKitPersonalities:RMNetDriver_0316')
out=$(sh "$CHECK" "$rm520" 2>&1)
check "the RM520N-GL's three personalities alone: the line the script always printed" \
  "0 personality check: 3 personalities ok" "$? $out"

check_refused "the RM520N-GL's RMNetDriver on interface 3: the same two lines as before" \
  "personality check: RMNetDriver: on interface 3, an AT port that no personality may match
personality check: RMNetDriver: RMNetDriver on interface 3, not 4" \
  "$(variant 'Set :IOKitPersonalities:RMNetDriver:bInterfaceNumber 3')"
check_refused "the RM520N-GL's RMNetDriver on interface 5" \
  "personality check: RMNetDriver: RMNetDriver on interface 5, not 4" \
  "$(variant 'Set :IOKitPersonalities:RMNetDriver:bInterfaceNumber 5')"
check_refused "another model on an interface that is not its QMI interface" \
  "personality check: RMNetDriver_0121: RMNetDriver for 2c7c:0121 on interface 2, not its QMI interface 4" \
  "$(variant 'Set :IOKitPersonalities:RMNetDriver_0121:bInterfaceNumber 2')"
check_refused "the RG255C on interface 4, not its QMI interface 3" \
  "personality check: RMNetDriver_0316: RMNetDriver for 2c7c:0316 on interface 4, not its QMI interface 3" \
  "$(variant 'Set :IOKitPersonalities:RMNetDriver_0316:bInterfaceNumber 4')"
check_refused "another model's interface given as a string" \
  "personality check: RMNetDriver_0195: RMNetDriver for 2c7c:0195 on interface (none, or not an integer), not its QMI interface 4" \
  "$(variant 'Delete :IOKitPersonalities:RMNetDriver_0195:bInterfaceNumber' \
    'Add :IOKitPersonalities:RMNetDriver_0195:bInterfaceNumber string 4')"
check_refused "another model under another vendor" \
  "personality check: RMNetDriver_0191: idVendor 1234, not 11388 (0x2c7c)" \
  "$(variant 'Set :IOKitPersonalities:RMNetDriver_0191:idVendor 1234')"
check_refused "a product the kernel matches only by class (EC25, 0x0125)" \
  "personality check: RMNetDriver_0121: RMNetDriver for idProduct 293 (2c7c:0125), not a product in the model list" \
  "$(variant 'Set :IOKitPersonalities:RMNetDriver_0121:idProduct 293')"
check_refused "RMNetDriver with no idProduct" \
  "personality check: RMNetDriver: RMNetDriver for idProduct (none, or not an integer), not a product in the model list" \
  "$(variant 'Delete :IOKitPersonalities:RMNetDriver:idProduct')"
check_refused "a serial personality for another model" \
  "personality check: RMNetSerialNMEA: RMNetSerial for idProduct 289 (2c7c:0121), not 2049 (2c7c:0801, the RM520N-GL, the only model with serial personalities)" \
  "$(variant 'Set :IOKitPersonalities:RMNetSerialNMEA:idProduct 289')"
check_refused "a serial personality on another model's QMI interface 3: the AT port rule still applies" \
  "personality check: RMNetSerialNMEA: on interface 3, an AT port that no personality may match
personality check: RMNetSerialNMEA: RMNetSerial for idProduct 790 (2c7c:0316), not 2049 (2c7c:0801, the RM520N-GL, the only model with serial personalities)
personality check: RMNetSerialNMEA: RMNetSerial on interface 3, not 0 or 1" \
  "$(variant 'Set :IOKitPersonalities:RMNetSerialNMEA:idProduct 790' \
    'Set :IOKitPersonalities:RMNetSerialNMEA:bInterfaceNumber 3')"

echo "test-personalities: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
