#!/usr/bin/env bash
# Create a stable, self-signed code-signing identity for WinHub so macOS TCC grants
# (Accessibility, Screen Recording) survive rebuilds. Ad-hoc signing ("-") changes
# the code hash every build, which resets those grants; a fixed, trusted cert keeps
# the bundle's Designated Requirement constant, so you grant once.
#
# The identity lives in its own keychain (winhub-dev) with a throwaway password, so
# *signing* is non-interactive. The one step that needs your password is trusting
# the cert for code signing — macOS guards the trust store by design.
#
# Run:      Scripts/dev_identity.sh            (creates + trusts; prompts for password)
# Teardown: Scripts/dev_identity.sh --remove
set -euo pipefail

IDENTITY="WinHub Dev"
KC_PASS="winhub-dev"
KC="$HOME/Library/Keychains/winhub-dev.keychain-db"
CERT="$HOME/Library/Keychains/winhub-dev-cert.pem"

if [ "${1:-}" = "--remove" ]; then
    security delete-keychain "$KC" 2>/dev/null && echo "Removed '$IDENTITY' keychain." || echo "No keychain to remove."
    rm -f "$CERT"
    echo "If you trusted the cert, remove its trust in Keychain Access → login → Certificates (optional)."
    exit 0
fi

# Already set up AND trusted?
if security find-identity -p codesigning -v "$KC" 2>/dev/null | grep -q "$IDENTITY"; then
    echo "Identity '$IDENTITY' already set up and trusted — nothing to do."
    exit 0
fi

# Create the keychain + identity unless an (untrusted) one is already present.
if ! security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$IDENTITY"; then
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    echo "==> Generating self-signed code-signing certificate…"
    cat > "$TMP/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints   = critical,CA:FALSE
keyUsage           = critical,digitalSignature
extendedKeyUsage   = critical,codeSigning
EOF
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf" >/dev/null 2>&1
    # -legacy: OpenSSL 3's default PKCS12 envelope is unreadable by Apple's Security
    # framework; the legacy SHA1/3DES envelope imports cleanly via `security import`.
    openssl pkcs12 -export -legacy -name "$IDENTITY" \
        -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:winhub >/dev/null 2>&1

    echo "==> Creating dedicated keychain ${KC}…"
    security delete-keychain "$KC" 2>/dev/null || true
    security create-keychain -p "$KC_PASS" "$KC"
    security set-keychain-settings "$KC"                   # no auto-lock timeout
    security unlock-keychain -p "$KC_PASS" "$KC"
    security import "$TMP/id.p12" -k "$KC" -P winhub -T /usr/bin/codesign >/dev/null
    # Authorize codesign to use the private key without a GUI prompt at sign time.
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KC" >/dev/null 2>&1
fi

# Trust the cert for code signing (user domain). This is the step that asks for your
# password — codesign refuses an untrusted identity (CSSMERR_TP_NOT_TRUSTED).
security find-certificate -c "$IDENTITY" -p "$KC" > "$CERT"
echo "==> Trusting '$IDENTITY' for code signing (you'll be asked for your login password)…"
security add-trusted-cert -r trustRoot -p codeSign "$CERT"

# codesign resolves signing identities via the keychain search list, so add ours
# (preserving the existing entries). Idempotent.
if ! security list-keychains -d user | grep -q "winhub-dev.keychain"; then
    security list-keychains -d user -s "$KC" $(security list-keychains -d user | xargs -n1)
fi

echo "==> Verifying…"
security find-identity -p codesigning -v "$KC" | sed 's/^/    /'
echo "==> Done. Rebuild with ./build.sh — it now signs with '$IDENTITY' automatically."
