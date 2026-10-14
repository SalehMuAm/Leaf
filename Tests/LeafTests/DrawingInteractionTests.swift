import AppKit
import PDFKit
import XCTest
@testable import Leaf

final class DrawingInteractionTests: XCTestCase {
    func testCommandArrowsMoveTheEditorCaretWithoutTurningPages() async throws {
        try await MainActor.run {
            let fixture = try Self.makeFixture(rotation: 0, scale: 1)
            defer { fixture.window.close() }
            let second = try XCTUnwrap(fixture.page.copy() as? PDFPage)
            fixture.store.document?.insert(second, at: 1)
            let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
            editor.string = "First line\nSecond line"
            editor.isEditable = true
            fixture.view.addSubview(editor)
            XCTAssertTrue(fixture.window.makeFirstResponder(editor))
            editor.setSelectedRange(NSRange(location: 2, length: 0))
            let coordinator = PDFCanvas.Coordinator(store: fixture.store)
            let right = try Self.keyEvent(code: 124, modifiers: .command, window: fixture.window)
            let left = try Self.keyEvent(code: 123, modifiers: .command, window: fixture.window)

            XCTAssertTrue(coordinator.handleKeyEvent(right, in: fixture.view))
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 10, length: 0))
            XCTAssertTrue(coordinator.handleKeyEvent(left, in: fixture.view))
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0))
            XCTAssertEqual(fixture.store.currentPageIndex, 0)
            XCTAssertTrue(fixture.window.firstResponder === editor)
            let plainArrow = try Self.keyEvent(code: 124, modifiers: [], window: fixture.window)
            XCTAssertFalse(coordinator.handleKeyEvent(plainArrow, in: fixture.view),
                           "Unmodified arrows must remain with the active native editor.")

            XCTAssertTrue(fixture.window.makeFirstResponder(fixture.view))
            XCTAssertFalse(coordinator.handleKeyEvent(right, in: fixture.view),
                           "Outside text editors the menu keeps its Command-arrow navigation shortcut.")
        }
    }

    func testCommandArrowsStayInsideAttachedSheetEditors() async throws {
        try await MainActor.run {
            let fixture = try Self.makeFixture(rotation: 0, scale: 1)
            defer { fixture.window.close() }
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 150),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            sheet.isReleasedWhenClosed = false
            let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 150))
            editor.string = "A note for this page"
            editor.isEditable = true
            sheet.contentView = editor
            fixture.window.beginSheet(sheet)
            defer { fixture.window.endSheet(sheet); sheet.close() }
            XCTAssertTrue(sheet.makeFirstResponder(editor))
            editor.setSelectedRange(NSRange(location: 2, length: 0))
            let coordinator = PDFCanvas.Coordinator(store: fixture.store)
            let right = try Self.keyEvent(code: 124, modifiers: .command, window: sheet)

            XCTAssertTrue(coordinator.handleKeyEvent(right, in: fixture.view))
            XCTAssertEqual(editor.selectedRange().location, editor.string.utf16.count)
            XCTAssertEqual(fixture.store.currentPageIndex, 0)
            XCTAssertTrue(sheet.firstResponder === editor)
        }
    }

    func testPageNavigationCancelsAnUnfinishedDrawing() async throws {
        try await MainActor.run {
            let fixture = try Self.makeFixture(rotation: 90, scale: 1.2)
            defer { fixture.window.close() }
            let second = try XCTUnwrap(fixture.page.copy() as? PDFPage)
            fixture.store.document?.insert(second, at: 1)
            XCTAssertTrue(fixture.store.beginDrawing(tool: .rectangle))
            fixture.view.synchronize(with: fixture.store)
            fixture.view.mouseDown(with: try Self.event(.leftMouseDown, pagePoint: NSPoint(x: 100, y: 130), in: fixture))
            fixture.view.mouseDragged(with: try Self.event(.leftMouseDragged, pagePoint: NSPoint(x: 180, y: 210), in: fixture))

            fixture.store.goToPage(index: 1)
            fixture.view.mouseUp(with: try Self.event(.leftMouseUp, pagePoint: NSPoint(x: 240, y: 270), in: fixture))

            XCTAssertEqual(fixture.store.currentPageIndex, 1)
            XCTAssertTrue(fixture.page.annotations.isEmpty)
            XCTAssertTrue(second.annotations.isEmpty)
            XCTAssertFalse(fixture.store.isModified)
            XCTAssertFalse(fixture.store.canUndo)
        }
    }

    func testViewportChangesCancelProvisionalTextMovement() async throws {
        try await MainActor.run {
            for operation in ["zoom", "layout", "resize", "navigation"] {
                let fixture = try Self.makeFixture(rotation: 90, scale: 1.2)
                defer { fixture.window.close() }
                let annotation = Self.addExistingTextBox(to: fixture)
                let originalBounds = annotation.bounds
                fixture.view.mouseDown(with: try Self.event(.leftMouseDown, pagePoint: NSPoint(x: 130, y: 150), in: fixture))
                fixture.view.mouseDragged(with: try Self.event(.leftMouseDragged, pagePoint: NSPoint(x: 170, y: 210), in: fixture))
                XCTAssertNotEqual(annotation.bounds, originalBounds, "The text should move provisionally during the drag.")

                switch operation {
                case "zoom": fixture.store.zoomIn()
                case "layout": fixture.view.applyReadingLayout(.twoUp)
                case "resize":
                    fixture.view.setFrameSize(NSSize(width: 650, height: 550))
                    fixture.view.layoutSubtreeIfNeeded()
                default: fixture.view.go(to: fixture.page)
                }
                fixture.view.mouseUp(with: try Self.event(.leftMouseUp, pagePoint: NSPoint(x: 200, y: 250), in: fixture))

                XCTAssertEqual(annotation.bounds, originalBounds, "\(operation) must restore the uncommitted text position.")
                XCTAssertFalse(fixture.store.isModified)
                XCTAssertFalse(fixture.store.canUndo)
            }
        }
    }

    func testSavingDuringTextDragDoesNotPersistProvisionalBounds() async throws {
        try await MainActor.run {
            let fixture = try Self.makeFixture(rotation: 0, scale: 1)
            defer { fixture.window.close() }
            let originalRecents = UserDefaults.standard.object(forKey: "recentPDFs")
            defer { UserDefaults.standard.set(originalRecents, forKey: "recentPDFs") }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Leaf-drag-save-\(UUID()).pdf")
            defer { try? FileManager.default.removeItem(at: url) }
            fixture.store.fileURL = url
            let annotation = Self.addExistingTextBox(to: fixture)
            let originalBounds = annotation.bounds
            fixture.view.mouseDown(with: try Self.event(.leftMouseDown, pagePoint: NSPoint(x: 130, y: 150), in: fixture))
            fixture.view.mouseDragged(with: try Self.event(.leftMouseDragged, pagePoint: NSPoint(x: 180, y: 220), in: fixture))
            XCTAssertNotEqual(annotation.bounds, originalBounds)

            XCTAssertTrue(fixture.store.save())
            fixture.view.mouseUp(with: try Self.event(.leftMouseUp, pagePoint: NSPoint(x: 200, y: 240), in: fixture))

            let reopened = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0)?.annotations.first { $0.type == "FreeText" })
            XCTAssertEqual(reopened.bounds, originalBounds)
            XCTAssertEqual(annotation.bounds, originalBounds)
            XCTAssertFalse(fixture.store.isModified)
            XCTAssertFalse(fixture.store.canUndo)
        }
    }

    func testCompletedTextDragRemainsOneUndoableEdit() async throws {
        try await MainActor.run {
            let fixture = try Self.makeFixture(rotation: 270, scale: 0.7)
            defer { fixture.window.close() }
            let annotation = Self.addExistingTextBox(to: fixture)
            let originalBounds = annotation.bounds
            fixture.view.mouseDown(with: try Self.event(.leftMouseDown, pagePoint: NSPoint(x: 130, y: 150), in: fixture))
            fixture.view.mouseDragged(with: try Self.event(.leftMouseDragged, pagePoint: NSPoint(x: 170, y: 200), in: fixture))
            fixture.view.mouseUp(with: try Self.event(.leftMouseUp, pagePoint: NSPoint(x: 170, y: 200), in: fixture))

            XCTAssertEqual(annotation.bounds.minX, originalBounds.minX + 40, accuracy: 0.01)
            XCTAssertEqual(annotation.bounds.minY, originalBounds.minY + 50, accuracy: 0.01)
            XCTAssertTrue(fixture.store.isModified)
            fixture.store.undo()
            XCTAssertEqual(annotation.bounds, originalBounds)
            XCTAssertFalse(fixture.store.isModified)
            XCTAssertFalse(fixture.store.canUndo)
        }
    }

    func testLockedTextIsNotRoutedToTheDragHandler() async throws {
        try await MainActor.run {
            let fixture = try Self.makeFixture(rotation: 0, scale: 1)
            defer { fixture.window.close() }
            let annotation = Self.addExistingTextBox(to: fixture)
            let point = fixture.view.convert(NSPoint(x: 130, y: 150), from: fixture.page)
            let parentPoint = fixture.view.convert(point, to: fixture.view.superview)
            XCTAssertTrue(fixture.view.hitTest(parentPoint) === fixture.view)
            for flags in [64, 128] {
                annotation.setValue(NSNumber(value: flags), forAnnotationKey: PDFAnnotationKey(rawValue: "/F"))
                XCTAssertFalse(fixture.view.hitTest(parentPoint) === fixture.view)
            }
            annotation.setValue(NSNumber(value: 512), forAnnotationKey: PDFAnnotationKey(rawValue: "/F"))
            let event = try Self.event(.leftMouseDown, pagePoint: NSPoint(x: 130, y: 150), in: fixture, clickCount: 2)
            fixture.view.mouseDown(with: event)
            XCTAssertNil(fixture.store.editingTextBox, "LockedContents must prevent opening Leaf’s editor.")
        }
    }

    func testRectangleGestureCommitsOneUndoableEditAtEveryRotationAndZoom() async throws {
        try await MainActor.run {
            for rotation in [0, 90, 180, 270] {
                for scale in [CGFloat(0.7), CGFloat(1.2)] {
                    let fixture = try Self.makeFixture(rotation: rotation, scale: scale)
                    defer { fixture.window.close() }
                    let start = NSPoint(x: 100, y: 130)
                    let end = NSPoint(x: 240, y: 270)
                    XCTAssertTrue(fixture.store.beginDrawing(tool: .rectangle))
                    fixture.view.synchronize(with: fixture.store)
                    fixture.view.mouseDown(with: try Self.event(.leftMouseDown, pagePoint: start, in: fixture))
                    fixture.view.mouseDragged(with: try Self.event(.leftMouseDragged, pagePoint: end, in: fixture))

                    XCTAssertTrue(fixture.page.annotations.isEmpty, "A live preview must stay outside the PDF.")
                    XCTAssertFalse(fixture.store.isModified)
                    XCTAssertFalse(fixture.store.canUndo)

                    fixture.view.mouseUp(with: try Self.event(.leftMouseUp, pagePoint: end, in: fixture))
                    let annotation = try XCTUnwrap(fixture.page.annotations.first)
                    XCTAssertEqual(fixture.page.annotations.count, 1)
                    XCTAssertEqual(annotation.type, "Square")
                    XCTAssertEqual(annotation.bounds.minX, start.x, accuracy: 0.01)
                    XCTAssertEqual(annotation.bounds.minY, start.y, accuracy: 0.01)
                    XCTAssertEqual(annotation.bounds.maxX, end.x, accuracy: 0.01)
                    XCTAssertEqual(annotation.bounds.maxY, end.y, accuracy: 0.01)
                    XCTAssertTrue(fixture.store.isModified)
                    fixture.store.undo()
                    XCTAssertTrue(fixture.page.annotations.isEmpty)
                    XCTAssertFalse(fixture.store.isModified)
                    XCTAssertFalse(fixture.store.canUndo, "One gesture must produce exactly one undo step.")
                    fixture.store.redo()
                    XCTAssertTrue(fixture.page.annotations.first === annotation)
                }
            }
        }
    }

    func testEscapeCancelsPenPreviewWithoutEditingTheDocument() async throws {
        try await MainActor.run {
            let fixture = try Self.makeFixture(rotation: 90, scale: 1.2)
            defer { fixture.window.close() }
            XCTAssertTrue(fixture.store.beginDrawing(tool: .pen))
            fixture.view.synchronize(with: fixture.store)
            let originalSubviews = Set(fixture.view.subviews.map(ObjectIdentifier.init))
            fixture.view.mouseDown(with: try Self.event(.leftMouseDown, pagePoint: NSPoint(x: 100, y: 130), in: fixture))
            fixture.view.mouseDragged(with: try Self.event(.leftMouseDragged, pagePoint: NSPoint(x: 130, y: 180), in: fixture))
            fixture.view.mouseDragged(with: try Self.event(.leftMouseDragged, pagePoint: NSPoint(x: 220, y: 230), in: fixture))
            XCTAssertTrue(fixture.view.subviews.contains { !originalSubviews.contains(ObjectIdentifier($0)) })
            XCTAssertTrue(fixture.view.cancelTextInteraction())
            XCTAssertEqual(fixture.store.activeDrawingTool, .pen, "The first Escape cancels only the stroke in progress.")
            XCTAssertTrue(fixture.view.subviews.allSatisfy { originalSubviews.contains(ObjectIdentifier($0)) })
            XCTAssertTrue(fixture.page.annotations.isEmpty)
            XCTAssertFalse(fixture.store.isModified)
            XCTAssertFalse(fixture.store.canUndo)
            XCTAssertTrue(fixture.view.cancelTextInteraction())
            XCTAssertNil(fixture.store.activeDrawingTool)
        }
    }

    func testClickWithoutDragDoesNotCreateADrawing() async throws {
        try await MainActor.run {
            let fixture = try Self.makeFixture(rotation: 0, scale: 1)
            defer { fixture.window.close() }
            XCTAssertTrue(fixture.store.beginDrawing(tool: .pen))
            fixture.view.synchronize(with: fixture.store)
            let point = NSPoint(x: 150, y: 200)
            fixture.view.mouseDown(with: try Self.event(.leftMouseDown, pagePoint: point, in: fixture))
            fixture.view.mouseUp(with: try Self.event(.leftMouseUp, pagePoint: point, in: fixture))
            XCTAssertTrue(fixture.page.annotations.isEmpty)
            XCTAssertFalse(fixture.store.isModified)
            XCTAssertFalse(fixture.store.canUndo)
        }
    }

    func testRightAndControlClickMenusDeleteTheTargetDrawingWithUndo() async throws {
        try await MainActor.run {
            let fixture = try Self.makeFixture(rotation: 270, scale: 1.2)
            defer { fixture.window.close() }
            XCTAssertTrue(fixture.store.addDrawing(tool: .rectangle,
                                                   points: [NSPoint(x: 100, y: 130), NSPoint(x: 240, y: 270)],
                                                   on: fixture.page))
            let annotation = try XCTUnwrap(fixture.page.annotations.first)
            let target = NSPoint(x: 100, y: 200)
            let rightClick = try Self.event(.rightMouseDown, pagePoint: target, in: fixture)
            let controlClick = try Self.event(.leftMouseDown, pagePoint: target, in: fixture, modifiers: .control)
            for event in [rightClick, controlClick] {
                let menu = try XCTUnwrap(fixture.view.menu(for: event))
                let item = try XCTUnwrap(menu.items.first { $0.title == "Delete Drawing" })
                XCTAssertTrue(item.representedObject as? PDFAnnotation === annotation)
                let action = try XCTUnwrap(item.action)
                XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
                XCTAssertTrue(fixture.page.annotations.isEmpty)
                fixture.store.undo()
                XCTAssertTrue(fixture.page.annotations.first === annotation)
            }
        }
    }

    func testDetachedPreviewRendersAtTheMappedPageRectangle() async throws {
        try await MainActor.run {
            for rotation in [0, 90, 180, 270] {
                for scale in [CGFloat(0.7), CGFloat(1.2)] {
                    let fixture = try Self.makeFixture(rotation: rotation, scale: scale)
                    defer { fixture.window.close() }
                    fixture.store.drawingColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
                    fixture.store.drawingLineWidth = 6
                    XCTAssertTrue(fixture.store.beginDrawing(tool: .rectangle))
                    fixture.view.synchronize(with: fixture.store)
                    let existing = Set(fixture.view.subviews.map(ObjectIdentifier.init))
                    fixture.view.mouseDown(with: try Self.event(.leftMouseDown, pagePoint: NSPoint(x: 100, y: 130), in: fixture))
                    fixture.view.mouseDragged(with: try Self.event(.leftMouseDragged, pagePoint: NSPoint(x: 240, y: 270), in: fixture))
                    let preview = try XCTUnwrap(fixture.view.subviews.first { !existing.contains(ObjectIdentifier($0)) })
                    let pageRect = NSRect(x: 100, y: 130, width: 140, height: 140)
                    let expectedRect = preview.convert(fixture.view.convert(pageRect, from: fixture.page), from: fixture.view)
                    let renderedBounds = try Self.renderedStrokeBounds(size: preview.bounds.size) { _ in
                        preview.draw(preview.bounds)
                    }
                    let referenceBounds = try Self.renderedStrokeBounds(size: preview.bounds.size) { context in
                        context.setStrokeColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
                        context.setLineWidth(6 * scale)
                        context.stroke(expectedRect)
                    }
                    XCTAssertEqual(renderedBounds.minX, referenceBounds.minX, accuracy: 5, "Rotation \(rotation), scale \(scale)")
                    XCTAssertEqual(renderedBounds.minY, referenceBounds.minY, accuracy: 5, "Rotation \(rotation), scale \(scale)")
                    XCTAssertEqual(renderedBounds.maxX, referenceBounds.maxX, accuracy: 5, "Rotation \(rotation), scale \(scale)")
                    XCTAssertEqual(renderedBounds.maxY, referenceBounds.maxY, accuracy: 5, "Rotation \(rotation), scale \(scale)")
                    XCTAssertTrue(fixture.page.annotations.isEmpty)
                    XCTAssertFalse(fixture.store.isModified)
                    fixture.view.cancelTextInteraction()
                }
            }
        }
    }

    @MainActor
    private struct Fixture {
        let store: DocumentStore
        let view: LeafPDFView
        let window: NSWindow
        let page: PDFPage
    }

    @MainActor
    private static func makeFixture(rotation: Int, scale: CGFloat) throws -> Fixture {
        _ = NSApplication.shared
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 500)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        let page = try XCTUnwrap(document.page(at: 0))
        page.setBounds(CGRect(x: 40, y: 30, width: 300, height: 400), for: .cropBox)
        page.rotation = rotation
        let store = DocumentStore()
        store.document = document
        store.fitMode = .custom
        let view = LeafPDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.store = store
        store.pdfView = view
        view.displayBox = .cropBox
        view.displaysPageBreaks = false
        view.minScaleFactor = 0.1
        view.maxScaleFactor = 8
        view.synchronize(with: store)
        view.applyReadingLayout(.single)
        view.scaleFactor = scale
        view.layoutDocumentView()
        view.layoutSubtreeIfNeeded()
        return Fixture(store: store, view: view, window: window, page: page)
    }

    @MainActor
    private static func keyEvent(code: UInt16, modifiers: NSEvent.ModifierFlags, window: NSWindow) throws -> NSEvent {
        let characters = String(UnicodeScalar(code == 123 ? 0xF702 : 0xF703)!)
        return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                            timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                            characters: characters, charactersIgnoringModifiers: characters,
                                            isARepeat: false, keyCode: code))
    }

    @MainActor
    private static func addExistingTextBox(to fixture: Fixture) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: NSRect(x: 100, y: 130, width: 90, height: 45),
                                       forType: .freeText, withProperties: nil)
        annotation.contents = "Existing text"
        annotation.font = .systemFont(ofSize: 14)
        fixture.page.addAnnotation(annotation)
        fixture.store.captureVisibleWidgets()
        return annotation
    }

    @MainActor
    private static func event(_ type: NSEvent.EventType, pagePoint: NSPoint, in fixture: Fixture,
                              modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1) throws -> NSEvent {
        let viewPoint = fixture.view.convert(pagePoint, from: fixture.page)
        let windowPoint = fixture.view.convert(viewPoint, to: nil)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: windowPoint,
                                              modifierFlags: modifiers, timestamp: 0,
                                              windowNumber: fixture.window.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: clickCount, pressure: 1))
    }

    @MainActor
    private static func renderedStrokeBounds(size: NSSize, draw: (CGContext) -> Void) throws -> CGRect {
        let width = Int(size.width.rounded(.up))
        let height = Int(size.height.rounded(.up))
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: width * height * 4, alignment: 64)
        defer { bytes.deallocate() }
        bytes.initializeMemory(as: UInt8.self, repeating: 0, count: width * height * 4)
        let format = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let context = try XCTUnwrap(CGContext(data: bytes, width: width, height: height,
                                             bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: format))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        draw(context)
        NSGraphicsContext.restoreGraphicsState()
        let pixels = bytes.assumingMemoryBound(to: UInt8.self)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if pixels[offset] > 150 && pixels[offset + 1] < 100 && pixels[offset + 2] < 100 && pixels[offset + 3] > 30 {
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        XCTAssertGreaterThanOrEqual(maxX, minX, "The detached preview must render a visible stroke.")
        XCTAssertGreaterThanOrEqual(maxY, minY, "The detached preview must render a visible stroke.")
        return CGRect(x: CGFloat(minX), y: CGFloat(minY),
                      width: CGFloat(max(0, maxX - minX)), height: CGFloat(max(0, maxY - minY)))
    }
}
