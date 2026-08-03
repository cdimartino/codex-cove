#!/bin/sh
set -eu

identity_name=${CODEX_COVE_SIGNING_IDENTITY:-"Codex Cove Local Code Signing"}
login_keychain=${CODEX_COVE_KEYCHAIN:-"$HOME/Library/Keychains/login.keychain-db"}

if security find-identity -v -p codesigning "$login_keychain" 2>/dev/null | grep -F "\"$identity_name\"" >/dev/null; then
    printf 'Signing identity already available: %s\n' "$identity_name"
    exit 0
fi

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/codex-cove-signing.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

private_key="$temporary_directory/private-key.pem"
certificate="$temporary_directory/certificate.pem"
archive="$temporary_directory/identity.p12"
archive_password=$(openssl rand -hex 24)

openssl req -x509 -newkey rsa:3072 -sha256 -nodes \
    -subj "/CN=$identity_name/O=Codex Cove Local" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    -addext "subjectKeyIdentifier=hash" \
    -days 3650 \
    -keyout "$private_key" \
    -out "$certificate"

openssl pkcs12 -export \
    -inkey "$private_key" \
    -in "$certificate" \
    -name "$identity_name" \
    -passout "pass:$archive_password" \
    -out "$archive"

security import "$archive" \
    -k "$login_keychain" \
    -P "$archive_password" \
    -T /usr/bin/codesign

printf '%s\n' \
    "Trusting the machine-local Codex Cove certificate for code signing in the login keychain." \
    "Remove it later with: security delete-certificate -c \"$identity_name\" \"$login_keychain\""
security add-trusted-cert \
    -d \
    -r trustRoot \
    -p codeSign \
    -k "$login_keychain" \
    "$certificate"

if ! security find-identity -v -p codesigning "$login_keychain" | grep -F "\"$identity_name\"" >/dev/null; then
    printf 'Identity import completed, but codesign cannot find it.\n' >&2
    printf 'Unlock the login keychain and run this script again.\n' >&2
    exit 1
fi

printf 'Created local signing identity: %s\n' "$identity_name"
