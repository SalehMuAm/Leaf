import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

enum LeafStyle {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.67, green: 0.79, blue: 0.68, alpha: 1)
            : NSColor(red: 0.29, green: 0.40, blue: 0.31, alpha: 1)
    })
    static let paper = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.14, alpha: 1)
            : NSColor(red: 0.965, green: 0.959, blue: 0.938, alpha: 1)
    })
}

struct ReaderView: View {
    private enum Sheet: String, Identifiable {
        case note, textBox, extraction
        var id: String { rawValue }
    }
    @ObservedObject var store: DocumentStore
    @State private var sidebarTab: SidebarTab = .pages
    @State private var activeSheet: Sheet?
    @State private var textBoxToEdit: PDFAnnotation?
    @State private var pendingExtraction: [Int]?
    @State private var noteText = ""
    @State private var noteValidationMessage: String?
    @State private var pageEntry = "1"
    @State private var isDropTarget = false
    @FocusState private var pageFieldFocused: Bool
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if store.document != nil {
                if !store.isFocusMode { readingBar }
                HStack(spacing: 0) {
                    if store.showSidebar && !store.isFocusMode {
                        DocumentSidebar(store: store, tab: $sidebarTab, searchFocused: $searchFocused)
                            .frame(width: 224)
                        Divider()
                    }
                    PDFCanvas(store: store)
                        .overlay(alignment: .top) {
                            if store.activeDrawingTool != nil {
                                drawingBar
                                    .padding(.top, store.isFocusMode ? 52 : 14)
                            } else if store.pendingTextBox != nil {
                                HStack(spacing: 12) {
                                    Label("Click the page to place your text", systemImage: "character.cursor.ibeam")
                                    Button("Cancel") { store.cancelTextPlacement() }
                                        .buttonStyle(.borderless).help("Cancel placement (Esc)")
                                }
                                .font(.system(size: 12))
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                                .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
                                .padding(.top, store.isFocusMode ? 52 : 14)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if store.isFocusMode {
                                Button { store.isFocusMode = false } label: {
                                    Label("Leave focus", systemImage: "arrow.down.right.and.arrow.up.left")
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                                .padding(16).help("Leave focus mode (⇧⌘F)")
                            }
                        }
                }
                statusBar
            } else {
                WelcomeView(store: store)
            }
        }
        .tint(LeafStyle.accent)
        .background(LeafStyle.paper)
        .navigationTitle(store.document == nil ? "Leaf" : store.documentTitle)
        .toolbar { toolbar }
        .background(WindowLifecycle(store: store))
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LeafStyle.accent.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(LeafStyle.accent, style: StrokeStyle(lineWidth: 2, dash: [8])))
                    .padding(10).allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in store.open(url: url) }
            }
            return true
        }
        .onChange(of: store.currentPageIndex) { _, page in pageEntry = "\(page + 1)" }
        .onChange(of: store.document) { _, _ in pageEntry = "\(store.currentPageIndex + 1)" }
        .onReceive(NotificationCenter.default.publisher(for: .leafShowSearch)) { _ in revealSearch() }
        .onReceive(NotificationCenter.default.publisher(for: .leafAddNote)) { _ in presentNote() }
        .onReceive(NotificationCenter.default.publisher(for: .leafAddTextBox)) { _ in addTextBox() }
        .onReceive(NotificationCenter.default.publisher(for: .leafExtractPages)) { _ in activeSheet = .extraction }
        .onChange(of: store.editingTextBox) { _, annotation in
            guard let annotation else { return }
            textBoxToEdit = annotation
            activeSheet = .textBox
        }
        .sheet(item: $activeSheet, onDismiss: sheetDidDismiss) { sheet in
            switch sheet {
            case .note: noteSheet
            case .textBox:
                TextBoxSheet(store: store, annotation: textBoxToEdit) { activeSheet = nil }
            case .extraction:
                PageExtractionSheet(pageCount: store.pageCount, currentPageIndex: store.currentPageIndex) { indices in
                    pendingExtraction = indices
                    activeSheet = nil
                } onCancel: { activeSheet = nil }
            }
        }
        .alert("Leaf couldn’t finish that", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "Try opening the document again.") }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { store.showSidebar.toggle(); store.isFocusMode = false } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Toggle sidebar (⌃⌘S)").accessibilityLabel("Toggle sidebar")
            .disabled(store.document == nil)
            Button(action: store.openPanel) { Image(systemName: "folder") }
                .help("Open PDF (⌘O)").accessibilityLabel("Open PDF")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if store.document != nil {
                Button(action: store.highlightSelection) { Image(systemName: "highlighter") }
                    .disabled(!store.selectionAvailable)
                    .help("Select text, then highlight (⇧⌘H)").accessibilityLabel("Highlight selected text")
                Button(action: presentNote) { Image(systemName: "note.text.badge.plus") }
                    .help("Add a note (⇧⌘N)").accessibilityLabel("Add note")
                Menu {
                    Button("Add Text Box…", systemImage: "textformat", action: addTextBox)
                    Menu("Draw & Shapes", systemImage: "pencil.tip.crop.circle") {
                        ForEach(DrawingTool.allCases) { tool in
                            Button(tool.title, systemImage: tool.systemImage) { store.beginDrawing(tool: tool) }
                        }
                    }
                    Divider()
                    Button("Rotate Page Clockwise", systemImage: "rotate.right", action: store.rotateCurrentPage)
                    Button("Insert Pages from PDF…", systemImage: "doc.badge.plus", action: store.insertPages)
                    Button("Extract Pages…", systemImage: "square.and.arrow.up") { activeSheet = .extraction }
                        .disabled(!store.canExtractPages)
                    Divider()
                    Button("Delete Current Page…", systemImage: "trash", role: .destructive, action: store.deleteCurrentPage)
                        .disabled(store.pageCount <= 1)
                } label: { Image(systemName: "ellipsis.circle") }
                .help("More tools").accessibilityLabel("More tools")
                Divider()
                Button(action: revealSearch) { Image(systemName: "magnifyingglass") }
                    .help("Find in document (⌘F)").accessibilityLabel("Find in document")
                Button { store.isFocusMode.toggle() } label: {
                    Image(systemName: store.isFocusMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .help("Toggle focus mode (⇧⌘F)").accessibilityLabel("Toggle focus mode")
                Button { store.save() } label: { Image(systemName: "square.and.arrow.down") }
                    .help("Save PDF (⌘S)").accessibilityLabel("Save PDF")
            }
        }
    }

    private var drawingBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(DrawingTool.allCases) { tool in
                        Button { store.beginDrawing(tool: tool) } label: {
                            Image(systemName: tool.systemImage)
                                .font(.system(size: 14))
                                .frame(width: 30, height: 28)
                                .background(store.activeDrawingTool == tool ? LeafStyle.accent.opacity(0.16) : .clear,
                                            in: RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help(tool.title).accessibilityLabel(tool.title)
                        .accessibilityAddTraits(store.activeDrawingTool == tool ? .isSelected : [])
                    }
                }
                Divider().frame(height: 20)
                ColorPicker("Stroke color", selection: Binding(
                    get: { Color(nsColor: store.drawingColor) },
                    set: { store.drawingColor = NSColor($0) }
                ), supportsOpacity: false)
                .labelsHidden().fixedSize().help("Stroke color").accessibilityLabel("Stroke color")
                Picker("Stroke width", selection: $store.drawingLineWidth) {
                    ForEach([1, 2, 3, 5, 8], id: \.self) { width in
                        Text("\(width) pt").tag(CGFloat(width))
                    }
                }
                .labelsHidden().frame(width: 65).help("Stroke width").accessibilityLabel("Stroke width")
                Divider().frame(height: 20)
                Button("Done") { store.endDrawing() }
                    .buttonStyle(.borderless).help("Finish drawing (Esc)")
            }
            Text("Drag on the page to \(store.activeDrawingTool == .pen ? "draw" : "add a shape") · Esc to finish")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
    }

    private var readingBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                smallButton("chevron.left", "Previous page (←)", disabled: store.currentPageIndex == 0, action: store.previousPage)
                TextField("Page", text: $pageEntry)
                    .textFieldStyle(.roundedBorder).frame(width: 42)
                    .multilineTextAlignment(.center).monospacedDigit()
                    .focused($pageFieldFocused)
                    .accessibilityLabel("Current page").help("Enter a page number and press Return")
                    .onSubmit {
                        if let number = Int(pageEntry) { store.goToPage(index: number - 1) }
                        pageEntry = "\(store.currentPageIndex + 1)"
                        pageFieldFocused = false
                    }
                Text("of \(store.pageCount)").foregroundStyle(.secondary).monospacedDigit()
                smallButton("chevron.right", "Next page (→)", disabled: store.currentPageIndex >= store.pageCount - 1, action: store.nextPage)
            }
            Spacer(minLength: 10)
            HStack(spacing: 2) {
                fitButton(.page, title: "Page", icon: "arrow.up.left.and.arrow.down.right")
                fitButton(.width, title: "Width", icon: "arrow.left.and.right")
                fitButton(.height, title: "Height", icon: "arrow.up.and.down")
            }
            .padding(3)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
            Spacer(minLength: 10)
            HStack(spacing: 2) {
                smallButton("minus", "Zoom out (⌘−)", action: store.zoomOut)
                Menu {
                    Button("Actual Size") { store.setFitMode(.actual) }
                    Button("Fit Page") { store.setFitMode(.page) }
                    Button("Fit Width") { store.setFitMode(.width) }
                    Button("Fit Height") { store.setFitMode(.height) }
                } label: {
                    Text("\(store.zoomPercent)%").monospacedDigit().frame(minWidth: 42)
                }
                .menuStyle(.borderlessButton).fixedSize().help("Zoom options")
                smallButton("plus", "Zoom in (⌘+)", action: store.zoomIn)
            }
            Divider().frame(height: 18).padding(.horizontal, 4)
            Menu {
                Picker("Page layout", selection: $store.layout) {
                    ForEach(ReadingLayout.allCases) { layout in
                        Label(layout.label, systemImage: layout.systemImage).tag(layout)
                    }
                }
            } label: { Image(systemName: store.layout.systemImage).frame(width: 24) }
            .menuStyle(.borderlessButton).fixedSize().help("Page layout: \(store.layout.label)").accessibilityLabel("Page layout")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 18).frame(height: 52)
        .background(LeafStyle.paper)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: store.isModified ? "circle.fill" : "checkmark.circle")
                .font(.system(size: store.isModified ? 6 : 10))
                .foregroundStyle(store.isModified ? Color.orange : LeafStyle.accent)
            Text(store.isModified ? "Unsaved changes" : "Ready to read")
            Spacer()
            Text("Page \(store.currentPageIndex + 1) of \(store.pageCount)")
                .monospacedDigit()
            Text("·").padding(.horizontal, 2)
            Text(store.layout.label)
            Spacer()
            Menu {
                Picker("Reading background", selection: $store.canvasTheme) {
                    ForEach(CanvasTheme.allCases) { theme in Text(theme.label).tag(theme) }
                }
            } label: {
                Label(store.canvasTheme.label, systemImage: "circle.lefthalf.filled")
            }
            .menuStyle(.borderlessButton).fixedSize().help("Change the reading background")
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 18).frame(height: 32)
        .background(LeafStyle.paper).overlay(alignment: .top) { Divider() }
    }

    private var noteSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("A thought for this page", systemImage: "note.text")
                .font(.system(size: 20, weight: .semibold, design: .serif))
            Text("Add a note to page \(store.currentPageIndex + 1). It will stay with your PDF when you save.")
                .foregroundStyle(.secondary)
            TextEditor(text: $noteText).font(.body)
                .padding(8).frame(height: 130)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.15)))
                .accessibilityLabel("Note text")
            if let noteValidationMessage {
                Label(noteValidationMessage, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { activeSheet = nil; noteText = "" }.keyboardShortcut(.cancelAction)
                Button("Add Note") {
                    if store.addNote(text: noteText) {
                        noteText = ""
                        activeSheet = nil
                    } else {
                        noteValidationMessage = store.errorMessage ?? "This note couldn’t be added."
                        store.errorMessage = nil
                    }
                }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(26).frame(width: 430)
    }

    private func presentNote() {
        guard store.document != nil else { return }
        noteValidationMessage = nil
        activeSheet = .note
    }

    private func addTextBox() {
        guard store.document != nil else { return }
        store.endDrawing()
        store.cancelTextPlacement()
        store.editingTextBox = nil
        textBoxToEdit = nil
        activeSheet = .textBox
    }

    private func sheetDidDismiss() {
        store.editingTextBox = nil
        textBoxToEdit = nil
        guard let indices = pendingExtraction else { return }
        pendingExtraction = nil
        DispatchQueue.main.async {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "\(store.documentTitle) — extracted pages.pdf"
            panel.prompt = "Save Pages"
            if panel.runModal() == .OK, let url = panel.url {
                store.extractPages(indices, to: url)
            }
        }
    }

    private func revealSearch() {
        guard store.document != nil else { return }
        store.isFocusMode = false
        store.showSidebar = true
        sidebarTab = .search
        DispatchQueue.main.async { searchFocused = true }
    }

    private func fitButton(_ mode: FitMode, title: String, icon: String) -> some View {
        Button { store.setFitMode(mode) } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: store.fitMode == mode ? .semibold : .regular))
                .padding(.horizontal, 9).frame(height: 25)
                .background(store.fitMode == mode ? Color(nsColor: .controlBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .shadow(color: .black.opacity(store.fitMode == mode ? 0.07 : 0), radius: 2, y: 1)
        }
        .buttonStyle(.plain).help("Fit \(title.lowercased())")
        .accessibilityAddTraits(store.fitMode == mode ? .isSelected : [])
    }

    private func smallButton(_ icon: String, _ help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 25, height: 26).contentShape(Rectangle()) }
            .buttonStyle(.borderless).help(help).accessibilityLabel(help).disabled(disabled)
    }
}

private struct WindowLifecycle: NSViewRepresentable {
    let store: DocumentStore
    func makeCoordinator() -> Coordinator { Coordinator(store) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.delegate = context.coordinator
            view.window?.setFrameAutosaveName("LeafReader")
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.isDocumentEdited = store.isModified
        nsView.window?.representedURL = store.fileURL
    }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        let store: DocumentStore
        init(_ store: DocumentStore) { self.store = store }
        func windowShouldClose(_ sender: NSWindow) -> Bool { store.confirmDiscardIfNeeded() }
    }
}
