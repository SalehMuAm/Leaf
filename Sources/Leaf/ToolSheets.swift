import AppKit
import PDFKit
import SwiftUI

struct TextBoxSheet: View {
    @ObservedObject var store: DocumentStore
    let annotation: PDFAnnotation?
    let onDismiss: () -> Void
    @State private var text: String
    @State private var fontSizeInput: String
    @State private var validationMessage: String?
    @FocusState private var textFocused: Bool

    init(store: DocumentStore, annotation: PDFAnnotation?, onDismiss: @escaping () -> Void) {
        self.store = store
        self.annotation = annotation
        self.onDismiss = onDismiss
        _text = State(initialValue: annotation?.contents ?? "")
        _fontSizeInput = State(initialValue: Double(annotation?.font?.pointSize ?? 16)
            .formatted(.number.precision(.fractionLength(0...2))))
    }

    private var fontSize: Double? {
        try? Double(fontSizeInput, format: .number, lenient: false)
    }

    private var validFontSize: Bool {
        guard let fontSize else { return false }
        return fontSize.isFinite && (8...72).contains(fontSize)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(annotation == nil ? "Add a text box" : "Edit text box", systemImage: "textformat")
                .font(.system(size: 20, weight: .semibold, design: .serif))
            Text(annotation == nil ? "Type your text, then click on the page to place it." : "Update the text below. You can also drag the box to move it on the page.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(size: 14)).focused($textFocused)
                .padding(8).frame(height: 140)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.15)))
                .accessibilityLabel("Text box content")
            HStack(spacing: 8) {
                Text("Text size").foregroundStyle(.secondary)
                TextField("Text size", text: $fontSizeInput)
                    .textFieldStyle(.roundedBorder).frame(width: 48).multilineTextAlignment(.trailing)
                    .accessibilityLabel("Text size in points")
                Text("pt").foregroundStyle(.secondary)
                Stepper("Text size", value: Binding(
                    get: { min(72, max(8, fontSize ?? 16)) },
                    set: { fontSizeInput = $0.formatted(.number.precision(.fractionLength(0...2))) }
                ), in: 8...72).labelsHidden()
                    .accessibilityLabel("Adjust text size")
                Spacer()
                Text("8–72 pt").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let annotation {
                    Button("Delete Text Box", role: .destructive) {
                        if store.removeTextBox(annotation) { onDismiss() }
                        else {
                            validationMessage = store.errorMessage ?? "This text box couldn’t be removed."
                            store.errorMessage = nil
                        }
                    }.help("Delete this text box. You can undo the change.")
                }
                Spacer()
                Button("Cancel", action: onDismiss).keyboardShortcut(.cancelAction)
                Button(annotation == nil ? "Place Text" : "Save Changes", action: submit)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !validFontSize)
            }
        }
        .padding(26).frame(width: 440).tint(LeafStyle.accent)
        .onAppear { textFocused = true }
    }

    private func submit() {
        guard let fontSize, validFontSize else {
            validationMessage = "Choose a text size between 8 and 72 points."
            return
        }
        let success: Bool
        if let annotation { success = store.updateTextBox(annotation, text: text, fontSize: fontSize) }
        else { success = store.beginTextPlacement(text: text, fontSize: fontSize) }
        if success { onDismiss() }
        else {
            validationMessage = store.errorMessage ?? "Try shorter text or a smaller text size."
            store.errorMessage = nil
        }
    }
}

struct PageExtractionSheet: View {
    let pageCount: Int
    let currentPageIndex: Int
    let onExport: ([Int]) -> Void
    let onCancel: () -> Void
    @State private var range: String
    @FocusState private var rangeFocused: Bool

    init(pageCount: Int, currentPageIndex: Int, onExport: @escaping ([Int]) -> Void, onCancel: @escaping () -> Void) {
        self.pageCount = pageCount
        self.currentPageIndex = currentPageIndex
        self.onExport = onExport
        self.onCancel = onCancel
        _range = State(initialValue: "\(currentPageIndex + 1)")
    }

    private var selection: Result<[Int], Error> { Result { try PageRange.parse(range, totalPages: pageCount) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Extract pages", systemImage: "doc.on.doc")
                .font(.system(size: 20, weight: .semibold, design: .serif))
            Text("Save part of this document as a separate PDF. The original stays intact.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Pages").fontWeight(.medium)
                    Spacer()
                    Button("Current page") { range = "\(currentPageIndex + 1)" }
                    Button("All pages") { range = pageCount == 1 ? "1" : "1-\(pageCount)" }
                }.font(.system(size: 12)).buttonStyle(.borderless)
                TextField("For example: 1–3, 5", text: $range)
                    .textFieldStyle(.roundedBorder).focused($rangeFocused)
                    .accessibilityLabel("Pages to extract")
                Text("Use page numbers or ranges, such as 1–3, 5. This PDF has \(pageCount) \(pageCount == 1 ? "page" : "pages").")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Group {
                switch selection {
                case .success(let indices):
                    Label("\(indices.count) \(indices.count == 1 ? "page" : "pages") will be saved in document order.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                case .failure(let error):
                    Label(error.localizedDescription, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                }
            }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save Pages…") {
                    if case .success(let indices) = selection { onExport(indices) }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled((try? selection.get()) == nil)
            }
        }
        .padding(26).frame(width: 440).tint(LeafStyle.accent)
        .onAppear { rangeFocused = true }
    }
}
