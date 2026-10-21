#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"${ROOT_DIR}/Scripts/install-app.sh" >/dev/null
/Applications/Mantenimiento.app/Contents/MacOS/Mantenimiento --install-helper
echo "Helper instalado."
