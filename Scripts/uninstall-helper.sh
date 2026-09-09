#!/usr/bin/env bash
set -euo pipefail

HELPER_DEST="/Library/PrivilegedHelperTools/local.marc.mantenimiento.helper"
PLIST_DEST="/Library/LaunchDaemons/local.marc.mantenimiento.helper.plist"
SOCKET_PATH="/var/run/local.marc.mantenimiento.helper.sock"

TMP_SCRIPT="$(mktemp -t mantenimiento-helper-uninstall.XXXXXX.sh)"
trap 'rm -f "${TMP_SCRIPT}"' EXIT

cat > "${TMP_SCRIPT}" <<SCRIPT
set -euo pipefail
launchctl bootout system/local.marc.mantenimiento.helper 2>/dev/null || true
launchctl bootout system "${PLIST_DEST}" 2>/dev/null || true
rm -f "${PLIST_DEST}" "${HELPER_DEST}" "${SOCKET_PATH}"
SCRIPT

ESCAPED_COMMAND="$(printf '%s' "bash ${TMP_SCRIPT}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
/usr/bin/osascript -e "do shell script \"${ESCAPED_COMMAND}\" with administrator privileges"
echo "Helper eliminado."
