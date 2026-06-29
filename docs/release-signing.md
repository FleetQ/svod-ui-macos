# Release signing & Sparkle auto-update — setup

The app ships auto-update via **Sparkle** (appcast from GitHub Releases). The wiring is
in place (SPM dep, `Updater`, `Config/Info.plist` keys, `.github/workflows/release.yml`),
but Sparkle can only **install** an update when the build is **Developer-ID signed +
notarized** and the update archive is **EdDSA-signed** with the key matching
`SUPublicEDKey` in `Config/Info.plist`.

Until the secrets below are configured, `release.yml` takes the **unsigned** path:
it still publishes a `Svod.zip`, but with **no `appcast.xml`**, so "Check for Updates"
finds nothing to install. This is by design (non-fatal), not a bug.

## One-time setup

### 1. Sparkle EdDSA key
The public key is already committed in `Config/Info.plist`
(`SUPublicEDKey = tjHC4d/AW4IC/MJKOvftiezy501Fe+rq/rAGg2r4EhQ=`). The **private** key
is in the macOS login Keychain (created by Sparkle's `generate_keys`). Export it for CI:

```sh
# from the resolved Sparkle SPM artifact bin/, or a downloaded Sparkle release
./generate_keys -x sparkle_private_key.txt      # writes the private key
```
Store the file's contents as the GitHub Actions secret `SPARKLE_ED_PRIVATE_KEY`
(and keep a copy in 1Password). **Never commit it.** If it's ever lost, you must
generate a new keypair and ship a build with the new `SUPublicEDKey` before old clients
can validate updates again.

### 2. Apple Developer ID + notarization
- Export a **Developer ID Application** certificate as `.p12`; base64 it →
  `DEVELOPER_ID_P12`; its password → `DEVELOPER_ID_P12_PASSWORD`.
- Team ID (10 chars) → `DEVELOPMENT_TEAM`.
- An app-specific password for notarization → `NOTARY_PASSWORD`; Apple ID →
  `NOTARY_APPLE_ID`; team → `NOTARY_TEAM_ID`.

### 3. GitHub Actions secrets (repo → Settings → Secrets → Actions)
```
SPARKLE_ED_PRIVATE_KEY
DEVELOPER_ID_P12
DEVELOPER_ID_P12_PASSWORD
DEVELOPMENT_TEAM
NOTARY_APPLE_ID
NOTARY_PASSWORD
NOTARY_TEAM_ID
```

## Cutting a release
```sh
# bump MARKETING_VERSION in the Xcode project first (e.g. 0.2.0)
git tag v0.2.0 && git push origin v0.2.0
```
With the secrets present, CI signs → notarizes → staples → zips → EdDSA-signs →
generates `appcast.xml` → uploads `Svod-<v>.zip` + `appcast.xml` to the release. The
app's `SUFeedURL` (`…/releases/latest/download/appcast.xml`) then resolves to it and
"Check for Updates" can install.

## Validation boundary (this sprint)
The Sparkle integration was validated up to: SPM resolves (2.9.3), the app builds &
links & embeds `Sparkle.framework`, `Config/Info.plist` carries `SUFeedURL` /
`SUPublicEDKey` / `SUEnableAutomaticChecks`, and "Check for Updates…" is wired. The
**actual download/install** was **not** validatable here — no signing identity is
configured and no signed+notarized release with an appcast exists yet. Completing the
setup above is the remaining manual step.
