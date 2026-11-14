#!/bin/sh
# Checks which USB interfaces the dext's personalities may match, before anything is built or
# installed. On the RM520N-GL (2c7c:0801) interfaces 2 and 3 are its AT ports (the owner's console
# and the app's SMS), so no personality may match them; RMNetSerial may match only 0 (DIAG) and 1
# (NMEA) of the RM520N-GL, with Apple's serial kernel class and a usable port name; RMNetDriver for
# the RM520N-GL only 4 (QMI); RMNetDriver for another product only that product's QMI interface in
# the model list below, under vendor 0x2c7c; RMNetDriver for a product not in the list, or with no
# integer idProduct, is refused; and a personality of any other IOUserClass, or none, is refused.
# RMNetDriver and RMNetSerial check the interface again in Start; this check catches a wrong
# personality before it reaches the modem. The messages show the typed values the checks compare
# (an integer or a string): a value that is missing or of another type shows as "(none, or not an
# integer)" or "(none, or not a string)".
#
# Usage: scripts/check-personalities.sh [plist]   (default: driver/Info.plist)
#        scripts/check-personalities.sh --models  (prints the model list, one "<idProduct in hex>
#                                                  <QMI interface>" per line)
set -u

LC_ALL=C
export LC_ALL

# The products RMNetDriver may match, each with its QMI interface number: the same list as
# quectelModels in app/StatusModel.swift (tests/scripts/test-personalities.sh compares the two, and
# both with the RMNetDriver personalities in driver/Info.plist). 0801 is the RM520N-GL, the modem
# this driver was built for and tested on, whose QMI interface 4 was found on the modem (the kernel
# matches it by class: {QMI_MATCH_FF_FF_FF(0x2c7c, 0x0801)}, /* Quectel RM520N */). The others are
# untested: they are the Quectel (vendor 0x2c7c) entries of the Linux kernel's
# drivers/net/usb/qmi_wwan.c (torvalds/linux, master, fetched 2026-11-15) that name a fixed QMI
# interface number:
#   0121 4   {QMI_QUIRK_SET_DTR(0x2c7c, 0x0121, 4)},  /* Quectel EC21 Mini PCIe */
#   0191 4   {QMI_QUIRK_SET_DTR(0x2c7c, 0x0191, 4)},  /* Quectel EG91 */
#   0195 4   {QMI_QUIRK_SET_DTR(0x2c7c, 0x0195, 4)},  /* Quectel EG95 */
#   0296 4   {QMI_FIXED_INTF(0x2c7c, 0x0296, 4)},     /* Quectel BG96 */
#   030e 4   {QMI_QUIRK_SET_DTR(0x2c7c, 0x030e, 4)},  /* Quectel EM05GV2 */
#   0316 3   {QMI_QUIRK_SET_DTR(0x2c7c, 0x0316, 3)},  /* Quectel RG255C */
# The kernel's other Quectel entries match by class only (QMI_MATCH_FF_FF_FF), with no fixed
# interface number, so they are not in the list (README, "Supported models").
models='0801 4
0121 4
0191 4
0195 4
0296 4
030e 4
0316 3'

if [ "${1:-}" = --models ]; then
  echo "$models"
  exit 0
fi

plist=${1:-"$(dirname "$0")/../driver/Info.plist"}

failed=0
count=0
drivers=0

fail() {
  echo "personality check: $1: $2"
  failed=1
}

# The value of key in personality $1, printed raw; nothing (and a non-zero status) when the key is
# missing or, with a third argument, its value is not of that plist type.
value() {
  if [ $# -ge 3 ]; then
    plutil -extract "IOKitPersonalities.$1.$2" raw -expect "$3" -o - "$plist" 2>/dev/null
  else
    plutil -extract "IOKitPersonalities.$1.$2" raw -o - "$plist" 2>/dev/null
  fi
}

# True when $1 matches ^[A-Za-z0-9_-]{1,31}$ (rmnet::tty_name_ok accepts the same names).
name_ok() {
  case $1 in
    '' | *[!A-Za-z0-9_-]*) return 1 ;;
  esac
  [ "${#1}" -le 31 ]
}

# The QMI interface of product $1 (a decimal integer) in the model list; nothing when it is not there.
model_interface() {
  echo "$models" | while read -r hex ifn; do
    [ "$((0x$hex))" = "$1" ] && echo "$ifn"
  done
}

# An idProduct for a message: "289 (2c7c:0121)", or "(none, or not an integer)" when empty.
product_words() {
  if [ -n "$1" ]; then
    printf '%s (2c7c:%04x)' "$1" "$1"
  else
    printf '(none, or not an integer)'
  fi
}

if ! names=$(plutil -extract IOKitPersonalities raw -expect dictionary -o - "$plist" 2>/dev/null); then
  fail "$plist" "no IOKitPersonalities dictionary"
  names=
fi

while IFS= read -r name; do
  [ -n "$name" ] || continue
  count=$((count + 1))
  case $name in
    *.*)
      fail "$name" "the name has a '.', which a plutil key path cannot reach"
      continue
      ;;
  esac

  ifn=$(value "$name" bInterfaceNumber)
  ifn_int=$(value "$name" bInterfaceNumber integer)
  class=$(value "$name" IOUserClass string)
  product=$(value "$name" idProduct integer)

  # RMNetDriver for a listed product other than the RM520N-GL: checked against that product's QMI
  # interface (below), not against the RM520N-GL's interfaces.
  other=
  if [ "$class" = RMNetDriver ] && [ -n "$product" ] && [ "$product" != 2049 ]; then
    other=$(model_interface "$product")
  fi

  if [ -z "$other" ]; then
    case $ifn in
      2 | 3) fail "$name" "on interface $ifn, an AT port that no personality may match" ;;
    esac
  fi

  case $class in
    RMNetSerial)
      [ "$product" = 2049 ] || fail "$name" "RMNetSerial for idProduct $(product_words "$product"), not 2049 (2c7c:0801, the RM520N-GL, the only model with serial personalities)"
      case $ifn_int in
        0 | 1) ;;
        *) fail "$name" "RMNetSerial on interface ${ifn_int:-(none, or not an integer)}, not 0 or 1" ;;
      esac
      v=$(value "$name" IOClass string)
      [ "$v" = IOUserSerial ] || fail "$name" "IOClass ${v:-(none, or not a string)}, not IOUserSerial"
      v=$(value "$name" CFBundleIdentifierKernel string)
      [ "$v" = com.apple.driver.driverkit.serial ] ||
        fail "$name" "CFBundleIdentifierKernel ${v:-(none, or not a string)}, not com.apple.driver.driverkit.serial"
      if ! v=$(value "$name" RMNetSerialName string); then
        fail "$name" "RMNetSerialName missing or not a string"
      elif ! name_ok "$v"; then
        fail "$name" "RMNetSerialName '$v' is not 1 to 31 of A-Z, a-z, 0-9, '_' and '-'"
      fi
      ;;
    RMNetDriver)
      drivers=$((drivers + 1))
      if [ -n "$other" ]; then
        v=$(value "$name" idVendor integer)
        [ "$v" = 11388 ] || fail "$name" "idVendor ${v:-(none, or not an integer)}, not 11388 (0x2c7c)"
        [ "$ifn_int" = "$other" ] ||
          fail "$name" "RMNetDriver for 2c7c:$(printf '%04x' "$product") on interface ${ifn_int:-(none, or not an integer)}, not its QMI interface $other"
      else
        [ "$ifn_int" = 4 ] || fail "$name" "RMNetDriver on interface ${ifn_int:-(none, or not an integer)}, not 4"
        [ "$product" = 2049 ] ||
          fail "$name" "RMNetDriver for idProduct $(product_words "$product"), not a product in the model list"
      fi
      ;;
    *)
      fail "$name" "unknown IOUserClass ${class:-(none, or not a string)}"
      ;;
  esac
done <<EOF
$names
EOF

[ "$drivers" -gt 0 ] || fail "$plist" "no personality has IOUserClass RMNetDriver"

if [ "$failed" -ne 0 ]; then
  echo "personality check: failed"
  exit 1
fi
echo "personality check: $count personalities ok"
