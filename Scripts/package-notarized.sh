#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Mantenimiento"
APP_PATH="${ROOT_DIR}/.build/release/${APP_NAME}.app"
DIST_DIR="${ROOT_DIR}/dist"
ZIP_PATH="${DIST_DIR}/${APP_NAME}.zip"
SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

if [[ -z "${SIGN_IDENTITY}" || -z "${NOTARY_PROFILE}" ]]; then
    echo "Uso:" >&2
    echo "  DEVELOPER_ID_APPLICATION='Developer ID Application: ...' NOTARY_PROFILE='perfil-notarytool' $0" >&2
    exit 2
fi

CODE_SIGN_IDENTITY="${SIGN_IDENTITY}" "${ROOT_DIR}/Scripts/build-app.sh" release >/dev/null
/usr/bin/codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"
/usr/bin/ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"

/usr/bin/xcrun notarytool submit "${ZIP_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait
/usr/bin/xcrun stapler staple "${APP_PATH}"
/usr/sbin/spctl --assess --type execute --verbose=2 "${APP_PATH}"

echo "Paquete notarizado: ${APP_PATH}"
