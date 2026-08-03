#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACT_DIR="${PACKAGE_DIR}/Artifacts"

cd "${PACKAGE_DIR}"
checksum_output="$(shasum -a 256 -c Artifacts/SHA256SUMS 2>&1)" || {
    echo "${checksum_output}" >&2
    exit 1
}

for framework in COpenSSL CLibSSH2; do
    info="${ARTIFACT_DIR}/${framework}.xcframework/Info.plist"
    [[ -f "${info}" ]] || {
        echo "error: missing ${framework} Info.plist" >&2
        exit 1
    }

    plutil -convert json -o - "${info}" \
        | grep -q '"SupportedArchitectures".*"arm64"' || {
            echo "error: ${framework} has no arm64 slice" >&2
            exit 1
        }
    plutil -convert json -o - "${info}" \
        | grep -q '"SupportedPlatformVariant":"simulator"' || {
            echo "error: ${framework} has no Simulator slice" >&2
            exit 1
        }
done

for framework in "${ARTIFACT_DIR}/COpenSSL.xcframework"/*/COpenSSL.framework; do
    configuration="${framework}/Headers/openssl/configuration.h"
    [[ -f "${configuration}" ]] || {
        echo "error: missing OpenSSL configuration header in ${framework}" >&2
        exit 1
    }

    for feature in \
        ARIA BF CAMELLIA CAST DEPRECATED DES DSA IDEA RC2 RC4 RMD160 SEED \
        SM2 SM3 SM4 WHIRLPOOL; do
        grep -Eq "^[[:space:]]*#[[:space:]]*define OPENSSL_NO_${feature}([[:space:]]|$)" \
            "${configuration}" || {
                echo "error: OpenSSL ${feature} support is enabled in ${framework}" >&2
                exit 1
            }
    done

    if strings "${framework}/COpenSSL" \
        | grep -Eqi 'legacy provider|providers/legacy|legacy\.so|ossl_legacy_provider_init'; then
        echo "error: OpenSSL legacy provider found in ${framework}" >&2
        exit 1
    fi
done

for library in "${ARTIFACT_DIR}/CLibSSH2.xcframework"/*/CLibSSH2.framework/CLibSSH2; do
    forbidden="$({ strings "${library}" || true; } | grep -E '^(ssh-dss|diffie-hellman-group1-sha1|diffie-hellman-group14-sha1|diffie-hellman-group-exchange-sha1|hmac-sha1|hmac-sha1-96|aes(128|192|256)-cbc|3des-cbc|blowfish-cbc|arcfour|cast128-cbc)$' || true)"
    if [[ -n "${forbidden}" ]]; then
        echo "error: legacy SSH methods found in ${library}:" >&2
        echo "${forbidden}" >&2
        exit 1
    fi
done

grep -q 'OpenSSL features:.*legacy provider' Artifacts/PROVENANCE.md
grep -q 'libssh2 crypto backend: OpenSSL' Artifacts/PROVENANCE.md

echo "HeelerSSH artifact checksums, slices, provenance, and algorithm policy are valid."
