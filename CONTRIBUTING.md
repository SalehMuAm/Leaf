# Contributing to Leaf

Leaf is a native macOS PDF reader and annotation editor. Contributions should preserve its small footprint, responsive reading experience, and quiet interface.

## Development setup

- macOS 14 is the minimum deployment target.
- Install Xcode or Apple's Command Line Tools with the Swift toolchain.
- The verified development environment is Apple silicon (`arm64`), macOS 26.6.2, Swift 6.3.3, and the macOS 26.5 SDK. Older macOS releases and Intel Macs have not yet been verified.
- The Swift package has no external dependencies.

From the repository root:

```bash
./scripts/build-app.sh --debug
open dist/Leaf.app
swift test
```

The app bundle includes the icon and welcome PDF. `swift run Leaf` is also useful for quick development runs from the repository root. Build output belongs in `.build/` and `dist/`, not in commits.

## Making a change

Keep pull requests focused. Describe the problem, the resulting behavior, and how you verified it. Include before/after screenshots when a visible interaction or layout changes.

- Prefer native SwiftUI, AppKit, and PDFKit capabilities before adding dependencies.
- Keep reading controls simple; expose occasional editing tools only when needed.
- Keep UI and document mutations on the main actor. Completed edits should form one undo step; previews and cancelled gestures must not modify the document.
- Respect PDF document permissions and annotation locking flags. Preserve page coordinates, rotation, crop boxes, and annotation ordering.
- Follow the existing code style. Avoid unrelated formatting or refactors.
- Read the [MIT license](LICENSE) before contributing. It covers Leaf's code, documentation, and included assets. Do not include third-party code or assets without compatible permission and attribution.

## Verification

Run `swift test` for changes to document behavior or interactions. Record the command, result, and environment in your pull request.

PDFKit rendering and AppKit interaction tests require a macOS session with working graphics services. A restrictive headless sandbox can fail to create rendering surfaces. Record the environment and failure rather than removing assertions to make that environment pass.

Add regression coverage for a reproducible bug when it protects meaningful behavior. For annotation changes, check undo/redo and saved PDFs as well as the live preview. For UI changes, verify keyboard use, focus, window resizing, and reading at different zoom levels. Use synthetic or redacted PDFs that may be shared publicly; tests should clean up temporary files and never depend on fixed paths in `/tmp`.

## Reporting bugs

Open an issue with:

- Leaf version, macOS version, and Mac architecture.
- Steps to reproduce, expected behavior, and actual behavior.
- Whether it happens with every PDF or one file; include a small shareable sample when possible.
- Relevant error messages or a redacted screenshot.

Never attach a private document just to demonstrate a bug. Follow [SECURITY.md](SECURITY.md) for suspected vulnerabilities. See [the release guide](docs/RELEASING.md) for packaging and release checks.
