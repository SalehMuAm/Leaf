# Releasing Leaf

The first public beta is **1.2.1**, with the prerelease tag **`v1.2.1-beta.1`**. The app version and build number are defined in the `Info.plist` template in [`scripts/build-app.sh`](../scripts/build-app.sh): version `1.2.1`, build `4`.

## Prepare and verify

1. Update the app version and increment the build number for a new release. Update [CHANGELOG.md](../CHANGELOG.md), and confirm [LICENSE](../LICENSE) is included.
2. Work from the commit intended for the release. Run the tests and build the package:

   ```bash
   swift test
   ./scripts/package-release.sh
   ```

3. Record the actual macOS version, Swift version, SDK, architecture, and test result. PDFKit rendering tests need access to macOS graphics services.

The current verified environment is Apple silicon (`arm64`), macOS 26.6.2, Swift 6.3.3, and the macOS 26.5 SDK, with 65 passing tests. The deployment target is macOS 14. This does not establish compatibility on every macOS release from 14 onward. The current beta has no verified Intel or universal build.

## Package contents

`package-release.sh` builds the release app, reads its version and binary architecture, and creates the ZIP and SHA-256 file in `dist/`. For the current Apple silicon build:

- `Leaf.app`
- `Leaf-1.2.1-macos-arm64.zip`
- `Leaf-1.2.1-macos-arm64.zip.sha256`

The app includes its icon, welcome PDF, bundled resources, and MIT license. Build architecture comes from the produced binary; running the script on another architecture is not a substitute for testing that architecture.

Verify the checksum from the output directory:

```bash
cd dist
shasum -a 256 -c Leaf-1.2.1-macos-arm64.zip.sha256
```

Extract the ZIP into a fresh folder and test that copy. Check Finder opening, page navigation and fit modes, search, a note or text box, a drawing, undo/redo, Save As, and page extraction. Reopen an edited PDF in Leaf and another PDF viewer to check the saved result. Use disposable documents for these checks.

## Signing and notarization

By default, builds use an **ad hoc signature**. They are not Developer ID signed or notarized. State that clearly in the release notes; do not claim Apple verification or ask users to disable system-wide security protections.

For a Developer ID release, set `LEAF_SIGN_IDENTITY` to an installed signing identity. The build enables the hardened runtime and a signing timestamp. To notarize as well, set `LEAF_NOTARY_PROFILE` to an existing `notarytool` Keychain profile:

```bash
LEAF_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
LEAF_NOTARY_PROFILE="leaf-notary" \
./scripts/package-release.sh
```

Use the actual identity and profile configured on the release Mac. The script submits the archive, waits for acceptance, staples the app, then repackages it. A failed or rejected submission is not a notarized release. This optional Developer ID/notarization path has not been validated for the 1.2.1 beta, which uses ad hoc signing. Keep signing credentials and Keychain data out of the repository and build artifacts.

## Publish the beta

Create a GitHub release in [SalehMuAm/Leaf](https://github.com/SalehMuAm/Leaf/releases) for the verified commit using `v1.2.1-beta.1`, title it **Leaf 1.2.1 — Public beta**, and mark it as a **pre-release**. Attach the versioned ZIP and its `.sha256` file. Include:

- macOS 14 deployment target and the actual tested macOS version.
- Apple silicon-only binary availability.
- Signing and notarization status of the uploaded package.
- Beta limitations and the relevant changelog entries.

Enable GitHub private vulnerability reporting and verify the [private report form](https://github.com/SalehMuAm/Leaf/security/advisories/new) used by `SECURITY.md`. CI is configured to build, test, and package artifacts; it does not publish releases. Check the actual run result before treating a CI artifact as verified. Do not replace artifacts on an existing release silently: issue a new version or clearly document a replacement and its checksum.
