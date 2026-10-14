# Changelog

## 1.2.1 — Public beta

First public beta of Leaf, a native macOS PDF reader and annotation editor. Code, documentation, and included assets are available under the MIT license.

### Reading

- Page navigation with arrow controls, keyboard shortcuts, and a page number field.
- Fit page, width, or height; vertical, horizontal, single-page, and two-page reading layouts.
- Thumbnails, document outlines, text search, focus mode, and reading backgrounds.
- Finder opening, drag and drop, recent documents, and a bundled welcome PDF.

### Editing

- Highlights, notes, PDF form entry, and editable text boxes.
- Pen, rectangle, ellipse, line, and arrow annotations with stroke color and width.
- Page rotation, insertion, deletion, and extraction to another PDF.
- Undo/redo, Save As, and native printing. Existing PDF text is not rewritten or reflowed.

### Reliability fixes included in this beta

- Respect annotation locking flags, preserve imported text formatting on unchanged edits, and restore stacking order when undoing deletion.
- Clip off-page drawing gestures without bending lines or adding unwanted strokes along page edges.
- Cancel unfinished drawing and text movements when saving, navigating, or changing the view.
- Keep text-editor keyboard navigation separate from page navigation.
- Validate editing inputs and handle document outline edge cases.

### Verification and limitations

- Verified with 65 passing tests on Apple silicon, macOS 26.6.2, Swift 6.3.3, and the macOS 26.5 SDK.
- macOS 14 is the deployment target; compatibility on every supported macOS release is not yet verified.
- The current binary is `arm64` only. Intel and universal builds are not provided in this beta.
- The beta binary is ad hoc signed, without Developer ID signing or Apple notarization. Use copies of important PDFs while evaluating the beta.
