#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Mantenimiento.app"
SOURCE_APP="${ROOT_DIR}/.build/release/${APP_NAME}"
DEST_APP="/Applications/${APP_NAME}"

"${ROOT_DIR}/Scripts/build-app.sh"

rm -rf "${DEST_APP}"
/usr/bin/ditto "${SOURCE_APP}" "${DEST_APP}"
echo "${DEST_APP}"
