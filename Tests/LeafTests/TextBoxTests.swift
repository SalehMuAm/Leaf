import AppKit
import PDFKit
import XCTest
@testable import Leaf

final class TextBoxTests: XCTestCase {
    func testDraftDoesNotEditUntilPlacedAndCanBeCancelled() async throws {
        try await MainActor.run {
            let (store, page) = try Self.makeDocument()
            XCTAssertTrue(store.beginTextPlacement(text: "  A useful addition. \n", fontSize: 16))
            XCTAssertEqual(store.pendingTextBox?.text, "A useful addition.")
            XCTAssertFalse(store.isModified)
            XCTAssertTrue(page.annotations.isEmpty)
            store.cancelTextPlacement()
            XCTAssertNil(store.pendingTextBox)
            XCTAssertFalse(store.placeTextBox(on: page, at: NSPoint(x: 100, y: 700)))
            XCTAssertFalse(store.canUndo)
        }
    }

    func testPlacementUndoRedoAndSavePreserveTextFontAndPosition() async throws {
        try await MainActor.run {
            let oldRecentURLs = UserDefaults.standard.object(forKey: "recentPDFs")
            defer { UserDefaults.standard.set(oldRecentURLs, forKey: "recentPDFs") }
            let (store, page) = try Self.makeDocument()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("LeafText-\(UUID()).pdf")
            defer { try? FileManager.default.removeItem(at: url) }
            store.fileURL = url
            XCTAssertTrue(store.beginTextPlacement(text: "Added text\nSecond line", fontSize: 20))
            XCTAssertTrue(store.placeTextBox(on: page, at: NSPoint(x: 100, y: 700)))
            let annotation = try XCTUnwrap(page.annotations.first)
            XCTAssertEqual(annotation.type, "FreeText")
            XCTAssertEqual(annotation.contents, "Added text\nSecond line")
            XCTAssertEqual(annotation.font?.pointSize, 20)
            XCTAssertEqual(annotation.bounds.minX, 100)
            XCTAssertEqual(annotation.bounds.maxY, 700)
            XCTAssertGreaterThan(annotation.bounds.height, 40)
            XCTAssertNil(store.pendingTextBox)
            XCTAssertTrue(store.isModified)

            store.undo()
            XCTAssertTrue(page.annotations.isEmpty)
            XCTAssertFalse(store.isModified)
            store.redo()
            XCTAssertTrue(page.annotations.first === annotation)
            XCTAssertTrue(store.save())
            XCTAssertFalse(store.isModified)
            let reopened = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0)?.annotations.first)
            XCTAssertEqual(reopened.contents, annotation.contents)
            XCTAssertEqual(reopened.font?.pointSize, 20)
            XCTAssertEqual(reopened.bounds, annotation.bounds)
            store.undo()
            XCTAssertTrue(store.isModified)
            store.redo()
            XCTAssertFalse(store.isModified)
        }
    }

    func testEditingReflowsTextAndRestoresOriginalOnUndo() async throws {
        try await MainActor.run {
            let (store, page) = try Self.makeDocument()
            XCTAssertTrue(store.beginTextPlacement(text: "Original", fontSize: 16))
            XCTAssertTrue(store.placeTextBox(on: page, at: NSPoint(x: 70, y: 700)))
            let annotation = try XCTUnwrap(page.annotations.first)
            let originalBounds = annotation.bounds
            annotation.fontColor = .systemBlue
            let originalColor = annotation.fontColor
            store.editingTextBox = annotation

            let replacement = "A longer text box that wraps onto several lines and stays fully readable on the page."
            XCTAssertTrue(store.updateTextBox(annotation, text: replacement, fontSize: 24))
            XCTAssertEqual(annotation.contents, replacement)
            XCTAssertEqual(annotation.font?.pointSize, 24)
            XCTAssertEqual(annotation.fontColor, originalColor)
            XCTAssertEqual(annotation.bounds.maxY, originalBounds.maxY)
            XCTAssertGreaterThan(annotation.bounds.height, originalBounds.height)
            XCTAssertTrue(page.bounds(for: .cropBox).contains(annotation.bounds))
            XCTAssertNil(store.editingTextBox)

            store.undo()
            XCTAssertEqual(annotation.contents, "Original")
            XCTAssertEqual(annotation.font?.pointSize, 16)
            XCTAssertEqual(annotation.bounds, originalBounds)
            store.redo()
            XCTAssertEqual(annotation.contents, replacement)
            XCTAssertTrue(store.removeTextBox(annotation))
            XCTAssertTrue(page.annotations.isEmpty)
            store.undo()
            XCTAssertTrue(page.annotations.contains { $0 === annotation })
            XCTAssertEqual(annotation.contents, replacement)
        }
    }

    func testMoveClampsToPageAndIsOneUndoableEdit() async throws {
        try await MainActor.run {
            let (store, page) = try Self.makeDocument()
            XCTAssertTrue(store.beginTextPlacement(text: "Move me", fontSize: 16))
            XCTAssertTrue(store.placeTextBox(on: page, at: NSPoint(x: 80, y: 700)))
            let annotation = try XCTUnwrap(page.annotations.first)
            let originalBounds = annotation.bounds
            XCTAssertTrue(store.moveTextBox(annotation, to: NSPoint(x: 900, y: -500)))
            XCTAssertTrue(page.bounds(for: .cropBox).contains(annotation.bounds))
            XCTAssertEqual(annotation.bounds.maxX, page.bounds(for: .cropBox).maxX)
            XCTAssertEqual(annotation.bounds.minY, page.bounds(for: .cropBox).minY)
            store.undo()
            XCTAssertEqual(annotation.bounds, originalBounds)
            store.undo()
            XCTAssertTrue(page.annotations.isEmpty)
            XCTAssertFalse(store.isModified)
        }
    }

    func testRotatedPagesUseUprightTextAndRespectOffsetCropBoxes() async throws {
        try await MainActor.run {
            for rotation in [0, 90, 180, 270] {
                let (store, page) = try Self.makeDocument()
                let crop = NSRect(x: 40, y: 30, width: 300, height: 400)
                page.setBounds(crop, for: .cropBox)
                page.rotation = rotation
                XCTAssertTrue(store.beginTextPlacement(text: "First line\nSecond line", fontSize: 16))
                XCTAssertTrue(store.placeTextBox(on: page, at: NSPoint(x: crop.maxX, y: crop.maxY)))
                let annotation = try XCTUnwrap(page.annotations.first)
                XCTAssertTrue(crop.contains(annotation.bounds), "Rotation \(rotation) must keep the box on the page.")
                XCTAssertEqual((annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Rotate")) as? NSNumber)?.intValue, rotation)
                if rotation == 90 || rotation == 270 {
                    XCTAssertGreaterThan(annotation.bounds.height, annotation.bounds.width)
                } else {
                    XCTAssertGreaterThan(annotation.bounds.width, annotation.bounds.height)
                }
                XCTAssertTrue(store.updateTextBox(annotation, text: "Updated\nwith more\nlines", fontSize: 18))
                XCTAssertTrue(crop.contains(annotation.bounds))
                let bytes = try XCTUnwrap(store.document?.dataRepresentation())
                let reopened = try XCTUnwrap(PDFDocument(data: bytes)?.page(at: 0)?.annotations.first)
                XCTAssertEqual(reopened.bounds, annotation.bounds)
                XCTAssertEqual(reopened.contents, "Updated\nwith more\nlines")
                XCTAssertEqual((reopened.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Rotate")) as? NSNumber)?.intValue, rotation)
            }
        }
    }

    func testBlankOversizedAndTinyPageTextFailWithoutChangingDocument() async throws {
        try await MainActor.run {
            let (store, page) = try Self.makeDocument()
            XCTAssertFalse(store.beginTextPlacement(text: " \n\t ", fontSize: 16))
            XCTAssertFalse(store.beginTextPlacement(text: "Text", fontSize: .nan))
            XCTAssertFalse(store.beginTextPlacement(text: "Text", fontSize: 200))
            XCTAssertFalse(store.beginTextPlacement(text: String(repeating: "Long paragraph. ", count: 600), fontSize: 72))
            XCTAssertNotNil(store.errorMessage)
            XCTAssertNil(store.pendingTextBox)
            XCTAssertTrue(page.annotations.isEmpty)
            XCTAssertFalse(store.isModified)
            XCTAssertFalse(store.canUndo)

            page.setBounds(NSRect(x: 0, y: 0, width: 30, height: 30), for: .cropBox)
            XCTAssertFalse(store.beginTextPlacement(text: "Tiny page", fontSize: 16))
            XCTAssertTrue(page.annotations.isEmpty)
            XCTAssertFalse(store.canUndo)
        }
    }

    func testInvalidUpdateAndForeignPageLeaveExistingTextUnchanged() async throws {
        try await MainActor.run {
            let (store, page) = try Self.makeDocument()
            let (_, otherPage) = try Self.makeDocument()
            XCTAssertTrue(store.beginTextPlacement(text: "Keep this", fontSize: 16))
            XCTAssertFalse(store.placeTextBox(on: otherPage, at: NSPoint(x: 100, y: 700)))
            XCTAssertNotNil(store.pendingTextBox)
            XCTAssertTrue(store.placeTextBox(on: page, at: NSPoint(x: 100, y: 700)))
            let annotation = try XCTUnwrap(page.annotations.first)
            let originalBounds = annotation.bounds
            XCTAssertFalse(store.updateTextBox(annotation, text: " ", fontSize: 16))
            XCTAssertFalse(store.updateTextBox(annotation, text: String(repeating: "Too much text. ", count: 400), fontSize: 72))
            XCTAssertEqual(annotation.contents, "Keep this")
            XCTAssertEqual(annotation.bounds, originalBounds)
            store.undo()
            XCTAssertTrue(page.annotations.isEmpty, "Invalid updates must not add undo entries.")
            XCTAssertFalse(store.isModified)
        }
    }

    @MainActor
    private static func makeDocument() throws -> (DocumentStore, PDFPage) {
        let bytes = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes as CFMutableData))
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: bytes as Data))
        let store = DocumentStore()
        store.document = document
        return (store, try XCTUnwrap(document.page(at: 0)))
    }
}
