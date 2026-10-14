import AppKit
import Combine
import PDFKit
import UniformTypeIdentifiers

enum FitMode: String, CaseIterable, Identifiable {
    case page, width, height, actual, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .page: return "Fit page"
        case .width: return "Fit width"
        case .height: return "Fit height"
        case .actual: return "Actual size"
        case .custom: return "Custom zoom"
        }
    }
    var systemImage: String {
        switch self {
        case .page: return "arrow.up.left.and.arrow.down.right"
        case .width: return "arrow.left.and.right"
        case .height: return "arrow.up.and.down"
        case .actual: return "1.magnifyingglass"
        case .custom: return "magnifyingglass"
        }
    }
}

enum ReadingLayout: String, CaseIterable, Identifiable {
    case vertical, horizontal, single, twoUp
    var id: String { rawValue }
    var label: String {
        switch self {
        case .vertical: return "Continuous vertical"
        case .horizontal: return "Continuous horizontal"
        case .single: return "Single page"
        case .twoUp: return "Two pages"
        }
    }
    var systemImage: String {
        switch self {
        case .vertical: return "rectangle.split.1x2"
        case .horizontal: return "rectangle.split.2x1"
        case .single: return "rectangle.portrait"
        case .twoUp: return "book"
        }
    }
}

enum CanvasTheme: String, CaseIterable, Identifiable {
    case paper, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .paper: return "Warm paper"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    var systemImage: String {
        switch self {
        case .paper: return "sun.haze"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
    var backgroundColor: NSColor {
        switch self {
        case .paper: return NSColor(srgbRed: 0.90, green: 0.89, blue: 0.86, alpha: 1)
        case .light: return NSColor(srgbRed: 0.93, green: 0.94, blue: 0.94, alpha: 1)
        case .dark: return NSColor(srgbRed: 0.16, green: 0.18, blue: 0.18, alpha: 1)
        }
    }
}

struct SearchHit: Identifiable {
    let id = UUID()
    let pageIndex: Int
    let excerpt: String
    let selection: PDFSelection
}

struct TextBoxDraft {
    var text: String
    var fontSize: CGFloat = 16
    var color: NSColor = .black
}

/// Owns a single document. Rendering and searching stay in PDFKit; edits retain only
/// the affected pages or annotations, rather than copying the entire PDF for undo.
@MainActor
final class DocumentStore: NSObject, ObservableObject {
    @Published var document: PDFDocument?
    @Published var fileURL: URL?
    @Published var currentPageIndex = 0
    @Published var isModified = false
    @Published var zoomPercent = 100
    @Published var fitMode: FitMode = .page {
        didSet { if oldValue != fitMode { pdfView?.scheduleFit() } }
    }
    @Published var layout: ReadingLayout = .vertical {
        didSet {
            guard oldValue != layout else { return }
            UserDefaults.standard.set(layout.rawValue, forKey: "readingLayout")
            pdfView?.applyReadingLayout(layout)
        }
    }
    @Published var canvasTheme: CanvasTheme = .paper {
        didSet {
            UserDefaults.standard.set(canvasTheme.rawValue, forKey: "canvasTheme")
            pdfView?.backgroundColor = canvasTheme.backgroundColor
        }
    }
    @Published var showSidebar = true
    @Published var isFocusMode = false
    @Published var searchQuery = ""
    @Published var searchResults: [SearchHit] = []
    @Published var activeSearchIndex: Int?
    @Published var isSearching = false
    @Published var selectionAvailable = false
    @Published var errorMessage: String?
    @Published var pageRevision = 0
    @Published var recentURLs: [URL] = []
    @Published var pendingTextBox: TextBoxDraft?
    @Published var editingTextBox: PDFAnnotation?
    @Published var activeDrawingTool: DrawingTool?
    @Published var drawingColor: NSColor = .systemRed
    @Published var drawingLineWidth: CGFloat = 2

    weak var pdfView: LeafPDFView?
    let undoManager = UndoManager()
    var pageCount: Int { document?.pageCount ?? 0 }
    var documentTitle: String {
        if let titleOverride { return titleOverride }
        if let fileURL { return fileURL.deletingPathExtension().lastPathComponent }
        return document == nil ? "Leaf" : "Untitled"
    }
    var canUndo: Bool { activeTextUndoManager?.canUndo ?? undoManager.canUndo }
    var canRedo: Bool { activeTextUndoManager?.canRedo ?? undoManager.canRedo }

    private var activeTextUndoManager: UndoManager? {
        guard let editor = NSApp?.keyWindow?.firstResponder as? NSTextView,
              editor.isEditable, let manager = editor.undoManager,
              manager !== undoManager else { return nil }
        return manager
    }

    private var titleOverride: String?
    private var changeID = UUID()
    private var savedChangeID: UUID
    private var lastWriteID = UUID()
    private var scopedURL: URL?
    private var searchObservers: [NSObjectProtocol] = []
    private var searchID = UUID()
    private var widgetSnapshots: [ObjectIdentifier: EditableAnnotationSnapshot] = [:]
    private var applyingMutation = false

    override init() {
        savedChangeID = changeID
        super.init()
        undoManager.groupsByEvent = false
        undoManager.levelsOfUndo = 100
        if let stored = UserDefaults.standard.string(forKey: "readingLayout"),
           let value = ReadingLayout(rawValue: stored) { layout = value }
        if let stored = UserDefaults.standard.string(forKey: "canvasTheme"),
           let value = CanvasTheme(rawValue: stored) { canvasTheme = value }
        recentURLs = (UserDefaults.standard.stringArray(forKey: "recentPDFs") ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    deinit {
        for observer in searchObservers { NotificationCenter.default.removeObserver(observer) }
        scopedURL?.stopAccessingSecurityScopedResource()
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Open PDF"
        if panel.runModal() == .OK, let url = panel.url { open(url: url) }
    }

    func open(url: URL) {
        load(url: url, isWelcome: false)
    }

    func openWelcomeDocument(url: URL) {
        load(url: url, isWelcome: true)
    }

    private func load(url: URL, isWelcome: Bool) {
        let accessStarted = url.startAccessingSecurityScopedResource()
        guard var incoming = PDFDocument(url: url), incoming.pageCount > 0 || incoming.isLocked else {
            if accessStarted { url.stopAccessingSecurityScopedResource() }
            errorMessage = "This file couldn’t be opened as a PDF. It may be damaged or empty."
            return
        }
        var incomingPassword: String?
        guard unlockIfNeeded(incoming, filename: url.lastPathComponent, onUnlock: { incomingPassword = $0 }) else {
            if accessStarted { url.stopAccessingSecurityScopedResource() }
            return
        }
        let previousWriteID = lastWriteID
        guard incoming.pageCount > 0, confirmDiscardIfNeeded() else {
            if accessStarted { url.stopAccessingSecurityScopedResource() }
            return
        }
        if previousWriteID != lastWriteID {
            // Save (including Save As) may have replaced the file selected for
            // opening. PDFKit retains its earlier file snapshot, so reopen it
            // after the write instead of displaying and later saving stale data.
            guard let refreshed = PDFDocument(url: url), refreshed.pageCount > 0 || refreshed.isLocked else {
                if accessStarted { url.stopAccessingSecurityScopedResource() }
                errorMessage = "The saved PDF couldn’t be reopened. Your current document is still open."
                return
            }
            if refreshed.isLocked {
                let unlocked = incomingPassword.map { refreshed.unlock(withPassword: $0) } ?? false
                guard unlocked || unlockIfNeeded(refreshed, filename: url.lastPathComponent) else {
                    if accessStarted { url.stopAccessingSecurityScopedResource() }
                    return
                }
            }
            incoming = refreshed
        }
        cancelSearch()
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = accessStarted ? url : nil
        undoManager.removeAllActions()
        widgetSnapshots.removeAll()
        fileURL = isWelcome ? nil : url
        titleOverride = isWelcome ? "Welcome to Leaf" : nil
        currentPageIndex = 0
        searchQuery = ""
        searchResults = []
        activeSearchIndex = nil
        selectionAvailable = false
        pendingTextBox = nil
        editingTextBox = nil
        activeDrawingTool = nil
        changeID = UUID()
        savedChangeID = changeID
        isModified = false
        document = incoming
        pageRevision += 1
        if !isWelcome { remember(url) }
        pdfView?.synchronize(with: self)
    }

    private func unlockIfNeeded(_ document: PDFDocument, filename: String,
                                onUnlock: ((String) -> Void)? = nil) -> Bool {
        guard document.isLocked else { return true }
        let alert = NSAlert()
        alert.messageText = "Open protected PDF"
        alert.informativeText = "Enter the password for “\(filename)”."
        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        field.placeholderString = "Password"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        while alert.runModal() == .alertFirstButtonReturn {
            if document.unlock(withPassword: field.stringValue) {
                onUnlock?(field.stringValue)
                return true
            }
            alert.informativeText = "That password didn’t work. Try again."
            field.stringValue = ""
        }
        return false
    }

    @discardableResult
    func save() -> Bool {
        guard document != nil else { return false }
        guard let fileURL else { return saveAs() }
        return writeDocument(to: fileURL)
    }

    @discardableResult
    func saveAs() -> Bool {
        guard document != nil else { return false }
        commitPendingEdits()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "\(documentTitle).pdf"
        panel.canCreateDirectories = true
        panel.prompt = "Save PDF"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return writeDocument(to: url)
    }

    private func writeDocument(to url: URL) -> Bool {
        guard let document else { return false }
        commitPendingEdits()
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".leaf-\(UUID().uuidString).pdf")
        let accessStarted = url.startAccessingSecurityScopedResource()
        defer {
            if accessStarted { url.stopAccessingSecurityScopedResource() }
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        do {
            // Never overwrite the original until PDFKit has written a complete,
            // readable replacement in the same directory.
            guard document.write(to: temporaryURL),
                  let verified = PDFDocument(url: temporaryURL),
                  verified.pageCount == document.pageCount else {
                throw DocumentError.writeFailed
            }
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: url)
            }
            fileURL = url
            titleOverride = nil
            savedChangeID = changeID
            lastWriteID = UUID()
            isModified = false
            remember(url)
            return true
        } catch {
            errorMessage = "The PDF couldn’t be saved. \(error.localizedDescription) Try Save As to choose another location."
            return false
        }
    }

    func confirmDiscardIfNeeded() -> Bool {
        commitPendingEdits()
        guard isModified else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(documentTitle)”?"
        alert.informativeText = "Your highlights, notes, form entries, and page changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn:
            // Window close can be followed by application termination. Once the
            // user has discarded this revision, do not prompt for it twice.
            savedChangeID = changeID
            isModified = false
            return true
        default: return false
        }
    }

    func printDocument() {
        guard let document else { return }
        guard document.allowsPrinting else {
            errorMessage = "The owner of this PDF has disabled printing."
            return
        }
        commitPendingEdits()
        guard let operation = document.printOperation(for: NSPrintInfo.shared,
                                                       scalingMode: .pageScaleToFit,
                                                       autoRotate: true) else { return }
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }

    func goToPage(index: Int) {
        guard let document, document.pageCount > 0 else { return }
        let boundedIndex = min(max(index, 0), document.pageCount - 1)
        guard let page = document.page(at: boundedIndex) else { return }
        commitPendingEdits()
        currentPageIndex = boundedIndex
        pdfView?.go(to: page)
        pdfView?.scheduleFit()
        captureVisibleWidgets()
    }

    func previousPage() {
        let index = layout == .twoUp ? (currentPageIndex / 2) * 2 - 2 : currentPageIndex - 1
        goToPage(index: index)
    }

    func nextPage() {
        let index = layout == .twoUp ? (currentPageIndex / 2) * 2 + 2 : currentPageIndex + 1
        // In a final complete spread, advancing must not select its second page.
        guard index < pageCount else { return }
        goToPage(index: index)
    }

    func zoomIn() { changeZoom(by: 1.2) }
    func zoomOut() { changeZoom(by: 1 / 1.2) }

    private func changeZoom(by factor: CGFloat) {
        guard let pdfView, document != nil else { return }
        fitMode = .custom
        pdfView.autoScales = false
        pdfView.scaleFactor = min(max(pdfView.scaleFactor * factor, pdfView.minScaleFactor), pdfView.maxScaleFactor)
        zoomPercent = Int((pdfView.scaleFactor * 100).rounded())
    }

    func setFitMode(_ mode: FitMode) {
        fitMode = mode
        pdfView?.scheduleFit()
    }

    func setLayout(_ mode: ReadingLayout) {
        layout = mode
        pdfView?.applyReadingLayout(mode)
    }

    func performSearch() {
        cancelSearch()
        searchResults = []
        activeSearchIndex = nil
        pdfView?.highlightedSelections = nil
        guard let document else { return }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let identifier = UUID()
        searchID = identifier
        isSearching = true
        let center = NotificationCenter.default
        searchObservers.append(center.addObserver(forName: .PDFDocumentDidFindMatch,
                                                   object: document, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.searchID == identifier,
                      let selection = notification.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection,
                      let page = selection.pages.first,
                      let activeDocument = self.document else { return }
                let pageIndex = activeDocument.index(for: page)
                guard pageIndex != NSNotFound else { return }
                let expanded = selection.copy() as? PDFSelection
                expanded?.extend(atStart: 45)
                expanded?.extend(atEnd: 70)
                let excerpt = (expanded?.string ?? selection.string ?? query)
                    .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
                selection.color = NSColor.systemYellow.withAlphaComponent(0.4)
                self.searchResults.append(SearchHit(pageIndex: pageIndex, excerpt: excerpt, selection: selection))
                if self.activeSearchIndex == nil { self.selectSearchResult(0) }
            }
        })
        searchObservers.append(center.addObserver(forName: .PDFDocumentDidEndFind,
                                                   object: document, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.searchID == identifier else { return }
                self.isSearching = false
            }
        })
        document.beginFindString(query, withOptions: [.caseInsensitive])
    }

    private func cancelSearch() {
        searchID = UUID()
        for observer in searchObservers { NotificationCenter.default.removeObserver(observer) }
        searchObservers.removeAll()
        document?.cancelFindString()
        isSearching = false
    }

    func selectSearchResult(_ index: Int) {
        guard searchResults.indices.contains(index) else { return }
        activeSearchIndex = index
        let hit = searchResults[index]
        pdfView?.highlightedSelections = [hit.selection]
        pdfView?.setCurrentSelection(hit.selection, animate: true)
        pdfView?.go(to: hit.selection)
        currentPageIndex = hit.pageIndex
    }

    func nextSearchResult() {
        guard !searchResults.isEmpty else { return }
        selectSearchResult(((activeSearchIndex ?? -1) + 1) % searchResults.count)
    }

    func previousSearchResult() {
        guard !searchResults.isEmpty else { return }
        selectSearchResult(((activeSearchIndex ?? 0) - 1 + searchResults.count) % searchResults.count)
    }

    func highlightSelection() {
        guard canAnnotate(), let selection = pdfView?.currentSelection,
              !(selection.string ?? "").isEmpty else { return }
        var additions: [(PDFPage, PDFAnnotation)] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard !bounds.isEmpty, !bounds.isInfinite else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                annotation.color = NSColor(srgbRed: 1, green: 0.82, blue: 0.22, alpha: 0.55)
                annotation.contents = line.string
                annotation.modificationDate = Date()
                additions.append((page, annotation))
            }
        }
        guard !additions.isEmpty else { return }
        applyChange(named: "Highlight", apply: {
            for (page, annotation) in additions { page.addAnnotation(annotation) }
        }, revert: {
            for (page, annotation) in additions { page.removeAnnotation(annotation) }
        })
        pdfView?.clearSelection()
    }

    @discardableResult
    func addNote(text: String) -> Bool {
        guard canAnnotate(), let page = document?.page(at: currentPageIndex) else { return false }
        let contents = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !contents.isEmpty else { return false }
        let pageBounds = page.bounds(for: .cropBox)
        var origin = NSPoint(x: pageBounds.minX + 32, y: pageBounds.maxY - 62)
        if let selection = pdfView?.currentSelection, selection.pages.contains(page) {
            let selectionBounds = selection.bounds(for: page)
            origin = NSPoint(x: max(pageBounds.minX + 8, selectionBounds.minX - 28),
                             y: min(pageBounds.maxY - 28, selectionBounds.maxY - 20))
        } else {
            let noteCount = page.annotations.filter { $0.type == "Text" }.count
            origin.x += CGFloat(noteCount % 8) * 30
            origin.y -= CGFloat(noteCount / 8) * 30
        }
        let annotation = PDFAnnotation(bounds: NSRect(origin: origin, size: NSSize(width: 24, height: 24)),
                                       forType: .text, withProperties: nil)
        annotation.contents = contents
        annotation.iconType = .note
        annotation.color = NSColor(srgbRed: 0.98, green: 0.76, blue: 0.24, alpha: 1)
        annotation.modificationDate = Date()
        applyChange(named: "Add Note", apply: { page.addAnnotation(annotation) },
                    revert: { page.removeAnnotation(annotation) })
        pdfView?.go(to: annotation.bounds, on: page)
        return true
    }

    @discardableResult
    func beginTextPlacement(text: String, fontSize: CGFloat = 16) -> Bool {
        guard canAnnotate(), let page = document?.page(at: currentPageIndex),
              let draft = validatedTextBox(text: text, fontSize: fontSize),
              textBoxSize(draft, on: page, rotation: page.rotation) != nil else { return false }
        editingTextBox = nil
        activeDrawingTool = nil
        pendingTextBox = draft
        pdfView?.clearSelection()
        return true
    }

    func cancelTextPlacement() { pendingTextBox = nil }

    @discardableResult
    func beginDrawing(tool: DrawingTool) -> Bool {
        guard canAnnotate() else { return false }
        pendingTextBox = nil
        editingTextBox = nil
        activeDrawingTool = tool
        pdfView?.clearSelection()
        return true
    }

    func endDrawing() { activeDrawingTool = nil }

    @discardableResult
    func addDrawing(tool: DrawingTool, points: [NSPoint], on page: PDFPage) -> Bool {
        guard canAnnotate(), let document, document.index(for: page) != NSNotFound,
              let annotation = drawingAnnotation(tool: tool, points: points, on: page,
                                                 color: drawingColor, lineWidth: drawingLineWidth) else { return false }
        applyChange(named: tool == .pen ? "Draw with Pen" : "Add \(tool.title)", apply: {
            page.addAnnotation(annotation)
        }, revert: {
            page.removeAnnotation(annotation)
        }, relayout: false)
        return true
    }

    @discardableResult
    func removeDrawing(_ annotation: PDFAnnotation) -> Bool {
        guard canAnnotate(), isDrawingAnnotation(annotation), Self.annotationAllowsChanges(annotation),
              let document, let page = annotation.page,
              document.index(for: page) != NSNotFound,
              let index = page.annotations.firstIndex(where: { $0 === annotation }) else { return false }
        applyChange(named: "Delete Drawing", apply: { page.removeAnnotation(annotation) },
                    revert: { Self.restoreAnnotation(annotation, on: page, at: index) }, relayout: false)
        return true
    }

    @discardableResult
    func placeTextBox(on page: PDFPage, at point: NSPoint) -> Bool {
        guard canAnnotate(), let document, document.index(for: page) != NSNotFound,
              let draft = pendingTextBox, point.x.isFinite, point.y.isFinite,
              let size = textBoxSize(draft, on: page, rotation: page.rotation) else { return false }
        let rotation = normalizedRotation(page.rotation)
        let bounds = textBoxBounds(topLeft: point, size: size, rotation: rotation,
                                   within: page.bounds(for: .cropBox))
        let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        annotation.contents = draft.text
        annotation.font = textBoxFont(size: draft.fontSize)
        annotation.fontColor = draft.color
        annotation.color = .clear
        annotation.alignment = .left
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
        // /Rotate counteracts the page's display rotation. The stored rectangle
        // remains in PDF coordinates while the text reads upright on screen.
        annotation.setValue(NSNumber(value: rotation), forAnnotationKey: PDFAnnotationKey(rawValue: "/Rotate"))
        annotation.modificationDate = Date()
        applyChange(named: "Add Text", apply: { page.addAnnotation(annotation) },
                    revert: { page.removeAnnotation(annotation) }, relayout: false)
        pendingTextBox = nil
        return true
    }

    @discardableResult
    func updateTextBox(_ annotation: PDFAnnotation, text: String, fontSize: CGFloat) -> Bool {
        guard canAnnotate(), let page = editableTextBoxPage(annotation, contents: true) else { return false }
        // Preserve an imported annotation verbatim when the editor is confirmed
        // without changes, including its whitespace and original font size.
        if annotation.contents == text && annotation.font?.pointSize == fontSize {
            editingTextBox = nil
            return true
        }
        guard let draft = validatedTextBox(text: text, fontSize: fontSize) else { return false }
        if annotation.contents == draft.text && annotation.font?.pointSize == fontSize {
            editingTextBox = nil
            return true
        }
        let rotation = textBoxRotation(annotation)
        let oldBounds = annotation.bounds
        let logicalWidth = rotation == 90 || rotation == 270 ? oldBounds.height : oldBounds.width
        let font = annotation.font.map { NSFontManager.shared.convert($0, toSize: fontSize) }
            ?? textBoxFont(size: fontSize)
        guard let size = textBoxSize(draft, on: page, rotation: rotation,
                                     preferredWidth: logicalWidth, font: font) else { return false }
        let bounds = textBoxBounds(topLeft: textBoxTopLeft(oldBounds, rotation: rotation),
                                   size: size, rotation: rotation, within: page.bounds(for: .cropBox))
        let oldContents = annotation.contents
        let oldFont = annotation.font
        let oldDate = annotation.modificationDate
        guard oldContents != draft.text || oldFont?.pointSize != fontSize || oldBounds != bounds else {
            editingTextBox = nil
            return true
        }
        let date = Date()
        applyChange(named: "Edit Text", apply: {
            annotation.contents = draft.text
            annotation.font = font
            annotation.bounds = bounds
            annotation.modificationDate = date
        }, revert: {
            annotation.contents = oldContents
            annotation.font = oldFont
            annotation.bounds = oldBounds
            annotation.modificationDate = oldDate
        }, relayout: false)
        editingTextBox = nil
        return true
    }

    @discardableResult
    func removeTextBox(_ annotation: PDFAnnotation) -> Bool {
        guard canAnnotate(), let page = editableTextBoxPage(annotation),
              let index = page.annotations.firstIndex(where: { $0 === annotation }) else { return false }
        applyChange(named: "Delete Text", apply: { page.removeAnnotation(annotation) },
                    revert: { Self.restoreAnnotation(annotation, on: page, at: index) }, relayout: false)
        if editingTextBox === annotation { editingTextBox = nil }
        return true
    }

    private static func restoreAnnotation(_ annotation: PDFAnnotation, on page: PDFPage, at index: Int) {
        // PDFKit exposes append/remove but no indexed insertion. Temporarily
        // detach the suffix so undo restores the original visual stacking order.
        let suffix = Array(page.annotations.dropFirst(min(index, page.annotations.count)))
        for item in suffix { page.removeAnnotation(item) }
        page.addAnnotation(annotation)
        for item in suffix { page.addAnnotation(item) }
    }

    @discardableResult
    func moveTextBox(_ annotation: PDFAnnotation, to origin: NSPoint) -> Bool {
        guard canAnnotate(), let page = editableTextBoxPage(annotation),
              origin.x.isFinite, origin.y.isFinite else { return false }
        let oldBounds = annotation.bounds
        let bounds = constrainedTextBoxBounds(NSRect(origin: origin, size: oldBounds.size), on: page)
        guard bounds != oldBounds else { return true }
        let oldDate = annotation.modificationDate
        let date = Date()
        applyChange(named: "Move Text", apply: {
            annotation.bounds = bounds
            annotation.modificationDate = date
        }, revert: {
            annotation.bounds = oldBounds
            annotation.modificationDate = oldDate
        }, relayout: false)
        return true
    }

    func constrainedTextBoxBounds(_ bounds: NSRect, on page: PDFPage) -> NSRect {
        let crop = page.bounds(for: .cropBox)
        return NSRect(x: min(max(bounds.minX, crop.minX), max(crop.minX, crop.maxX - bounds.width)),
                      y: min(max(bounds.minY, crop.minY), max(crop.minY, crop.maxY - bounds.height)),
                      width: bounds.width, height: bounds.height)
    }

    static func annotationAllowsChanges(_ annotation: PDFAnnotation, contents: Bool = false) -> Bool {
        let flags = (annotation.value(forAnnotationKey: .flags) as? NSNumber)?.intValue ?? 0
        let protectedFlags = 64 | 128 | (contents ? 512 : 0)
        return !annotation.isReadOnly && flags & protectedFlags == 0
    }

    private func editableTextBoxPage(_ annotation: PDFAnnotation, contents: Bool = false) -> PDFPage? {
        guard annotation.type == "FreeText", Self.annotationAllowsChanges(annotation, contents: contents),
              let page = annotation.page, let document,
              document.index(for: page) != NSNotFound,
              page.annotations.contains(where: { $0 === annotation }) else { return nil }
        return page
    }

    private func validatedTextBox(text: String, fontSize: CGFloat) -> TextBoxDraft? {
        let contents = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !contents.isEmpty else {
            errorMessage = "Enter some text for the text box."
            return nil
        }
        guard fontSize.isFinite, (8...72).contains(fontSize) else {
            errorMessage = "Choose a text size between 8 and 72 points."
            return nil
        }
        guard contents.count <= 10_000 else {
            errorMessage = "This text is too long for a text box. Split it into smaller boxes."
            return nil
        }
        return TextBoxDraft(text: contents, fontSize: fontSize)
    }

    private func textBoxFont(size: CGFloat) -> NSFont {
        NSFont(name: "Helvetica", size: size) ?? NSFont.systemFont(ofSize: size)
    }

    private func normalizedRotation(_ rotation: Int) -> Int {
        let value = ((rotation % 360) + 360) % 360
        return [0, 90, 180, 270].contains(value) ? value : 0
    }

    private func textBoxRotation(_ annotation: PDFAnnotation) -> Int {
        normalizedRotation((annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Rotate")) as? NSNumber)?.intValue ?? 0)
    }

    /// Measure in the text's upright coordinates, then transpose the resulting
    /// rectangle when the annotation runs vertically in PDF page coordinates.
    private func textBoxSize(_ draft: TextBoxDraft, on page: PDFPage, rotation: Int,
                             preferredWidth: CGFloat = 240, font: NSFont? = nil) -> NSSize? {
        let rotation = normalizedRotation(rotation)
        let crop = page.bounds(for: .cropBox)
        let sideways = rotation == 90 || rotation == 270
        let pageWidth = sideways ? crop.height : crop.width
        let pageHeight = sideways ? crop.width : crop.height
        let width = min(max(24, preferredWidth), pageWidth - 16)
        let font = font ?? textBoxFont(size: draft.fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let measured = (draft.text as NSString).boundingRect(
            with: NSSize(width: max(1, width - 12), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: paragraph])
        let height = ceil(max(font.ascender - font.descender + font.leading, measured.height)) + 12
        guard width >= 24, height <= pageHeight - 16, measured.width <= width - 12 + 1,
              width.isFinite, height.isFinite else {
            errorMessage = "This text won’t fit on the page. Use a smaller text size or split it into shorter boxes."
            return nil
        }
        return sideways ? NSSize(width: height, height: width) : NSSize(width: width, height: height)
    }

    private func textBoxTopLeft(_ bounds: NSRect, rotation: Int) -> NSPoint {
        switch rotation {
        case 90: return NSPoint(x: bounds.minX, y: bounds.minY)
        case 180: return NSPoint(x: bounds.maxX, y: bounds.minY)
        case 270: return NSPoint(x: bounds.maxX, y: bounds.maxY)
        default: return NSPoint(x: bounds.minX, y: bounds.maxY)
        }
    }

    private func textBoxBounds(topLeft: NSPoint, size: NSSize, rotation: Int, within crop: NSRect) -> NSRect {
        let origin: NSPoint
        switch rotation {
        case 90: origin = topLeft
        case 180: origin = NSPoint(x: topLeft.x - size.width, y: topLeft.y)
        case 270: origin = NSPoint(x: topLeft.x - size.width, y: topLeft.y - size.height)
        default: origin = NSPoint(x: topLeft.x, y: topLeft.y - size.height)
        }
        return NSRect(x: min(max(origin.x, crop.minX), crop.maxX - size.width),
                      y: min(max(origin.y, crop.minY), crop.maxY - size.height),
                      width: size.width, height: size.height)
    }

    func rotateCurrentPage() {
        guard canAssemble(), let page = document?.page(at: currentPageIndex) else { return }
        let rotation = page.rotation
        applyChange(named: "Rotate Page", apply: { page.rotation = (rotation + 90) % 360 },
                    revert: { page.rotation = rotation })
        pdfView?.scheduleFit()
    }

    func deleteCurrentPage() {
        guard canAssemble(), let document, document.pageCount > 1,
              let page = document.page(at: currentPageIndex) else { return }
        let index = currentPageIndex
        let alert = NSAlert()
        alert.messageText = "Delete page \(index + 1)?"
        alert.informativeText = "You can undo this change from the Edit menu."
        alert.addButton(withTitle: "Delete Page")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        cancelSearch()
        searchResults = []
        activeSearchIndex = nil
        applyChange(named: "Delete Page", apply: { document.removePage(at: index) },
                    revert: { document.insert(page, at: index) })
        goToPage(index: min(index, document.pageCount - 1))
    }

    func insertPages() {
        guard canAssemble() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.prompt = "Insert Pages"
        panel.message = "The selected PDF will be inserted after the current page."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessStarted = url.startAccessingSecurityScopedResource()
        defer { if accessStarted { url.stopAccessingSecurityScopedResource() } }
        guard let incoming = PDFDocument(url: url) else {
            errorMessage = "No pages could be read from this PDF."
            return
        }
        guard unlockIfNeeded(incoming, filename: url.lastPathComponent) else { return }
        insertPages(from: incoming)
    }

    @discardableResult
    func insertPages(from incoming: PDFDocument) -> Bool {
        guard canAssemble(), let document else { return false }
        guard !incoming.isLocked, incoming.pageCount > 0 else {
            errorMessage = "Open and unlock a PDF with pages to insert."
            return false
        }
        guard incoming.allowsCopying && incoming.allowsDocumentAssembly else {
            errorMessage = "The owner of this PDF has disabled copying or inserting its pages."
            return false
        }
        let pages = (0..<incoming.pageCount).compactMap { incoming.page(at: $0)?.copy() as? PDFPage }
        guard pages.count == incoming.pageCount else {
            errorMessage = "Some pages could not be copied from this PDF."
            return false
        }
        let insertionIndex = min(currentPageIndex + 1, document.pageCount)
        cancelSearch()
        searchResults = []
        activeSearchIndex = nil
        applyChange(named: "Insert Pages", apply: {
            for (offset, page) in pages.enumerated() { document.insert(page, at: insertionIndex + offset) }
        }, revert: {
            for _ in pages { document.removePage(at: insertionIndex) }
        })
        goToPage(index: insertionIndex)
        return true
    }

    func undo() {
        if let manager = activeTextUndoManager {
            if manager.canUndo { manager.undo() }
            return
        }
        commitPendingEdits()
        guard undoManager.canUndo else { return }
        undoManager.undo()
    }

    func redo() {
        if let manager = activeTextUndoManager {
            if manager.canRedo { manager.redo() }
            return
        }
        commitPendingEdits()
        guard undoManager.canRedo else { return }
        undoManager.redo()
    }

    private func canAnnotate() -> Bool {
        guard let document else { return false }
        guard document.allowsCommenting else {
            errorMessage = "The owner of this PDF has disabled annotations."
            return false
        }
        commitPendingEdits()
        return true
    }

    private func canAssemble() -> Bool {
        guard let document else { return false }
        guard document.allowsDocumentAssembly else {
            errorMessage = "The owner of this PDF has disabled page changes."
            return false
        }
        commitPendingEdits()
        return true
    }

    private func applyChange(named name: String, apply: @escaping () -> Void,
                             revert: @escaping () -> Void, targetID: UUID? = nil,
                             relayout: Bool = true) {
        let previousID = changeID
        let previousPageCount = pageCount
        applyingMutation = true
        apply()
        applyingMutation = false
        changeID = targetID ?? UUID()
        let needsGroup = !undoManager.isUndoing && !undoManager.isRedoing
        if needsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { store in
            store.applyChange(named: name, apply: revert, revert: apply,
                              targetID: previousID, relayout: relayout)
        }
        undoManager.setActionName(name)
        if needsGroup { undoManager.endUndoGrouping() }
        isModified = changeID != savedChangeID
        currentPageIndex = min(currentPageIndex, max(0, pageCount - 1))
        pageRevision += 1
        if relayout { pdfView?.layoutDocumentView() }
        pdfView?.needsDisplay = true
        for snapshot in widgetSnapshots.values { snapshot.state = EditableAnnotationState(snapshot.annotation) }
        captureVisibleWidgets()
        if previousPageCount != pageCount {
            // Stored hit page indices become stale when page assembly is undone.
            performSearch()
        }
    }

    /// Commit the native field editor before saving, replacing, or closing a PDF.
    func commitPendingEdits() {
        pdfView?.cancelTransientInteractions()
        if let pdfView, let window = pdfView.window, window.attachedSheet == nil,
           let responder = window.firstResponder as? NSView,
           responder !== pdfView,
           responder.isDescendant(of: pdfView) || responder is NSTextView || responder is NSTextField {
            // PDFKit can place its note editor beside the PDF view in the same
            // window. Ending that editor also commits its annotation contents.
            // Find/page fields can harmlessly commit here; sheets stay untouched.
            window.makeFirstResponder(pdfView)
        }
        scanFormChanges()
    }

    func captureVisibleWidgets() {
        guard let document else { return }
        var pages = pdfView?.visiblePages ?? []
        if let current = document.page(at: currentPageIndex), !pages.contains(where: { $0 === current }) {
            pages.append(current)
        }
        for page in pages {
            for annotation in page.annotations where ["Widget", "Text", "FreeText"].contains(annotation.type ?? "") {
                let key = ObjectIdentifier(annotation)
                if widgetSnapshots[key] == nil { widgetSnapshots[key] = EditableAnnotationSnapshot(annotation) }
            }
        }
    }

    func scanFormChanges() {
        guard !applyingMutation else { return }
        let changed = widgetSnapshots.values.compactMap { snapshot -> (PDFAnnotation, EditableAnnotationState, EditableAnnotationState)? in
            let current = EditableAnnotationState(snapshot.annotation)
            guard current != snapshot.state else { return nil }
            return (snapshot.annotation, snapshot.state, current)
        }
        if !changed.isEmpty {
            let name = changed.allSatisfy { $0.0.type == "Widget" } ? "Fill Form" : "Edit Note"
            applyChange(named: name, apply: {
                for (annotation, _, current) in changed { current.apply(to: annotation) }
            }, revert: {
                for (annotation, previous, _) in changed { previous.apply(to: annotation) }
            }, relayout: false)
        }
        captureVisibleWidgets()
    }

    private func remember(_ url: URL) {
        recentURLs.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        recentURLs.insert(url, at: 0)
        recentURLs = Array(recentURLs.prefix(8))
        UserDefaults.standard.set(recentURLs.map(\.path), forKey: "recentPDFs")
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }
}

private enum DocumentError: LocalizedError {
    case writeFailed
    var errorDescription: String? { "PDFKit could not write a complete PDF file." }
}

private struct EditableAnnotationState: Equatable {
    let text: String?
    let button: String?
    let contents: String?
    init(_ annotation: PDFAnnotation) {
        if annotation.type == "Widget" {
            text = annotation.widgetStringValue
            button = annotation.widgetFieldType == .button ? annotation.buttonWidgetStateString : nil
            contents = nil
        } else {
            text = nil
            button = nil
            contents = annotation.contents
        }
    }
    func apply(to annotation: PDFAnnotation) {
        if annotation.type == "Widget" {
            annotation.widgetStringValue = text
            if let button { annotation.buttonWidgetStateString = button }
        } else {
            annotation.contents = contents
        }
    }
}

private final class EditableAnnotationSnapshot {
    let annotation: PDFAnnotation
    var state: EditableAnnotationState
    init(_ annotation: PDFAnnotation) {
        self.annotation = annotation
        state = EditableAnnotationState(annotation)
    }
}
