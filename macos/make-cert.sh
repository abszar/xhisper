#!/bin/bash
# Create the "xhisper Code Signing" identity once, in the login keychain.
# `make` signs Xhisper.app with it, so rebuilds keep the Accessibility and
# Input Monitoring grants (an ad-hoc signature changes on every build and macOS
# silently drops them). macOS asks for your password to trust the certificate.
NAME="xhisper Code Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists"
  exit 0
fi

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
cat > "$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

# /usr/bin/openssl (LibreSSL) on purpose: Homebrew's OpenSSL 3 writes PKCS#12
# files that `security import` rejects ("MAC verification failed").
/usr/bin/openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.cnf" \
  -keyout "$work/key.pem" -out "$work/cert.pem" || exit 1
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$NAME" \
  -passout pass:xhisper -out "$work/id.p12" || exit 1
security import "$work/id.p12" -k "$KEYCHAIN" -P xhisper -T /usr/bin/codesign || exit 1
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$work/cert.pem" || exit 1
security find-identity -v -p codesigning | grep "\"$NAME\""
