#!/usr/bin/env bash
# Creates a self-signed code-signing identity for the fork. Idempotent.
# A stable identity lets TCC key grants on the cert leaf instead of the
# ad-hoc CDHash, so privacy prompts survive rebuilds.
set -euo pipefail

CN="${1:-ghostty-fork-dev}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-certificate -c "${CN}" >/dev/null 2>&1; then
  echo "✓ identity '${CN}' already in keychain"
  security find-certificate -c "${CN}" -Z 2>&1 | grep '^SHA-1'
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
OPENSSL=/usr/bin/openssl  # Apple LibreSSL — writes PKCS12 that `security import` accepts

cat >"${tmp}/csr.conf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = ${CN}
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

"${OPENSSL}" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "${tmp}/key.pem" -out "${tmp}/cert.pem" \
  -config "${tmp}/csr.conf"

pw="$(head -c12 /dev/urandom | base64)"
"${OPENSSL}" pkcs12 -export -inkey "${tmp}/key.pem" -in "${tmp}/cert.pem" \
  -out "${tmp}/id.p12" -passout pass:"${pw}"

security import "${tmp}/id.p12" -k "${KEYCHAIN}" -P "${pw}" \
  -T /usr/bin/codesign -T /usr/bin/security

# Allow codesign to use the key without a prompt every build.
security set-key-partition-list -S apple-tool:,apple: -s \
  -k "" -D "${CN}" "${KEYCHAIN}" >/dev/null 2>&1 || \
  echo "  (skip: set-key-partition-list needs your login-keychain password — codesign may prompt once)"

echo "✓ created self-signed identity '${CN}'"
security find-certificate -c "${CN}" -Z 2>&1 | grep '^SHA-1'
