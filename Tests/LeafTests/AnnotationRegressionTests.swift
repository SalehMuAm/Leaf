import AppKit
import PDFKit
import XCTest
@testable import Leaf

final class AnnotationRegressionTests: XCTestCase {
    func testImportedReadOnlyAndLockedAnnotationsCannotBeChanged() async throws {
        try await MainActor.run {
            for flag in [64, 128] {
                let document = try Self.documentWithAnnotations(flags: flag | 4)
                let store = DocumentStore()
                store.document = document
                let page = try XCTUnwrap(document.page(at: 0))
                let text = try XCTUnwrap(page.annotations.first { $0.type == "FreeText" })
                let drawing = try XCTUnwrap(page.annotations.first { $0.type == "Square" })
                let originalBounds = text.bounds
                XCTAssertEqual(((text.value(forAnnotationKey: .flags) as? NSNumber)?.intValue ?? 0) & flag, flag)
                XCTAssertFalse(store.updateTextBox(text, text: "Forbidden change", fontSize: 20))
                XCTAssertFalse(store.moveTextBox(text, to: NSPoint(x: 250, y: 100)))
                XCTAssertFalse(store.removeTextBox(text))
                XCTAssertFalse(store.removeDrawing(drawing))
                XCTAssertEqual(text.contents, "Original text")
                XCTAssertEqual(text.bounds, originalBounds)
                XCTAssertEqual(page.annotations.count, 2)
                XCTAssertFalse(store.isModified)
                XCTAssertFalse(store.canUndo)
            }
        }
    }

    func testLockedContentsBlockTextChangesButPermitMovingAndDeleting() async throws {
        try await MainActor.run {
            let document = try Self.documentWithAnnotations(flags: 512 | 4)
            let store = DocumentStore()
            store.document = document
            let page = try XCTUnwrap(document.page(at: 0))
            let text = try XCTUnwrap(page.annotations.first { $0.type == "FreeText" })
            let originalBounds = text.bounds
            XCTAssertFalse(store.updateTextBox(text, text: "Forbidden change", fontSize: 20))
            XCTAssertFalse(store.isModified)
            XCTAssertTrue(store.moveTextBox(text, to: NSPoint(x: 200, y: 300)))
            XCTAssertNotEqual(text.bounds, originalBounds)
            XCTAssertEqual(text.contents, "Original text")
            store.undo()
            XCTAssertEqual(text.bounds, originalBounds)
            XCTAssertFalse(store.isModified)
            XCTAssertTrue(store.removeTextBox(text))
            XCTAssertFalse(page.annotations.contains { $0 === text })
            store.undo()
            XCTAssertTrue(page.annotations.contains { $0 === text })
            XCTAssertFalse(store.isModified)
        }
    }

    func testSavingUnchangedImportedTextPreservesItsFrameAndCleanState() async throws {
        try await MainActor.run {
            for (text, fontSize) in [("Original text", CGFloat(16)), ("  Padded text\n", CGFloat(96))] {
                let document = try Self.documentWithAnnotations(flags: 4, text: text, fontSize: fontSize)
                let store = DocumentStore()
                store.document = document
                let annotation = try XCTUnwrap(document.page(at: 0)?.annotations.first { $0.type == "FreeText" })
                let originalBounds = annotation.bounds
                let originalColor = annotation.color
                let originalBorder = annotation.border?.lineWidth
                store.editingTextBox = annotation
                XCTAssertTrue(store.updateTextBox(annotation, text: text, fontSize: fontSize))
                XCTAssertEqual(annotation.contents, text)
                XCTAssertEqual(annotation.bounds, originalBounds,
                               "Opening an imported box and saving unchanged must not shrink its background or move its text.")
                XCTAssertEqual(annotation.color, originalColor)
                XCTAssertEqual(annotation.border?.lineWidth, originalBorder)
                XCTAssertNil(store.editingTextBox)
                XCTAssertFalse(store.isModified)
                XCTAssertFalse(store.canUndo)
            }
        }
    }

    func testUndoDeletingAnAnnotationRestoresItsStackingOrder() async throws {
        try await MainActor.run {
            for removeText in [true, false] {
                let document = try Self.documentWithAnnotations(flags: 4)
                let store = DocumentStore()
                store.document = document
                let page = try XCTUnwrap(document.page(at: 0))
                let front = PDFAnnotation(bounds: NSRect(x: 75, y: 80, width: 300, height: 650),
                                          forType: .freeText, withProperties: nil)
                front.contents = "Keep this annotation in front"
                front.font = NSFont.systemFont(ofSize: 16)
                front.color = .systemBlue
                page.addAnnotation(front)
                let originalOrder = page.annotations.map(ObjectIdentifier.init)
                let target = try XCTUnwrap(page.annotations.first { $0.type == (removeText ? "FreeText" : "Square") })
                XCTAssertTrue(removeText ? store.removeTextBox(target) : store.removeDrawing(target))
                store.undo()
                XCTAssertEqual(page.annotations.map(ObjectIdentifier.init), originalOrder,
                               "Undo must restore overlap order, not place the restored annotation on top.")
                XCTAssertFalse(store.isModified)
                store.redo()
                XCTAssertFalse(page.annotations.contains { $0 === target })
                store.undo()
                XCTAssertEqual(page.annotations.map(ObjectIdentifier.init), originalOrder)
            }
        }
    }

    @MainActor
    private static func documentWithAnnotations(flags: Int, text: String = "Original text",
                                               fontSize: CGFloat = 16) throws -> PDFDocument {
        let bytes = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes as CFMutableData))
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: bytes as Data))
        let page = try XCTUnwrap(document.page(at: 0))
        let annotation = PDFAnnotation(bounds: NSRect(x: 60, y: 600, width: 300, height: 100),
                                       forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = NSFont(name: "Helvetica", size: fontSize)
        annotation.fontColor = .black
        annotation.color = .yellow
        let border = PDFBorder()
        border.lineWidth = 3
        annotation.border = border
        annotation.setValue(NSNumber(value: flags), forAnnotationKey: .flags)
        page.addAnnotation(annotation)
        let drawing = try XCTUnwrap(drawingAnnotation(tool: .rectangle,
            points: [NSPoint(x: 50, y: 50), NSPoint(x: 150, y: 150)], on: page,
            color: .systemRed, lineWidth: 2))
        drawing.setValue(NSNumber(value: flags), forAnnotationKey: .flags)
        page.addAnnotation(drawing)
        // Exercise the persisted PDF flags, not a PDFKit property set only in memory.
        return try XCTUnwrap(PDFDocument(data: try XCTUnwrap(document.dataRepresentation())))
    }
}
