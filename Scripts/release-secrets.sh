# Sourced by Scripts/release.sh when RELEASE_SECRETS=op — never run on its own.
#
# Lets a release run with nobody at the Mac. The login keychain cannot be unlocked from a
# background launchd session (codesign fails with errSecInternalComponent, notarytool with
# keychainLocked), so everything the release signs with comes from 1Password through the
# Service Account instead:
#
#   op://AI Agent/Svod release signing/
#     developer-id.p12      file     Developer ID Application certificate + private key
#     p12-password          password password of that .p12
#     asc-api-key.p8        file     App Store Connect API key (notarytool --key)
#     asc-key-id            text     its Key ID
#     asc-issuer-id         text     its Issuer ID
#     sparkle-ed25519.key   file     Sparkle EdDSA private key (generate_keys -x)
#
# The certificate goes into a throwaway keychain with a random password, placed first in the
# search list for this run only. Secret files live in a 0700 temp dir. The EXIT trap restores
# the search list and deletes both, on success and on failure.

OP_ITEM="${OP_ITEM:-op://AI Agent/Svod release signing}"

if [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
  [ -r "$HOME/.config/op/sa-token" ] || { echo "ERROR: RELEASE_SECRETS=op needs OP_SERVICE_ACCOUNT_TOKEN or ~/.config/op/sa-token" >&2; exit 1; }
  OP_SERVICE_ACCOUNT_TOKEN="$(cat "$HOME/.config/op/sa-token")"
  export OP_SERVICE_ACCOUNT_TOKEN
fi

SECRETS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/svod-release.XXXXXX")"
chmod 700 "$SECRETS_DIR"
RELEASE_KEYCHAIN="$SECRETS_DIR/release.keychain-db"
ORIGINAL_KEYCHAINS="$(security list-keychains -d user | tr -d '"' | xargs)"

release_secrets_cleanup() {
  # shellcheck disable=SC2086 — the list is whitespace-separated paths without spaces
  security list-keychains -d user -s $ORIGINAL_KEYCHAINS >/dev/null 2>&1 || true
  security delete-keychain "$RELEASE_KEYCHAIN" >/dev/null 2>&1 || true
  rm -rf "$SECRETS_DIR"
}
trap release_secrets_cleanup EXIT

echo "==> signing material from 1Password ($OP_ITEM)"
op read --force --out-file "$SECRETS_DIR/developer-id.p12" "$OP_ITEM/developer-id.p12" >/dev/null
op read --force --out-file "$SECRETS_DIR/asc-api-key.p8" "$OP_ITEM/asc-api-key.p8" >/dev/null
op read --force --out-file "$SECRETS_DIR/sparkle-ed25519.key" "$OP_ITEM/sparkle-ed25519.key" >/dev/null
chmod 600 "$SECRETS_DIR"/*
ASC_KEY_ID="$(op read "$OP_ITEM/asc-key-id")"
ASC_ISSUER_ID="$(op read "$OP_ITEM/asc-issuer-id")"
SPARKLE_KEY_FILE="$SECRETS_DIR/sparkle-ed25519.key"
ASC_KEY_FILE="$SECRETS_DIR/asc-api-key.p8"

keychain_password="$(openssl rand -hex 32)"
security create-keychain -p "$keychain_password" "$RELEASE_KEYCHAIN"
security set-keychain-settings -lut 7200 "$RELEASE_KEYCHAIN"
security unlock-keychain -p "$keychain_password" "$RELEASE_KEYCHAIN"
security import "$SECRETS_DIR/developer-id.p12" -k "$RELEASE_KEYCHAIN" \
  -P "$(op read "$OP_ITEM/p12-password")" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
# Without the partition list codesign still asks for a UI confirmation, which a background session cannot give.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$RELEASE_KEYCHAIN" >/dev/null
unset keychain_password
# shellcheck disable=SC2086
security list-keychains -d user -s "$RELEASE_KEYCHAIN" $ORIGINAL_KEYCHAINS
rm -f "$SECRETS_DIR/developer-id.p12"

# Sign by SHA-1 so a copy of the same certificate in the (locked) login keychain is never picked.
SIGN_IDENTITY="$(security find-identity -v -p codesigning "$RELEASE_KEYCHAIN" | awk '/Developer ID Application/ {print $2; exit}')"
[ -n "$SIGN_IDENTITY" ] || { echo "ERROR: the .p12 from 1Password holds no Developer ID Application identity" >&2; exit 1; }
echo "    identity $SIGN_IDENTITY in a temporary keychain"
