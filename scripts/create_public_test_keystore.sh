#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 output.p12" >&2
    exit 2
fi

root=$(cd "$(dirname "$0")/.." && pwd)
certificate="$root/android/signing/neuromesh-public-test.pem"
fixture_url='https://android.googlesource.com/platform/tools/apksig/+/184702d9d18877edf9e5296c4e191cf0aa2b5fbb/src/test/resources/com/android/apksig/rsa-2048_3.pk8?format=TEXT'
fixture_digest=04cdfb0d8fb446fb1d0a1492233a245f5331a9dc1a6cd286f99c58b0fa948f4a

# This upstream key is public. Use it only for the isolated test application ID.
scratch=$(mktemp -d)
trap 'rm -r -- "$scratch"' EXIT
umask 077
curl -fsSL --retry 3 "$fixture_url" | base64 -d > "$scratch/test.pk8"
printf '%s  %s\n' "$fixture_digest" "$scratch/test.pk8" | sha256sum --check --status
openssl pkcs8 -inform DER -nocrypt -in "$scratch/test.pk8" -out "$scratch/test.pem"
openssl pkcs12 -export -inkey "$scratch/test.pem" -in "$certificate" \
    -name neuromesh-test -passout pass:android -out "$1"
openssl x509 -in "$certificate" -outform DER | sha256sum | cut -d ' ' -f 1
