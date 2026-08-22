#!/usr/bin/env bash
# Creates a stable self-signed code-signing identity in your login keychain.
#
# WHY THIS EXISTS
#
# An ad-hoc signature's designated requirement is the hash of the code:
#
#     # designated => cdhash H"bf2759a7674105c875b1207d4a9389135a30cc74"
#
# TCC pins Accessibility grants to that requirement. Change one line of
# Swift and the hash changes, the requirement stops matching, and macOS
# silently revokes the grant — so you re-authorise on every single build.
#
# Signing with a stable certificate makes the requirement identity-based
# instead, and the grant survives rebuilds.
#
# This is free and entirely local. It is NOT an Apple Developer ID, it
# cannot notarise, and apps signed with it are still Gatekeeper-blocked
# when downloaded through a browser.
#
# This script will prompt for your login keychain password when it adds
# the certificate to the trust settings. That prompt is macOS, not us.
set -euo pipefail

NAME="${1:-CreativeNotch Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "identity '$NAME' already exists — nothing to do."
  security find-identity -v -p codesigning | grep "$NAME"
  exit 0
fi

echo "==> generating a self-signed code-signing certificate: $NAME"

# A config file rather than -addext: macOS ships LibreSSL, whose `req` does
# not support -addext. This form works on a stock Mac and with Homebrew's
# OpenSSL alike.
cat > "$WORK/ext.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions    = codesign
prompt             = no
[ dn ]
CN = $NAME
[ codesign ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
CNF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -config "$WORK/ext.cnf" >/dev/null 2>&1

/usr/bin/openssl pkcs12 -export -out "$WORK/identity.p12" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -passout pass: >/dev/null 2>&1

echo "==> importing into the login keychain"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "==> trusting it for code signing (macOS will ask for your password)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo "==> allowing codesign to use the key without prompting each time"
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -k "" "$KEYCHAIN" >/dev/null 2>&1 || \
  echo "    (could not set partition list — codesign may prompt once per build)"

echo
if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "done. use it with:"
  echo
  echo "    export CODESIGN_IDENTITY=\"$NAME\""
  echo "    ./Scripts/dev.sh"
  echo
  echo "add that export to your shell profile to make it permanent."
else
  echo "the identity was created but is not showing as valid for code signing." >&2
  echo "open Keychain Access, find '$NAME', and set its trust for" >&2
  echo "'Code Signing' to 'Always Trust'." >&2
  exit 1
fi
