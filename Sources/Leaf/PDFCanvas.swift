import AppKit
import PDFKit
import SwiftUI

struct PDFCanvas: NSViewRepresentable {
    @ObservedObject var store: DocumentStore

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> LeafPDFView {
        let view = LeafPDFView(frame: .zero)
        view.store = store
        store.pdfView = view
        view.displayBox = .cropBox
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        view.pageShadowsEnabled = true
        view.interpolationQuality = .high
        view.minScaleFactor = 0.10
        view.maxScaleFactor = 8
        view.autoScales = false
        view.registerForDraggedTypes([.fileURL])
        view.setAccessibilityLabel("PDF document")
        view.setAccessibilityHelp("Use the left and right arrow keys to move between pages. Select text to copy or highlight it.")
        context.coordinator.observe(view)
        view.synchronize(with: store)
        return view
    }

    func updateNSView(_ view: LeafPDFView, context: Context) {
        view.synchronize(with: store)
    }

    static func dismantleNSView(_ view: LeafPDFView, coordinator: Coordinator) {
        coordinator.stopObserving()
        view.cancelTransientInteractions()
        view.store = nil
    }

    @MainActor
    final class Coordinator {
        weak var store: DocumentStore?
        private var observers: [NSObjectProtocol] = []
        private var keyMonitor: Any?

        init(store: DocumentStore) { self.store = store }

        func observe(_ view: LeafPDFView) {
            let center = NotificationCenter.default
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, let view else { return false }
                    return self.handleKeyEvent(event, in: view)
                }
                return handled ? nil : event
            }
            for name in [Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged, .PDFViewSelectionChanged] {
                observers.append(center.addObserver(forName: name, object: view, queue: .main) { [weak self, weak view] notification in
                    // PDFKit can notify during updateNSView. Publish on the next turn
                    // so SwiftUI never receives state changes while rendering.
                    let notificationName = notification.name
                    if notificationName == .PDFViewPageChanged || notificationName == .PDFViewScaleChanged {
                        MainActor.assumeIsolated { view?.cancelTransientInteractions() }
                    }
                    DispatchQueue.main.async {
                        guard let store = self?.store, let view else { return }
                        if notificationName == .PDFViewPageChanged,
                           let page = view.currentPage, let document = store.document {
                            let index = document.index(for: page)
                            if index != NSNotFound, store.currentPageIndex != index {
                                store.currentPageIndex = index
                                view.scheduleFit()
                            }
                            store.captureVisibleWidgets()
                        }
                        if notificationName == .PDFViewScaleChanged {
                            let percent = Int((view.scaleFactor * 100).rounded())
                            if store.zoomPercent != percent { store.zoomPercent = percent }
                        }
                        if notificationName == .PDFViewSelectionChanged {
                            store.selectionAvailable = !(view.currentSelection?.string ?? "").isEmpty
                        }
                    }
                })
            }
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification,
                                                object: nil, queue: .main) { [weak view] notification in
                MainActor.assumeIsolated {
                    guard let view, let clip = notification.object as? NSClipView,
                          clip.isDescendant(of: view) else { return }
                    view.cancelTransientInteractions()
                }
            })
            observers.append(center.addObserver(forName: .PDFViewAnnotationWillHit,
                                                object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.store?.captureVisibleWidgets() }
            })
            observers.append(center.addObserver(forName: .PDFViewAnnotationHit,
                                                object: view, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.store?.scanFormChanges() }
            })
            // Text entry is handled by PDFKit's native AppKit field editors.
            // Observe their commit events so form values participate in Leaf undo/save.
            for name in [NSText.didChangeNotification, NSText.didEndEditingNotification,
                         NSControl.textDidChangeNotification, NSControl.textDidEndEditingNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self, weak view] notification in
                    MainActor.assumeIsolated {
                        guard let view, let sender = notification.object as? NSView,
                              sender.isDescendant(of: view) || sender.window === view.window else { return }
                        DispatchQueue.main.async {
                            self?.store?.scanFormChanges()
                            self?.store?.objectWillChange.send()
                        }
                    }
                })
            }
        }

        /// Run before menu key equivalents so Command-arrow remains a native
        /// caret command while a search, form, or sheet text editor has focus.
        func handleKeyEvent(_ event: NSEvent, in view: LeafPDFView) -> Bool {
            guard let window = view.window, let store, store.document != nil else { return false }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let editorWindow: NSWindow?
            if event.window === window {
                editorWindow = window.attachedSheet ?? window
            } else if event.window?.sheetParent === window {
                editorWindow = event.window
            } else {
                return false
            }
            if modifiers == .command, event.keyCode == 123 || event.keyCode == 124,
               let editor = editorWindow?.firstResponder as? NSTextView, editor.isEditable {
                editor.interpretKeyEvents([event])
                return true
            }
            guard event.window === window, window.attachedSheet == nil,
                  NSApp.modalWindow == nil, modifiers.isEmpty else { return false }
            if event.keyCode == 53, view.cancelTextInteraction() { return true }
            // Toolbar and thumbnail clicks can leave the window itself focused.
            // Plain arrows still turn pages, while editors retain caret movement.
            if let editor = window.firstResponder as? NSTextView, editor.isEditable { return false }
            if let field = window.firstResponder as? NSTextField, field.isEditable { return false }
            switch event.keyCode {
            case 123: store.previousPage(); return true
            case 124: store.nextPage(); return true
            default: return false
            }
        }

        func stopObserving() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
        }
    }
}

@MainActor
final class LeafPDFView: PDFView {
    weak var store: DocumentStore?
    private var fitScheduled = false
    private var lastViewportSize = NSSize.zero
    private var appliedLayout: ReadingLayout?
    private var placingText = false
    private var cursorRevision = -1
    private var textBoxDrag: TextBoxDrag?
    private var drawingGesture: DrawingGesture?
    private var ignoreGestureRemainder = false
    private var appliedDrawingTool: DrawingTool?
    private lazy var drawingPreview = DrawingPreviewView(owner: self)
    private(set) var applyingFit = false

    private struct DrawingGesture {
        let tool: DrawingTool
        let page: PDFPage
        let color: NSColor
        let lineWidth: CGFloat
        let startViewPoint: NSPoint
        let geometry: PageGeometry
        var points: [NSPoint]
        var didMove = false
    }

    private struct TextBoxDrag {
        let annotation: PDFAnnotation
        let page: PDFPage
        let originalBounds: NSRect
        let startPoint: NSPoint
        let startViewPoint: NSPoint
        let geometry: PageGeometry
        var didMove = false
    }

    @MainActor
    private struct PageGeometry {
        let origin: NSPoint
        let xAxis: NSPoint
        let yAxis: NSPoint

        init(page: PDFPage, view: PDFView) {
            origin = view.convert(.zero, from: page)
            xAxis = view.convert(NSPoint(x: 100, y: 0), from: page)
            yAxis = view.convert(NSPoint(x: 0, y: 100), from: page)
        }

        func matches(page: PDFPage, view: PDFView) -> Bool {
            let current = PageGeometry(page: page, view: view)
            return zip([origin, xAxis, yAxis], [current.origin, current.xAxis, current.yAxis]).allSatisfy { pair in
                hypot(pair.0.x - pair.1.x, pair.0.y - pair.1.y) < 0.1
            }
        }
    }

    func synchronize(with store: DocumentStore) {
        if document !== store.document {
            cancelTransientInteractions()
            document = store.document
            if let page = document?.page(at: store.currentPageIndex) { go(to: page) }
            applyReadingLayout(store.layout)
            scheduleFit()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.store?.captureVisibleWidgets()
                self.window?.makeFirstResponder(self)
            }
        } else if appliedLayout != store.layout {
            applyReadingLayout(store.layout)
        }
        if backgroundColor != store.canvasTheme.backgroundColor {
            backgroundColor = store.canvasTheme.backgroundColor
        }
        if appliedDrawingTool != store.activeDrawingTool || cursorRevision != store.pageRevision {
            cancelTransientInteractions()
        }
        if let gesture = drawingGesture,
           gesture.color != store.drawingColor || gesture.lineWidth != store.drawingLineWidth {
            cancelTransientInteractions()
        }
        if placingText != (store.pendingTextBox != nil) || cursorRevision != store.pageRevision || appliedDrawingTool != store.activeDrawingTool {
            placingText = store.pendingTextBox != nil
            appliedDrawingTool = store.activeDrawingTool
            cursorRevision = store.pageRevision
            window?.invalidateCursorRects(for: self)
        }
    }

    func applyReadingLayout(_ layout: ReadingLayout) {
        cancelTransientInteractions()
        let page = currentPage
        appliedLayout = layout
        autoScales = false
        displaysAsBook = false
        switch layout {
        case .vertical:
            displayMode = .singlePageContinuous
            displayDirection = .vertical
        case .horizontal:
            displayMode = .singlePageContinuous
            displayDirection = .horizontal
        case .single:
            displayMode = .singlePage
            displayDirection = .vertical
        case .twoUp:
            displayMode = .twoUp
            displayDirection = .horizontal
        }
        layoutDocumentView()
        if let page { go(to: page) }
        scheduleFit()
    }

    override func layout() {
        super.layout()
        let size = scrollView?.contentSize ?? bounds.size
        if size != lastViewportSize {
            cancelTransientInteractions()
            lastViewportSize = size
            scheduleFit()
        }
    }

    func scheduleFit() {
        guard !fitScheduled else { return }
        fitScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fitScheduled = false
            self.applyFit()
        }
    }

    func applyFit() {
        guard let store, store.fitMode != .custom,
              let document, let page = document.page(at: store.currentPageIndex),
              bounds.width > 1, bounds.height > 1, !applyingFit else { return }
        applyingFit = true
        defer { applyingFit = false }
        autoScales = false
        let viewport = scrollView?.contentSize ?? bounds.size
        var pageSize = displayedSize(of: page)
        // PDFKit keeps document geometry in unscaled PDF points, including page
        // margins. Single-page and two-up layouts also add outer document margins.
        // Read that actual geometry instead of subtracting fixed screen margins,
        // which causes overflow as soon as the fitted scale exceeds 100%.
        pageSize.width += pageBreakMargins.left + pageBreakMargins.right
        pageSize.height += pageBreakMargins.top + pageBreakMargins.bottom
        if let intrinsic = documentView?.bounds.size, intrinsic.width > 0, intrinsic.height > 0 {
            if displayMode == .singlePage || displayMode == .twoUp {
                pageSize = intrinsic
            } else if displayDirection == .vertical {
                pageSize.width = intrinsic.width
            } else {
                pageSize.height = intrinsic.height
            }
        }
        let widthScale = viewport.width / max(1, pageSize.width)
        let heightScale = viewport.height / max(1, pageSize.height)
        let scale: CGFloat
        switch store.fitMode {
        case .page: scale = min(widthScale, heightScale)
        case .width: scale = widthScale
        case .height: scale = heightScale
        case .actual: scale = 1
        case .custom: return
        }
        let clamped = min(maxScaleFactor, max(minScaleFactor, scale))
        if abs(scaleFactor - clamped) > 0.002 { scaleFactor = clamped }
        let percent = Int((scaleFactor * 100).rounded())
        if store.zoomPercent != percent { store.zoomPercent = percent }
    }

    private func displayedSize(of page: PDFPage) -> NSSize {
        let size = page.bounds(for: displayBox).size
        let rotation = ((page.rotation % 360) + 360) % 360
        return rotation == 90 || rotation == 270 ? NSSize(width: size.height, height: size.width) : size
    }

    private var scrollView: NSScrollView? {
        documentView?.enclosingScrollView ?? subviews.compactMap { $0 as? NSScrollView }.first
    }

    override var scaleFactor: CGFloat {
        get { super.scaleFactor }
        set {
            if newValue != super.scaleFactor { cancelTransientInteractions() }
            super.scaleFactor = newValue
        }
    }

    override func go(to page: PDFPage) {
        cancelTransientInteractions()
        super.go(to: page)
    }

    override func go(to destination: PDFDestination) {
        cancelTransientInteractions()
        super.go(to: destination)
    }

    override func go(to selection: PDFSelection) {
        cancelTransientInteractions()
        super.go(to: selection)
    }

    override func go(to rect: NSRect, on page: PDFPage) {
        cancelTransientInteractions()
        super.go(to: rect, on: page)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let editing = window?.firstResponder is NSTextView || window?.firstResponder is NSTextField
        if modifiers.isEmpty && !editing {
            switch event.keyCode {
            case 53: if cancelTextInteraction() { return }
            case 123: store?.previousPage(); return
            case 124: store?.nextPage(); return
            case 115: store?.goToPage(index: 0); return
            case 119: store?.goToPage(index: (store?.pageCount ?? 1) - 1); return
            default: break
            }
        }
        super.keyDown(with: event)
        DispatchQueue.main.async { [weak self] in self?.store?.scanFormChanges() }
    }

    override func mouseDown(with event: NSEvent) {
        cancelTransientInteractions()
        ignoreGestureRemainder = false
        let viewPoint = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.control), drawing(at: viewPoint) != nil,
           let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        if let store, let tool = store.activeDrawingTool {
            if let page = page(for: viewPoint, nearest: false) {
                let point = convert(viewPoint, to: page)
                if page.bounds(for: .cropBox).contains(point) {
                    store.commitPendingEdits()
                    window?.makeFirstResponder(self)
                    clearSelection()
                    drawingGesture = DrawingGesture(tool: tool, page: page, color: store.drawingColor,
                                                    lineWidth: store.drawingLineWidth,
                                                    startViewPoint: viewPoint,
                                                    geometry: PageGeometry(page: page, view: self), points: [point])
                    if drawingPreview.superview == nil {
                        drawingPreview.frame = bounds
                        drawingPreview.autoresizingMask = [.width, .height]
                        addSubview(drawingPreview, positioned: .above, relativeTo: nil)
                    }
                    drawingPreview.needsDisplay = true
                }
            }
            return
        }
        if store?.pendingTextBox != nil {
            if let page = page(for: viewPoint, nearest: false) {
                let point = convert(viewPoint, to: page)
                if page.bounds(for: .cropBox).contains(point) {
                    _ = store?.placeTextBox(on: page, at: point)
                }
            }
            return
        }
        if let (page, annotation) = textBox(at: viewPoint) {
            store?.commitPendingEdits()
            window?.makeFirstResponder(self)
            if event.clickCount >= 2 {
                if DocumentStore.annotationAllowsChanges(annotation, contents: true) {
                    store?.editingTextBox = annotation
                }
            } else {
                textBoxDrag = TextBoxDrag(annotation: annotation, page: page,
                                          originalBounds: annotation.bounds,
                                          startPoint: convert(viewPoint, to: page),
                                          startViewPoint: viewPoint,
                                          geometry: PageGeometry(page: page, view: self))
            }
            return
        }
        store?.captureVisibleWidgets()
        super.mouseDown(with: event)
        DispatchQueue.main.async { [weak self] in self?.store?.scanFormChanges() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !ignoreGestureRemainder else { return }
        guard gestureGeometryIsUnchanged else {
            cancelTransientInteractions()
            return
        }
        if drawingGesture != nil {
            updateDrawingGesture(at: convert(event.locationInWindow, from: nil))
            return
        }
        guard var drag = textBoxDrag, let store else {
            super.mouseDragged(with: event)
            return
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let distance = hypot(viewPoint.x - drag.startViewPoint.x, viewPoint.y - drag.startViewPoint.y)
        guard drag.didMove || distance >= 4 else { return }
        drag.didMove = true
        let point = convert(viewPoint, to: drag.page)
        let proposed = drag.originalBounds.offsetBy(dx: point.x - drag.startPoint.x,
                                                     dy: point.y - drag.startPoint.y)
        drag.annotation.bounds = store.constrainedTextBoxBounds(proposed, on: drag.page)
        textBoxDrag = drag
        documentView?.needsDisplay = true
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        guard !ignoreGestureRemainder, gestureGeometryIsUnchanged else {
            cancelTransientInteractions()
            ignoreGestureRemainder = false
            return
        }
        if drawingGesture != nil {
            updateDrawingGesture(at: convert(event.locationInWindow, from: nil))
            if let gesture = drawingGesture {
                cancelDrawingGesture()
                if gesture.didMove {
                    _ = store?.addDrawing(tool: gesture.tool, points: gesture.points, on: gesture.page)
                }
            }
            return
        }
        guard let drag = textBoxDrag else {
            super.mouseUp(with: event)
            return
        }
        let finalOrigin = drag.annotation.bounds.origin
        drag.annotation.bounds = drag.originalBounds
        textBoxDrag = nil
        if drag.didMove { _ = store?.moveTextBox(drag.annotation, to: finalOrigin) }
        documentView?.needsDisplay = true
        window?.invalidateCursorRects(for: self)
        NSCursor.openHand.set()
    }

    // PDFKit's document subview normally receives mouse events directly. Route
    // only drawing, placement and text-box interactions here; links, forms, notes and
    // ordinary text selection retain PDFKit's normal event handling.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return super.hitTest(point) }
        if (store?.pendingTextBox != nil || store?.activeDrawingTool != nil), let page = page(for: local, nearest: false),
           page.bounds(for: .cropBox).contains(convert(local, to: page)) { return self }
        if let event = NSApp.currentEvent,
           event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)),
           drawing(at: local) != nil { return self }
        if textBox(at: local) != nil { return self }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if store?.pendingTextBox != nil || store?.activeDrawingTool != nil {
            addCursorRect(visibleRect, cursor: .crosshair)
        } else if document?.allowsCommenting == true {
            for page in visiblePages {
                for annotation in page.annotations where isEditableTextBox(annotation) {
                    let rect = convert(annotation.bounds, from: page).intersection(visibleRect)
                    if !rect.isEmpty { addCursorRect(rect, cursor: .openHand) }
                }
            }
        }
    }

    @discardableResult
    func cancelTextInteraction() -> Bool {
        if drawingGesture != nil {
            cancelTransientInteractions()
            return true
        }
        if store?.activeDrawingTool != nil {
            store?.endDrawing()
            return true
        }
        if textBoxDrag != nil {
            cancelTransientInteractions()
            return true
        }
        if store?.pendingTextBox != nil {
            store?.cancelTextPlacement()
            return true
        }
        return false
    }

    private func updateDrawingGesture(at viewPoint: NSPoint) {
        guard var gesture = drawingGesture else { return }
        let point = convert(viewPoint, to: gesture.page)
        gesture.didMove = gesture.didMove || hypot(viewPoint.x - gesture.startViewPoint.x,
                                                  viewPoint.y - gesture.startViewPoint.y) >= 3
        if gesture.tool == .pen {
            if let last = gesture.points.last, hypot(last.x - point.x, last.y - point.y) * scaleFactor >= 0.5 {
                gesture.points.append(point)
            }
        } else {
            gesture.points = [gesture.points[0], point]
        }
        drawingGesture = gesture
        drawingPreview.needsDisplay = true
    }

    private func cancelDrawingGesture() {
        guard drawingGesture != nil else { return }
        drawingGesture = nil
        // A preview never enters the PDF document or its undo history.
        drawingPreview.removeFromSuperview()
    }

    /// Discard provisional geometry before navigation, saving, or changing the
    /// viewport. A later mouse-up from that same drag must not commit an edit.
    func cancelTransientInteractions() {
        if drawingGesture != nil || textBoxDrag != nil { ignoreGestureRemainder = true }
        cancelDrawingGesture()
        cancelTextBoxDrag()
    }

    private var gestureGeometryIsUnchanged: Bool {
        if let gesture = drawingGesture { return gesture.geometry.matches(page: gesture.page, view: self) }
        if let drag = textBoxDrag { return drag.geometry.matches(page: drag.page, view: self) }
        return true
    }

    fileprivate func drawDrawingPreview(in overlay: NSView) {
        guard let gesture = drawingGesture,
              let annotation = drawingAnnotation(tool: gesture.tool, points: gesture.points,
                                                 on: gesture.page, color: gesture.color,
                                                 lineWidth: gesture.lineWidth),
              let context = NSGraphicsContext.current?.cgContext else { return }
        func mapped(_ point: NSPoint) -> NSPoint {
            overlay.convert(convert(point, from: gesture.page), from: self)
        }
        let origin = mapped(.zero)
        let x = mapped(NSPoint(x: 1, y: 0))
        let y = mapped(NSPoint(x: 0, y: 1))
        context.saveGState()
        context.concatenate(CGAffineTransform(a: x.x - origin.x, b: x.y - origin.y,
                                             c: y.x - origin.x, d: y.y - origin.y,
                                             tx: origin.x, ty: origin.y))
        annotation.draw(with: .cropBox, in: context)
        context.restoreGState()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let annotation = drawing(at: convert(event.locationInWindow, from: nil)) else {
            return super.menu(for: event)
        }
        let menu = NSMenu(title: "Drawing")
        let item = NSMenuItem(title: "Delete Drawing", action: #selector(deleteDrawing(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = annotation
        menu.addItem(item)
        return menu
    }

    override func rightMouseDown(with event: NSEvent) {
        if drawing(at: convert(event.locationInWindow, from: nil)) != nil, let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    @objc private func deleteDrawing(_ sender: NSMenuItem) {
        guard let annotation = sender.representedObject as? PDFAnnotation else { return }
        _ = store?.removeDrawing(annotation)
    }

    private func drawing(at point: NSPoint) -> PDFAnnotation? {
        guard document?.allowsCommenting == true,
              let page = page(for: point, nearest: false) else { return nil }
        let pagePoint = convert(point, to: page)
        return page.annotations.reversed().first {
            isDrawingAnnotation($0) &&
            $0.shouldDisplay && DocumentStore.annotationAllowsChanges($0) &&
            $0.bounds.insetBy(dx: -3 / scaleFactor, dy: -3 / scaleFactor).contains(pagePoint)
        }
    }

    private func cancelTextBoxDrag() {
        guard let drag = textBoxDrag else { return }
        textBoxDrag = nil
        drag.annotation.bounds = drag.originalBounds
        documentView?.needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private func isEditableTextBox(_ annotation: PDFAnnotation) -> Bool {
        annotation.type == "FreeText" && annotation.shouldDisplay && DocumentStore.annotationAllowsChanges(annotation)
    }

    private func textBox(at point: NSPoint) -> (PDFPage, PDFAnnotation)? {
        guard document?.allowsCommenting == true,
              let page = page(for: point, nearest: false) else { return nil }
        let pagePoint = convert(point, to: page)
        guard page.bounds(for: .cropBox).contains(pagePoint),
              let annotation = page.annotations.reversed().first(where: {
                  isEditableTextBox($0) && $0.bounds.contains(pagePoint)
              }) else { return nil }
        return (page, annotation)
    }

    override func magnify(with event: NSEvent) {
        store?.fitMode = .custom
        super.magnify(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggedPDF(from: sender) == nil ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        draggedPDF(from: sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = draggedPDF(from: sender) else { return false }
        DispatchQueue.main.async { [weak self] in self?.store?.open(url: url) }
        return true
    }

    private func draggedPDF(from sender: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return urls?.first { $0.pathExtension.lowercased() == "pdf" }
    }
}

@MainActor
private final class DrawingPreviewView: NSView {
    weak var owner: LeafPDFView?
    init(owner: LeafPDFView) {
        self.owner = owner
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { owner?.drawDrawingPreview(in: self) }
}
