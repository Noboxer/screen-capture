#!/usr/bin/env bash
# setup-signing.sh — create a persistent self-signed code-signing identity so that
# macOS keeps the app's Screen Recording + Accessibility (TCC) grants across
# rebuilds and in-app updates.
#
# Why this is needed: ad-hoc signing (`codesign --sign -`) has no stable identity,
# so every rebuild produces a new code hash and macOS treats the app as brand new,
# silently dropping its permissions. Signing with a stable self-signed certificate
# gives the app a designated requirement pinned to the certificate — so TCC keeps
# the grants even after the binary changes.
#
# Run this ONCE. You may be asked to approve keychain access (that's expected).
# After it succeeds, run ./install.sh — it auto-detects and uses this identity.
set -e

IDENTITY="ScreenCapture Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✓ Signing identity '$IDENTITY' already exists — nothing to do."
    exit 0
fi

echo "Creating self-signed code-signing identity '$IDENTITY'..."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

cat > cfg.cnf <<EOF
[req]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints   = critical,CA:false
keyUsage           = critical,digitalSignature
extendedKeyUsage   = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout key.pem -out cert.pem -days 3650 -config cfg.cnf >/dev/null 2>&1

# Apple's `security` tool can't verify the MAC on an empty-password PKCS#12 built
# by OpenSSL 3. Use a throwaway password and, when the OpenSSL 3 `-legacy` flag is
# available, the legacy algorithms macOS understands. (System LibreSSL doesn't know
# `-legacy` and doesn't need it.)
P12PW="screencapture-local"
if openssl pkcs12 -help 2>&1 | grep -q -- "-legacy"; then
    LEGACY="-legacy"
else
    LEGACY=""
fi
openssl pkcs12 -export $LEGACY -inkey key.pem -in cert.pem -out id.p12 -passout pass:"$P12PW" >/dev/null 2>&1

# -A lets codesign use the key without a per-signing prompt.
security import id.p12 -k "$KEYCHAIN" -P "$P12PW" -T /usr/bin/codesign -A
# Allow Apple codesigning tools to use the key non-interactively (best effort;
# an empty keychain password is assumed — if yours differs you may get one prompt
# the first time you codesign, which is harmless).
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

# One-time migration: clear any TCC entries left by earlier ad-hoc builds so the
# permission lists don't show a stale, un-toggleable duplicate. macOS forbids an
# app from editing its own TCC grants, so this must happen here (outside the app).
# After this, the newly-signed build prompts fresh and you approve it once.
tccutil reset ScreenCapture  com.thea.screencapture >/dev/null 2>&1 || true
tccutil reset Accessibility  com.thea.screencapture >/dev/null 2>&1 || true

echo ""
echo "✓ Created '$IDENTITY' and cleared stale permission entries."
echo "  Now run ./install.sh — it signs with this identity; approve Screen Recording"
echo "  + Accessibility once and the grants will survive future updates."
