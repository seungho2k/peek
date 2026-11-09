#!/bin/bash
# Creates a self-signed code-signing certificate "peek local" in the login keychain (once).
# build.sh signs with it when present, so the app keeps the same identity across rebuilds and
# macOS doesn't ask for the Accessibility permission again after every install.
# Uses macOS's /usr/bin/openssl with SHA1/3DES: a .p12 from OpenSSL 3 (e.g. conda or
# Homebrew) fails `security import` with "MAC verification failed".
set -euo pipefail
NAME="peek local"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "\"$NAME\" already exists"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.conf" <<EOF
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
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.conf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS="peek-$RANDOM$RANDOM"
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$TMP/cert.p12" -passout "pass:$PASS" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
security import "$TMP/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "created \"$NAME\""
