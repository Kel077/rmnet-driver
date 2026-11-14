#!/bin/sh
# Checks which USB interfaces the dext's personalities may match, before anything is built or
# installed. The modem's interfaces 2 and 3 are its AT ports (the owner's console and the app's
# SMS), so no personality may match them; RMNetSerial may match only 0 (DIAG) and 1 (NMEA), with
# Apple's serial kernel class and a usable port name; RMNetDriver only 4 (QMI); and a personality
# of any other IOUserClass, or none, is refused. RMNetSerial checks the interface's class, subclass
# and protocol again in Start; this check catches a wrong personality before it reaches the modem.
# The messages show the typed values the checks compare (an integer or a string): a value that is
# missing or of another type shows as "(none, or not an integer)" or "(none, or not a string)".
#
# Usage: scripts/check-personalities.sh [plist]   (default: driver/Info.plist)
set -u

LC_ALL=C
export LC_ALL

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
  case $ifn in
    2 | 3) fail "$name" "on interface $ifn, an AT port that no personality may match" ;;
  esac

  ifn_int=$(value "$name" bInterfaceNumber integer)
  class=$(value "$name" IOUserClass string)
  case $class in
    RMNetSerial)
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
      [ "$ifn_int" = 4 ] || fail "$name" "RMNetDriver on interface ${ifn_int:-(none, or not an integer)}, not 4"
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
