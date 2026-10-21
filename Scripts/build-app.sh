#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Mantenimiento"
BUILD_CONFIGURATION="${1:-release}"
SWIFT_BIN="${ROOT_DIR}/.build/${BUILD_CONFIGURATION}/${APP_NAME}"
FANCTL_BIN="${ROOT_DIR}/.build/${BUILD_CONFIGURATION}/mantenimiento-fanctl"
HELPER_BIN="${ROOT_DIR}/.build/${BUILD_CONFIGURATION}/mantenimiento-helper"
APP_DIR="${ROOT_DIR}/.build/${BUILD_CONFIGURATION}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
HELPER_DIR="${CONTENTS_DIR}/Library/PrivilegedHelperTools"

cd "${ROOT_DIR}"
BUILD_OPTIONS=(-c "${BUILD_CONFIGURATION}")
if [[ -n "${MACOS_SDK_PATH:-}" ]]; then
    BUILD_OPTIONS+=(--sdk "${MACOS_SDK_PATH}")
fi
if [[ -n "${SWIFT_BUILD_SYSTEM:-}" ]]; then
    BUILD_OPTIONS+=(--build-system "${SWIFT_BUILD_SYSTEM}")
fi
swift build "${BUILD_OPTIONS[@]}"

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${HELPER_DIR}"
cp "${SWIFT_BIN}" "${MACOS_DIR}/${APP_NAME}"
if [[ -f "${FANCTL_BIN}" ]]; then
    cp "${FANCTL_BIN}" "${MACOS_DIR}/mantenimiento-fanctl"
fi
if [[ -f "${HELPER_BIN}" ]]; then
    cp "${HELPER_BIN}" "${HELPER_DIR}/local.marc.mantenimiento.helper"
fi

swift "${ROOT_DIR}/Scripts/generate-icon.swift" "${RESOURCES_DIR}"

cat > "${CONTENTS_DIR}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>es</string>
    <key>CFBundleExecutable</key>
    <string>Mantenimiento</string>
    <key>CFBundleIdentifier</key>
    <string>local.marc.mantenimiento</string>
    <key>CFBundleName</key>
    <string>Mantenimiento</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.3.5</string>
    <key>CFBundleVersion</key>
    <string>8</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSInputMonitoringUsageDescription</key>
    <string>Mantenimiento necesita monitorizar teclado y raton durante el modo Limpieza para bloquear la entrada mientras limpias el Mac.</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>Mantenimiento necesita Accesibilidad para interceptar temporalmente la entrada durante el modo Limpieza.</string>
    <key>NSHumanReadableCopyright</key>
    <string>Personal utility.</string>
</dict>
</plist>
PLIST

SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [[ -z "${SIGN_IDENTITY}" ]]; then
    if /usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/grep -q "Mantenimiento Local Code Signing"; then
        SIGN_IDENTITY="Mantenimiento Local Code Signing"
    else
        SIGN_IDENTITY="-"
    fi
fi

if [[ "${SIGN_IDENTITY}" == "-" ]]; then
    REQUIREMENTS_FILE="${ROOT_DIR}/.build/${BUILD_CONFIGURATION}/${APP_NAME}.requirements"
    printf 'designated => identifier "local.marc.mantenimiento"\n' > "${REQUIREMENTS_FILE}"

    if [[ -f "${MACOS_DIR}/mantenimiento-fanctl" ]]; then
        codesign --force --sign - "${MACOS_DIR}/mantenimiento-fanctl" >/dev/null
    fi
    if [[ -f "${HELPER_DIR}/local.marc.mantenimiento.helper" ]]; then
        codesign --force --sign - --identifier local.marc.mantenimiento.helper "${HELPER_DIR}/local.marc.mantenimiento.helper" >/dev/null
    fi
    codesign --force --sign - --requirements "${REQUIREMENTS_FILE}" "${APP_DIR}" >/dev/null
else
    SIGNING_OPTIONS=(--force --sign "${SIGN_IDENTITY}")
    if [[ "${SIGN_IDENTITY}" == Developer\ ID\ Application* ]]; then
        SIGNING_OPTIONS+=(--options runtime --timestamp)
    else
        SIGNING_OPTIONS+=(--timestamp=none)
    fi

    if [[ -f "${MACOS_DIR}/mantenimiento-fanctl" ]]; then
        codesign "${SIGNING_OPTIONS[@]}" "${MACOS_DIR}/mantenimiento-fanctl" >/dev/null
    fi
    if [[ -f "${HELPER_DIR}/local.marc.mantenimiento.helper" ]]; then
        codesign "${SIGNING_OPTIONS[@]}" --identifier local.marc.mantenimiento.helper "${HELPER_DIR}/local.marc.mantenimiento.helper" >/dev/null
    fi
    codesign "${SIGNING_OPTIONS[@]}" "${APP_DIR}" >/dev/null
fi

echo "${APP_DIR}"
