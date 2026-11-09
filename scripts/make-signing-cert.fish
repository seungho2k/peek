#!/usr/bin/env fish
# fish version of make-signing-cert.sh: creates the self-signed code-signing certificate
# "peek local" in the login keychain (once). build.sh signs with it when present, so the app
# keeps the same identity across rebuilds and the Accessibility permission sticks.
# Uses macOS's /usr/bin/openssl with SHA1/3DES: a .p12 from OpenSSL 3 (e.g. conda or
# Homebrew) fails `security import` with "MAC verification failed".
set NAME "peek local"

if security find-certificate -c "$NAME" >/dev/null 2>&1
    echo "\"$NAME\" already exists"
    exit 0
end

set TMP (mktemp -d)
function cleanup --on-event fish_exit
    rm -rf $TMP
end

printf '%s\n' \
    '[req]' \
    'distinguished_name = dn' \
    'x509_extensions = ext' \
    'prompt = no' \
    '[dn]' \
    "CN = $NAME" \
    '[ext]' \
    'basicConstraints = critical, CA:false' \
    'keyUsage = critical, digitalSignature' \
    'extendedKeyUsage = critical, codeSigning' >$TMP/cert.conf

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config $TMP/cert.conf \
    -keyout $TMP/key.pem -out $TMP/cert.pem 2>/dev/null
or begin; echo "openssl req failed"; exit 1; end

set PASS "peek-"(random)(random)
/usr/bin/openssl pkcs12 -export -inkey $TMP/key.pem -in $TMP/cert.pem -name "$NAME" \
    -out $TMP/cert.p12 -passout "pass:$PASS" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
or begin; echo "openssl pkcs12 failed"; exit 1; end

security import $TMP/cert.p12 -k $HOME/Library/Keychains/login.keychain-db \
    -P "$PASS" -T /usr/bin/codesign >/dev/null
or begin; echo "security import failed"; exit 1; end

echo "created \"$NAME\""
