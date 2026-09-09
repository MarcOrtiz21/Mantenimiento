#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="/Applications/Mantenimiento.app"
HELPER_SOURCE="${APP_PATH}/Contents/Library/PrivilegedHelperTools/local.marc.mantenimiento.helper"
HELPER_DEST="/Library/PrivilegedHelperTools/local.marc.mantenimiento.helper"
PLIST_DEST="/Library/LaunchDaemons/local.marc.mantenimiento.helper.plist"
SOCKET_PATH="/var/run/local.marc.mantenimiento.helper.sock"
OWNER_UID="$(id -u)"
CLIENT_PATH="${APP_PATH}/Contents/MacOS/Mantenimiento"

"${ROOT_DIR}/Scripts/install-app.sh" >/dev/null

if [[ ! -x "${HELPER_SOURCE}" ]]; then
    echo "No se encontro el helper en ${HELPER_SOURCE}" >&2
    exit 1
fi

/usr/bin/codesign --verify --strict "${HELPER_SOURCE}"
CLIENT_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP_PATH}/Contents/Info.plist")"
CLIENT_REQUIREMENT="$(/usr/bin/codesign -d -r- "${APP_PATH}" 2>&1)"
CLIENT_CERT_SHA1="$(printf '%s\n' "${CLIENT_REQUIREMENT}" | /usr/bin/sed -n 's/.*certificate leaf = H"\([0-9A-Fa-f]*\)".*/\1/p')"

if [[ -z "${CLIENT_CERT_SHA1}" ]]; then
    echo "La app necesita una identidad de firma estable antes de instalar el helper." >&2
    exit 1
fi

TMP_SCRIPT="$(mktemp -t mantenimiento-helper-install.XXXXXX.sh)"
trap 'rm -f "${TMP_SCRIPT}"' EXIT

cat > "${TMP_SCRIPT}" <<SCRIPT
set -euo pipefail
mkdir -p /Library/PrivilegedHelperTools
cp "${HELPER_SOURCE}" "${HELPER_DEST}"
chown root:wheel "${HELPER_DEST}"
chmod 755 "${HELPER_DEST}"
cat > "${PLIST_DEST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>local.marc.mantenimiento.helper</string>
    <key>ProgramArguments</key>
    <array>
        <string>${HELPER_DEST}</string>
        <string>--socket</string>
        <string>${SOCKET_PATH}</string>
        <string>--owner-uid</string>
        <string>${OWNER_UID}</string>
        <string>--client-path</string>
        <string>${CLIENT_PATH}</string>
        <string>--client-identifier</string>
        <string>${CLIENT_IDENTIFIER}</string>
        <string>--client-cert-sha1</string>
        <string>${CLIENT_CERT_SHA1}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/var/log/mantenimiento-helper.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/mantenimiento-helper.err</string>
</dict>
</plist>
chown root:wheel "${PLIST_DEST}"
chmod 644 "${PLIST_DEST}"
launchctl bootout system/local.marc.mantenimiento.helper 2>/dev/null || true
launchctl bootout system "${PLIST_DEST}" 2>/dev/null || true
launchctl bootstrap system "${PLIST_DEST}"
launchctl enable system/local.marc.mantenimiento.helper
launchctl kickstart -k system/local.marc.mantenimiento.helper
SCRIPT

ESCAPED_COMMAND="$(printf '%s' "bash ${TMP_SCRIPT}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
/usr/bin/osascript -e "do shell script \"${ESCAPED_COMMAND}\" with administrator privileges"
echo "Helper instalado: ${PLIST_DEST}"
