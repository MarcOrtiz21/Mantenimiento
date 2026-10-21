#!/usr/bin/env bash
set -euo pipefail

APP_BINARY="/Applications/Mantenimiento.app/Contents/MacOS/Mantenimiento"
if [[ ! -x "${APP_BINARY}" ]]; then
    echo "Instala Mantenimiento para retirar el helper de forma segura." >&2
    exit 1
fi
"${APP_BINARY}" --uninstall-helper
echo "Helper eliminado."
