import AppKit
import CoreText
import PDFKit
import XCTest
@testable import Leaf

final class StoreRegressionTests: XCTestCase {
    private var savedDefaults: [String: Any] = [:]
    private let keys = ["readingLayout", "canvasTheme", "recentPDFs"]

    override func setUp() {
        super.setUp()
        for key in keys { savedDefaults[key] = UserDefaults.standard.object(forKey: key) }
        UserDefaults.standard.set("vertical", forKey: "readingLayout")
    }

    override func tearDown() {
        for key in keys {
            if let value = savedDefaults[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    func testReopeningCurrentFileAfterSaveUsesSavedRevision() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let fixture = try Self.makePDF()
            defer { try? FileManager.default.removeItem(at: fixture) }
            let store = DocumentStore()
            store.open(url: fixture)
            store.rotateCurrentPage()
            XCTAssertTrue(store.isModified)

            let response = Self.respondToModal(with: .alertFirstButtonReturn)
            defer { response.invalidate() }
            store.open(url: fixture)

            XCTAssertEqual(store.document?.page(at: 0)?.rotation, 90,
                           "Choosing Save while reopening must show the newly saved revision.")
            XCTAssertFalse(store.isModified)
            XCTAssertTrue(store.save())
            XCTAssertEqual(PDFDocument(url: fixture)?.page(at: 0)?.rotation, 90,
                           "A later save must not overwrite the saved changes with a stale document.")
        }
    }

    func testInvalidOpenKeepsUnsavedDocumentAndUndoHistory() async throws {
        try await MainActor.run {
            let fixture = try Self.makePDF()
            defer { try? FileManager.default.removeItem(at: fixture) }
            let store = DocumentStore()
            store.open(url: fixture)
            store.rotateCurrentPage()
            let document = store.document
            let revision = store.pageRevision

            store.open(url: fixture.deletingPathExtension().appendingPathExtension("missing"))

            XCTAssertTrue(store.document === document)
            XCTAssertEqual(store.fileURL, fixture)
            XCTAssertEqual(store.pageRevision, revision)
            XCTAssertTrue(store.isModified)
            XCTAssertTrue(store.canUndo)
            XCTAssertNotNil(store.errorMessage)
            store.undo()
            XCTAssertFalse(store.isModified)
            XCTAssertEqual(store.document?.page(at: 0)?.rotation, 0)
        }
    }

    func testFailedSaveKeepsOriginalBytesAndUndoHistory() async throws {
        try await MainActor.run {
            let fixture = try Self.makePDF()
            defer { try? FileManager.default.removeItem(at: fixture) }
            let original = try Data(contentsOf: fixture)
            let store = DocumentStore()
            store.open(url: fixture)
            store.rotateCurrentPage()
            store.fileURL = fixture.appendingPathComponent("Missing/Document.pdf")

            XCTAssertFalse(store.save())
            XCTAssertEqual(try Data(contentsOf: fixture), original)
            XCTAssertTrue(store.isModified)
            XCTAssertTrue(store.canUndo)
            store.undo()
            XCTAssertFalse(store.isModified)
            XCTAssertEqual(store.document?.page(at: 0)?.rotation, 0)
        }
    }

    func testUnlockedProtectedPDFCanSaveEdits() async throws {
        try await MainActor.run {
            let fixture = try Self.makePDF()
            defer { try? FileManager.default.removeItem(at: fixture) }
            let document = try XCTUnwrap(PDFDocument(url: fixture))
            let protectedURL = fixture.deletingPathExtension().appendingPathExtension("protected.pdf")
            defer { try? FileManager.default.removeItem(at: protectedURL) }
            XCTAssertTrue(document.write(to: protectedURL, withOptions: [
                .ownerPasswordOption: "owner-password", .userPasswordOption: "reader-password"
            ]))
            let protected = try XCTUnwrap(PDFDocument(url: protectedURL))
            XCTAssertTrue(protected.isLocked)
            XCTAssertTrue(protected.unlock(withPassword: "owner-password"))
            let store = DocumentStore()
            store.document = protected
            store.fileURL = protectedURL
            store.rotateCurrentPage()

            XCTAssertTrue(store.save(), store.errorMessage ?? "")
            let reopened = try XCTUnwrap(PDFDocument(url: protectedURL))
            XCTAssertTrue(reopened.isEncrypted)
            XCTAssertTrue(reopened.isLocked, "Saving must preserve password protection.")
            XCTAssertTrue(reopened.unlock(withPassword: "owner-password"))
            XCTAssertEqual(reopened.page(at: 0)?.rotation, 90)
        }
    }

    func testInsertionRejectsRestrictedSourceAndPreservesDestination() async throws {
        try await MainActor.run {
            let fixture = try Self.makePDF()
            defer { try? FileManager.default.removeItem(at: fixture) }
            let source = try XCTUnwrap(NoCopyPDFDocument(data: Data(contentsOf: fixture)))
            let store = DocumentStore()
            store.open(url: fixture)

            XCTAssertFalse(store.insertPages(from: source))
            XCTAssertEqual(store.pageCount, 1)
            XCTAssertFalse(store.isModified)
            XCTAssertFalse(store.canUndo)
            XCTAssertTrue(store.errorMessage?.contains("disabled copying") == true)
        }
    }

    func testInsertedPagesRemainIndependentAndUndoRestoresSavedState() async throws {
        try await MainActor.run {
            let fixture = try Self.makePDF()
            defer { try? FileManager.default.removeItem(at: fixture) }
            let incoming = try XCTUnwrap(PDFDocument(url: fixture))
            incoming.page(at: 0)?.rotation = 90
            let note = PDFAnnotation(bounds: NSRect(x: 40, y: 100, width: 24, height: 24),
                                     forType: .text, withProperties: nil)
            note.contents = "Inserted note"
            incoming.page(at: 0)?.addAnnotation(note)
            let store = DocumentStore()
            store.open(url: fixture)

            XCTAssertTrue(store.insertPages(from: incoming))
            XCTAssertEqual(store.pageCount, 2)
            XCTAssertEqual(store.currentPageIndex, 1)
            XCTAssertEqual(store.document?.page(at: 1)?.rotation, 90)
            XCTAssertEqual(store.document?.page(at: 1)?.annotations.first?.contents, "Inserted note")
            XCTAssertTrue(store.isModified)
            store.undo()
            XCTAssertEqual(store.pageCount, 1)
            XCTAssertFalse(store.isModified)
            XCTAssertEqual(incoming.pageCount, 1)
            XCTAssertEqual(note.contents, "Inserted note")
            store.redo()
            XCTAssertEqual(store.pageCount, 2)
            XCTAssertTrue(store.save())
            XCTAssertEqual(PDFDocument(url: fixture)?.page(at: 1)?.annotations.first?.contents, "Inserted note")
        }
    }

    @MainActor
    private static func respondToModal(with response: NSApplication.ModalResponse) -> Timer {
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                if NSApp.modalWindow != nil { NSApp.stopModal(withCode: response) }
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        return timer
    }

    @MainActor
    private static func makePDF() throws -> URL {
        let bytes = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes as CFMutableData))
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 72, y: 720)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "A saved reading page", attributes: [
            .font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black
        ])), context)
        context.endPDFPage()
        context.closePDF()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LeafRegression-\(UUID().uuidString).pdf")
        try (bytes as Data).write(to: url)
        return url
    }
}

private final class NoCopyPDFDocument: PDFDocument {
    override var allowsCopying: Bool { false }
}
