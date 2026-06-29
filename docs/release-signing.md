# Releasing & signing the macOS app

Svod for macOS auto-updates via **Sparkle**. The feed is a single `appcast.xml`
committed at the repo root and served from `raw.githubusercontent.com/FleetQ/svod-ui-macos/main/appcast.xml`
(`SUFeedURL` in `Config/Info.plist`). Each release prepends a signed `<item>`. This is
the same model as the Lattice app — releases are cut **locally** (where the signing
identity + notary credential live), not in CI.

## One command
```sh
Scripts/release.sh 0.2.0           # build + sign + DMG + notarize + appcast (no publish)
PUBLISH=1 Scripts/release.sh 0.2.0 # …then gh release + commit/push appcast
```
`release.sh` does: archive (Release) → `exportArchive` Developer-ID → DMG (hdiutil) →
codesign DMG → `notarytool submit --wait` → `stapler staple` → Sparkle `sign_update`
(EdDSA) → prepend the `<item>` to `appcast.xml`. Flags: `SKIP_NOTARIZE=1` (local dry
run), `PUBLISH=1` (publish), `NOTARY_PROFILE` / `TEAM` overrides.

## Prerequisites (one-time, on the release Mac)
- **Developer ID Application** certificate in the login keychain
  (`security find-identity -v -p codesigning` → currently
  `Developer ID Application: PRICEX LTD EOOD (UQK5BS5U9A)`).
- A **notarytool keychain profile**. The existing `lattice-notary` profile works for
  any app under the same team, so it is reused (override with `NOTARY_PROFILE`). To
  create a fresh one:
  ```sh
  xcrun notarytool store-credentials svod-notary \
    --apple-id you@example.com --team-id UQK5BS5U9A --password <app-specific-password>
  ```
- **Sparkle EdDSA key** in the login Keychain. Public key is committed in
  `Config/Info.plist` (`SUPublicEDKey = tjHC4d/AW4IC/MJKOvftiezy501Fe+rq/rAGg2r4EhQ=`);
  the matching private key signs each DMG via `sign_update`. Never commit the private
  key. If lost: generate a new keypair, ship a build with the new `SUPublicEDKey`.

## Notes
- The appcast lives on `main`; `PUBLISH=1` commits + pushes it, so the new version is
  visible to existing installs within minutes (raw.githubusercontent cache ~5 min).
- Gatekeeper acceptance requires the notarized + stapled DMG — `SKIP_NOTARIZE=1` builds
  are for local testing only.
- There is intentionally **no CI release workflow** for the app: signing identities and
  notarization credentials stay on the operator's machine.
