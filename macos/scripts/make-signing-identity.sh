#!/usr/bin/env bash
# Creates the "Bookshelf Local" code-signing identity in the login keychain, once
# (docs/MACOS_APP.md M11, §18): a self-signed certificate and its private key. A stable
# identity keeps the app's designated requirement the same across rebuilds, so macOS keeps
# the app's permissions; an ad-hoc signature changes with every build.
#
#   macos/scripts/make-signing-identity.sh
#
# Does nothing when the identity is already there. The key is made on this Mac and stays in
# the keychain; the temporary files are deleted. The first codesign with it may make macOS
# ask whether codesign may use the key: choose Always Allow.
set -euo pipefail

NAME="Bookshelf Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL=/usr/bin/openssl  # LibreSSL: its PKCS#12 encryption is what `security import` reads

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
  echo "\"$NAME\" is already in the login keychain."
  exit 0
fi

umask 077
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PASS="$("$OPENSSL" rand -hex 16)"  # protects the temporary .p12 only
"$OPENSSL" pkcs12 -export -name "$NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout "pass:$PASS"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -f pkcs12 -P "$PASS" -T /usr/bin/codesign

security find-identity -p codesigning "$KEYCHAIN" | grep "\"$NAME\""
