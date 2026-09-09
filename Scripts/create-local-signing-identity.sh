#!/usr/bin/env bash
set -euo pipefail

IDENTITY_NAME="${CODE_SIGN_IDENTITY:-Mantenimiento Local Code Signing}"
KEYCHAIN="${KEYCHAIN_PATH:-$(/usr/bin/security default-keychain -d user | /usr/bin/sed 's/^ *//; s/"//g')}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${ROOT_DIR}/.build/local-signing"
CONFIG_FILE="${WORK_DIR}/openssl-code-signing.cnf"
KEY_FILE="${WORK_DIR}/${IDENTITY_NAME// /_}.key"
CERT_FILE="${WORK_DIR}/${IDENTITY_NAME// /_}.crt"
P12_FILE="${WORK_DIR}/${IDENTITY_NAME// /_}.p12"
OPENSSL_BIN="${OPENSSL_BIN:-$(command -v openssl)}"

if [[ -z "${OPENSSL_BIN}" ]]; then
    echo "No se encontro openssl en PATH."
    exit 1
fi

if /usr/bin/security find-identity -v -p codesigning "${KEYCHAIN}" 2>/dev/null | /usr/bin/grep -Fq "${IDENTITY_NAME}"; then
    echo "La identidad '${IDENTITY_NAME}' ya existe en ${KEYCHAIN}."
    exit 0
fi

mkdir -p "${WORK_DIR}"
chmod 700 "${WORK_DIR}"

cat > "${CONFIG_FILE}" <<EOF_CONFIG
[ req ]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = code_signing

[ dn ]
CN = ${IDENTITY_NAME}

[ code_signing ]
basicConstraints = critical,CA:true
keyUsage = critical,digitalSignature,keyCertSign
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF_CONFIG

echo "Creando certificado local '${IDENTITY_NAME}'..."
"${OPENSSL_BIN}" req \
    -x509 \
    -newkey rsa:2048 \
    -sha256 \
    -days 3650 \
    -nodes \
    -keyout "${KEY_FILE}" \
    -out "${CERT_FILE}" \
    -config "${CONFIG_FILE}" >/dev/null 2>&1

P12_PASSWORD="$("${OPENSSL_BIN}" rand -base64 32)"
"${OPENSSL_BIN}" pkcs12 \
    -export \
    -inkey "${KEY_FILE}" \
    -in "${CERT_FILE}" \
    -name "${IDENTITY_NAME}" \
    -out "${P12_FILE}" \
    -passout "pass:${P12_PASSWORD}" >/dev/null 2>&1

echo "Importando identidad en ${KEYCHAIN}..."
/usr/bin/security import "${P12_FILE}" \
    -k "${KEYCHAIN}" \
    -f pkcs12 \
    -P "${P12_PASSWORD}" \
    -T /usr/bin/codesign >/dev/null

echo "Marcando el certificado como confianza local para firma de codigo..."
if ! /usr/bin/security add-trusted-cert -r trustRoot -p codeSign -k "${KEYCHAIN}" "${CERT_FILE}" >/dev/null 2>&1; then
    echo "No se pudo marcar la confianza automaticamente."
    echo "Abre Acceso a Llaveros, busca '${IDENTITY_NAME}' y marca Confiar > Firma de codigo > Confiar siempre."
fi

/usr/bin/security find-identity -v -p codesigning "${KEYCHAIN}" | /usr/bin/grep -F "${IDENTITY_NAME}" || {
    echo "La identidad se importo, pero aun no aparece como valida para codesign."
    echo "Puede que macOS necesite que confirmes la confianza del certificado en Acceso a Llaveros."
    exit 1
}

rm -f "${P12_FILE}"
chmod 600 "${KEY_FILE}" "${CERT_FILE}" "${CONFIG_FILE}"

echo "Identidad local lista: ${IDENTITY_NAME}"
