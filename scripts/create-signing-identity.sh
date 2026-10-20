#!/usr/bin/env bash
# Creates the MacEase Release signing identity.
# Usage: scripts/create-signing-identity.sh [--set-secrets] [output-dir]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
identity="MacEase Release"
validity_days=3650
key_bits=2048
set_secrets=0

if [[ "${1:-}" == "--set-secrets" ]]; then
    set_secrets=1
    shift
fi
out="${1:-$root/build/signing}"
[[ "$out" == /* ]] || out="$PWD/$out"

# Keys inside the repository must stay ignored.
if [[ "$out/" == "$root"/* ]] && ! git -C "$root" check-ignore -q "$out/"; then
    echo "error: $out is inside the repository but not git-ignored" >&2
    exit 1
fi
if [[ -d "$out" && -n "$(ls -A "$out")" ]]; then
    echo "error: $out is not empty; refusing to overwrite an existing identity" >&2
    exit 1
fi

umask 077
mkdir -p "$out"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat >"$work/openssl.cnf" <<'EOF'
[req]
distinguished_name = subject
prompt = no
[subject]
CN = MacEase Release
[codesign]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey "rsa:$key_bits" -nodes -sha256 -days "$validity_days" \
    -config "$work/openssl.cnf" -extensions codesign \
    -keyout "$work/key.pem" -out "$out/certificate.pem" 2>/dev/null

MACEASE_CERT_PASSWORD="$(openssl rand -hex 32)"
export MACEASE_CERT_PASSWORD
p12="$out/MacEase-Release.p12"
# Older `security import` versions reject PBES2 archives.
openssl pkcs12 -export -name "$identity" -inkey "$work/key.pem" -in "$out/certificate.pem" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -passout env:MACEASE_CERT_PASSWORD -out "$p12"

if [[ "$set_secrets" == 1 ]]; then
    base64 -i "$p12" | gh secret set MACEASE_CERT_P12_BASE64
    printf '%s' "$MACEASE_CERT_PASSWORD" | gh secret set MACEASE_CERT_PASSWORD
fi

cat <<EOF
Created "$identity" in $out.
Back up $p12 and the password below; a new identity resets user privacy grants.

MACEASE_CERT_PASSWORD=$MACEASE_CERT_PASSWORD
MACEASE_CERT_P12_BASE64=$(base64 -i "$p12")
EOF
