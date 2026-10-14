import AppKit
import CoreText
import PDFKit
import XCTest
@testable import Leaf

final class PageExtractionTests: XCTestCase {
    private var recentURLs: Any?

    override func setUp() {
        super.setUp()
        recentURLs = UserDefaults.standard.object(forKey: "recentPDFs")
    }

    override func tearDown() {
        if let recentURLs {
            UserDefaults.standard.set(recentURLs, forKey: "recentPDFs")
        } else {
            UserDefaults.standard.removeObject(forKey: "recentPDFs")
        }
        super.tearDown()
    }

    func testRangesAcceptWhitespaceAndDashesAndUseDocumentOrder() throws {
        XCTAssertEqual(try PageRange.parse(" 5, 1, 3 – 5, 2—3 \n", totalPages: 6), [0, 1, 2, 3, 4])
        XCTAssertEqual(try PageRange.parse("1", totalPages: 1), [0])
        XCTAssertEqual(try PageRange.parse("2-2, 2", totalPages: 2), [1])
    }

    func testInvalidRangesGiveActionableErrors() {
        for input in ["", " \n", "0", "-1", "6", "3-2", "1-6", "1,,2", "1,", ",1",
                      "1-", "-2", "1-2-3", "1 2", "one", "+1", "1.5", "999999999999999999999999"] {
            XCTAssertThrowsError(try PageRange.parse(input, totalPages: 5), input) { error in
                XCTAssertFalse(error.localizedDescription.isEmpty)
                XCTAssertFalse(error.localizedDescription.contains("couldn’t be completed"))
            }
        }
        XCTAssertThrowsError(try PageRange.parse("1", totalPages: 0))
    }

    func testExtractionPreservesPagesAndAnnotationsWithoutChangingSourceState() async throws {
        try await MainActor.run {
            let directory = try Self.makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = try Self.makePDF(in: directory, pages: ["First page", "Second page", "Third page"])
            let originalBytes = try Data(contentsOf: source)
            let output = directory.appendingPathComponent("Extracted.pdf")
            let store = DocumentStore()
            store.open(url: source)
            let sourceDocument = try XCTUnwrap(store.document)
            store.goToPage(index: 2)
            store.addNote(text: "Keep this annotation")
            store.rotateCurrentPage()
            let recentBefore = store.recentURLs
            let undoName = store.undoManager.undoActionName
            let revision = store.pageRevision

            XCTAssertTrue(store.canExtractPages)
            XCTAssertTrue(store.extractPages([2, 0, 2], to: output), store.errorMessage ?? "")

            let extracted = try XCTUnwrap(PDFDocument(url: output))
            XCTAssertEqual(extracted.pageCount, 2)
            XCTAssertTrue(extracted.page(at: 0)?.string?.contains("First page") == true)
            XCTAssertTrue(extracted.page(at: 1)?.string?.contains("Third page") == true)
            XCTAssertEqual(extracted.page(at: 1)?.rotation, 90)
            XCTAssertEqual(extracted.page(at: 1)?.annotations.first { $0.type == "Text" }?.contents,
                           "Keep this annotation")
            XCTAssertTrue(store.document === sourceDocument)
            XCTAssertEqual(store.fileURL, source)
            XCTAssertEqual(store.currentPageIndex, 2)
            XCTAssertEqual(store.pageCount, 3)
            XCTAssertEqual(store.recentURLs, recentBefore)
            XCTAssertEqual(store.pageRevision, revision)
            XCTAssertEqual(store.undoManager.undoActionName, undoName)
            XCTAssertTrue(store.isModified)
            XCTAssertEqual(try Data(contentsOf: source), originalBytes)

            store.undo()
            XCTAssertEqual(sourceDocument.page(at: 2)?.rotation, 0)
            XCTAssertTrue(store.isModified)
            store.undo()
            XCTAssertTrue(sourceDocument.page(at: 2)?.annotations.isEmpty == true)
            XCTAssertFalse(store.isModified, "Extraction must preserve the source's saved revision.")
            XCTAssertEqual(extracted.page(at: 1)?.rotation, 90)
            XCTAssertEqual(extracted.page(at: 1)?.annotations.filter { $0.type == "Text" }.count, 1)
        }
    }

    func testExtractionCannotOverwriteSourceOrItsAliases() async throws {
        try await MainActor.run {
            let directory = try Self.makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = try Self.makePDF(in: directory, pages: ["Source page", "Another page"])
            let link = directory.appendingPathComponent("Alias.pdf")
            let hardLink = directory.appendingPathComponent("HardLink.pdf")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
            try FileManager.default.linkItem(at: source, to: hardLink)
            let store = DocumentStore()
            store.open(url: source)
            let originalBytes = try Data(contentsOf: source)

            for destination in [source, source.deletingLastPathComponent().appendingPathComponent("./Source.pdf"), link, hardLink] {
                XCTAssertFalse(store.extractPages([0], to: destination))
                XCTAssertTrue(store.errorMessage?.contains("different filename") == true)
            }
            XCTAssertEqual(try Data(contentsOf: source), originalBytes)
            XCTAssertEqual(store.pageCount, 2)
            XCTAssertFalse(store.isModified)
            XCTAssertFalse(store.canUndo)
        }
    }

    func testExtractionIncludesPendingFormEditsAndKeepsThemUndoable() async throws {
        try await MainActor.run {
            let directory = try Self.makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = try Self.makePDF(in: directory, pages: ["Form page"])
            let output = directory.appendingPathComponent("Completed form.pdf")
            let store = DocumentStore()
            store.open(url: source)
            let page = try XCTUnwrap(store.document?.page(at: 0))
            let field = PDFAnnotation(bounds: CGRect(x: 72, y: 640, width: 240, height: 30),
                                      forType: .widget, withProperties: nil)
            field.widgetFieldType = .text
            field.fieldName = "readerName"
            field.widgetStringValue = ""
            page.addAnnotation(field)
            let view = LeafPDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            view.store = store
            store.pdfView = view
            view.document = store.document
            store.captureVisibleWidgets()
            field.widgetStringValue = "A reader"

            XCTAssertFalse(store.isModified)
            XCTAssertTrue(store.extractPages([0], to: output), store.errorMessage ?? "")
            let extracted = try XCTUnwrap(PDFDocument(url: output))
            XCTAssertEqual(extracted.page(at: 0)?.annotations.first { $0.fieldName == "readerName" }?.widgetStringValue,
                           "A reader")
            XCTAssertTrue(store.isModified, "Exporting must not mark pending form edits as saved.")
            store.undo()
            XCTAssertEqual(field.widgetStringValue, "")
            XCTAssertFalse(store.isModified)
        }
    }

    func testInvalidSelectionAndFailedWriteKeepExistingFilesAndSourceState() async throws {
        try await MainActor.run {
            let directory = try Self.makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = try Self.makePDF(in: directory, pages: ["Source page"])
            let output = directory.appendingPathComponent("Existing.pdf")
            let existingBytes = Data("Keep existing contents".utf8)
            try existingBytes.write(to: output)
            let store = DocumentStore()
            store.open(url: source)

            for indices in [[], [-1], [1], [Int.max]] {
                XCTAssertFalse(store.extractPages(indices, to: output))
                XCTAssertEqual(try Data(contentsOf: output), existingBytes)
            }
            let nonexistentDirectory = directory.appendingPathComponent("Missing", isDirectory: true)
            XCTAssertFalse(store.extractPages([0], to: nonexistentDirectory.appendingPathComponent("Pages.pdf")))
            XCTAssertFalse(store.extractPages([0], to: directory))
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
            XCTAssertNotNil(store.errorMessage)
            XCTAssertEqual(store.fileURL, source)
            XCTAssertFalse(store.isModified)
            XCTAssertFalse(store.canUndo)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains { $0.hasPrefix(".leaf-extract-") })
        }
    }

    @MainActor
    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LeafExtraction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    private static func makePDF(in directory: URL, pages: [String]) throws -> URL {
        let bytes = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes as CFMutableData))
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        for text in pages {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 72, y: 720)
            let attributed = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black
            ])
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            context.endPDFPage()
        }
        context.closePDF()
        let url = directory.appendingPathComponent("Source.pdf")
        try (bytes as Data).write(to: url)
        return url
    }
}
