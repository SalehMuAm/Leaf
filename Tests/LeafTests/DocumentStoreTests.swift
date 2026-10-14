import AppKit
import CoreText
import PDFKit
import XCTest
@testable import Leaf

final class DocumentStoreTests: XCTestCase {
    private var savedDefaults: [String: Any] = [:]
    private let preferenceKeys = ["readingLayout", "canvasTheme", "recentPDFs"]

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        savedDefaults = preferenceKeys.reduce(into: [:]) { snapshot, key in
            snapshot[key] = defaults.object(forKey: key)
        }
        defaults.set(ReadingLayout.vertical.rawValue, forKey: "readingLayout")
    }

    override func tearDown() {
        for key in preferenceKeys {
            if let value = savedDefaults[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        savedDefaults = [:]
        super.tearDown()
    }

    func testNavigationClampsToDocumentBounds() async throws {
        try await MainActor.run {
            let fixture = try Self.makePDF(pages: ["First page", "Second page", "Third page"])
            defer { try? FileManager.default.removeItem(at: fixture) }
            let store = DocumentStore()
            store.open(url: fixture)

            XCTAssertEqual(store.pageCount, 3)
            XCTAssertEqual(store.currentPageIndex, 0)
            store.previousPage()
            XCTAssertEqual(store.currentPageIndex, 0)
            store.goToPage(index: 100)
            XCTAssertEqual(store.currentPageIndex, 2)
            store.nextPage()
            XCTAssertEqual(store.currentPageIndex, 2)
            store.previousPage()
            XCTAssertEqual(store.currentPageIndex, 1)
            store.goToPage(index: -10)
            XCTAssertEqual(store.currentPageIndex, 0)
            XCTAssertFalse(store.isModified, "Reading a document must not mark it as edited.")
        }
    }

    func testRotationCanBeUndoneAndRedone() async throws {
        try await MainActor.run {
            let fixture = try Self.makePDF(pages: ["Rotation test"])
            defer { try? FileManager.default.removeItem(at: fixture) }
            let store = DocumentStore()
            store.open(url: fixture)
            let originalRotation = try XCTUnwrap(store.document?.page(at: 0)).rotation

            store.rotateCurrentPage()
            XCTAssertEqual(store.document?.page(at: 0)?.rotation, (originalRotation + 90) % 360)
            XCTAssertTrue(store.isModified)
            XCTAssertTrue(store.canUndo)

            store.undo()
            XCTAssertEqual(store.document?.page(at: 0)?.rotation, originalRotation)
            XCTAssertFalse(store.isModified, "Undoing the only edit must restore the saved state.")
            XCTAssertTrue(store.canRedo)

            store.redo()
            XCTAssertEqual(store.document?.page(at: 0)?.rotation, (originalRotation + 90) % 360)
        }
    }

    func testRotationAffectsOnlyCurrentPage() async throws {
        try await MainActor.run {
            let fixture = try Self.makePDF(pages: ["Unchanged page", "Rotated page"])
            defer { try? FileManager.default.removeItem(at: fixture) }
            let store = DocumentStore()
            store.open(url: fixture)
            store.goToPage(index: 1)
            store.rotateCurrentPage()

            XCTAssertEqual(store.document?.page(at: 0)?.rotation, 0)
            XCTAssertEqual(store.document?.page(at: 1)?.rotation, 90)
            XCTAssertEqual(store.currentPageIndex, 1)
        }
    }

    func testLastPageCannotBeDeleted() async throws {
        try await MainActor.run {
            let fixture = try Self.makePDF(pages: ["Keep this page"])
            defer { try? FileManager.default.removeItem(at: fixture) }
            let store = DocumentStore()
            store.open(url: fixture)

            store.deleteCurrentPage()

            XCTAssertEqual(store.pageCount, 1)
            XCTAssertEqual(store.currentPageIndex, 0)
            XCTAssertFalse(store.isModified)
        }
    }

    func testSavePersistsEditsAndClearsModifiedState() async throws {
        try await MainActor.run {
            let fixture = try Self.makePDF(pages: ["Saved rotation", "Still readable"])
            defer { try? FileManager.default.removeItem(at: fixture) }
            let store = DocumentStore()
            store.open(url: fixture)
            store.rotateCurrentPage()

            XCTAssertTrue(store.save())
            XCTAssertFalse(store.isModified)
            let reopened = try XCTUnwrap(PDFDocument(url: fixture))
            XCTAssertEqual(reopened.pageCount, 2)
            XCTAssertEqual(reopened.page(at: 0)?.rotation, 90)
            XCTAssertEqual(reopened.page(at: 1)?.rotation, 0)
            XCTAssertTrue(reopened.string?.contains("Still readable") == true)

            store.undo()
            XCTAssertTrue(store.isModified, "Undo after saving must mark the older version as unsaved.")
            store.redo()
            XCTAssertFalse(store.isModified, "Redo back to the saved version must clear the modified state.")
        }
    }

    func testNotesPersistAndSupportUndo() async throws {
        try await MainActor.run {
            let fixture = try Self.makePDF(pages: ["A page with a note"])
            defer { try? FileManager.default.removeItem(at: fixture) }
            let store = DocumentStore()
            store.open(url: fixture)
            let page = try XCTUnwrap(store.document?.page(at: 0))

            store.addNote(text: "  Remember this passage.\n")
            XCTAssertEqual(page.annotations.filter { $0.type == "Text" }.count, 1)
            XCTAssertEqual(page.annotations.first { $0.type == "Text" }?.contents, "Remember this passage.")
            store.undo()
            XCTAssertTrue(page.annotations.isEmpty)
            XCTAssertFalse(store.isModified)
            store.redo()
            XCTAssertEqual(page.annotations.filter { $0.type == "Text" }.count, 1)
            XCTAssertTrue(store.save())
            let reopened = try XCTUnwrap(PDFDocument(url: fixture))
            XCTAssertEqual(reopened.page(at: 0)?.annotations.first { $0.type == "Text" }?.contents,
                           "Remember this passage.")
        }
    }

    func testBlankNoteIsIgnored() async throws {
        try await MainActor.run {
            let fixture = try Self.makePDF(pages: ["No empty notes"])
            defer { try? FileManager.default.removeItem(at: fixture) }
            let store = DocumentStore()
            store.open(url: fixture)
            store.addNote(text: " \n\t ")

            XCTAssertTrue(store.document?.page(at: 0)?.annotations.isEmpty == true)
            XCTAssertFalse(store.isModified)
            XCTAssertFalse(store.canUndo)
        }
    }

    func testNativeEditsToExistingNotesSupportUndoAndPersist() async throws {
        try await MainActor.run {
            let fixture = try Self.makePDF(pages: ["A document with an existing note"])
            defer { try? FileManager.default.removeItem(at: fixture) }
            let writer = DocumentStore()
            writer.open(url: fixture)
            writer.addNote(text: "Original note")
            XCTAssertTrue(writer.save())

            let store = DocumentStore()
            store.open(url: fixture)
            store.captureVisibleWidgets()
            let note = try XCTUnwrap(store.document?.page(at: 0)?.annotations.first { $0.type == "Text" })
            note.contents = "Revised in the native note editor"
            store.scanFormChanges()

            XCTAssertTrue(store.isModified)
            store.undo()
            XCTAssertEqual(note.contents, "Original note")
            XCTAssertFalse(store.isModified)
            store.redo()
            XCTAssertEqual(note.contents, "Revised in the native note editor")
            XCTAssertTrue(store.isModified)
            XCTAssertTrue(store.save())
            XCTAssertFalse(store.isModified)
            let reopened = try XCTUnwrap(PDFDocument(url: fixture))
            XCTAssertEqual(reopened.page(at: 0)?.annotations.first { $0.type == "Text" }?.contents,
                           "Revised in the native note editor")
        }
    }

    func testSelectedTextHighlightPersistsAndSupportsUndo() async throws {
        try await MainActor.run {
            let fixture = try Self.makePDF(pages: ["Highlight this passage while reading."])
            defer { try? FileManager.default.removeItem(at: fixture) }
            let store = DocumentStore()
            store.open(url: fixture)
            let document = try XCTUnwrap(store.document)
            let page = try XCTUnwrap(document.page(at: 0))
            let view = LeafPDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            view.store = store
            store.pdfView = view
            view.document = document
            let selection = try XCTUnwrap(document.findString("passage", withOptions: []).first)
            view.setCurrentSelection(selection, animate: false)

            store.highlightSelection()

            XCTAssertEqual(page.annotations.count, 1)
            XCTAssertEqual(page.annotations.first?.type, "Highlight")
            XCTAssertFalse(try XCTUnwrap(page.annotations.first).bounds.isEmpty)
            XCTAssertNil(view.currentSelection)
            store.undo()
            XCTAssertTrue(page.annotations.isEmpty)
            XCTAssertFalse(store.isModified)
            store.redo()
            XCTAssertTrue(store.save())
            let reopened = try XCTUnwrap(PDFDocument(url: fixture))
            XCTAssertEqual(reopened.page(at: 0)?.annotations.first?.type, "Highlight")
            XCTAssertEqual(reopened.page(at: 0)?.annotations.first?.contents, "passage")
        }
    }

    func testFitWidthAndHeightRespectRotationAndResize() async throws {
        try await MainActor.run {
            let fixture = try Self.makePDF(pages: ["A portrait page that can turn sideways."])
            defer { try? FileManager.default.removeItem(at: fixture) }
            let store = DocumentStore()
            store.open(url: fixture)
            let view = LeafPDFView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
            view.store = store
            store.pdfView = view
            view.displayBox = .cropBox
            view.minScaleFactor = 0.1
            view.maxScaleFactor = 8
            view.pageBreakMargins = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
            view.displaysPageBreaks = true
            view.document = store.document
            view.applyReadingLayout(.single)
            view.layoutSubtreeIfNeeded()

            store.setFitMode(.width)
            view.applyFit()
            try Self.assertDocumentFits(view, dimension: .width)

            store.rotateCurrentPage()
            view.applyFit()
            try Self.assertDocumentFits(view, dimension: .width)

            store.setFitMode(.height)
            view.applyFit()
            try Self.assertDocumentFits(view, dimension: .height)

            view.setFrameSize(NSSize(width: 700, height: 500))
            view.layoutSubtreeIfNeeded()
            view.applyFit()
            try Self.assertDocumentFits(view, dimension: .height)
        }
    }

    func testFitWidthIncludesPageMarginsAcrossLayouts() async throws {
        try await MainActor.run {
            let fixture = try Self.makePDF(pages: ["One", "Two", "Three", "Four"])
            defer { try? FileManager.default.removeItem(at: fixture) }
            let store = DocumentStore()
            store.open(url: fixture)
            let view = LeafPDFView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
            view.store = store
            store.pdfView = view
            view.minScaleFactor = 0.1
            view.maxScaleFactor = 8
            view.pageBreakMargins = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
            view.displaysPageBreaks = true
            view.document = store.document
            for layout in [ReadingLayout.vertical, .single, .twoUp] {
                store.setLayout(layout)
                view.layoutSubtreeIfNeeded()
                store.setFitMode(.width)
                view.applyFit()
                try Self.assertDocumentFits(view, dimension: .width)
            }
        }
    }

    func testArrowKeysAdvanceWholeTwoPageSpreads() async throws {
        try await MainActor.run {
            let fixture = try Self.makePDF(pages: ["One", "Two", "Three", "Four", "Five"])
            defer { try? FileManager.default.removeItem(at: fixture) }
            let store = DocumentStore()
            store.open(url: fixture)
            let view = LeafPDFView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
            view.store = store
            store.pdfView = view
            view.document = store.document
            store.setLayout(.twoUp)
            let right = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                     modifierFlags: [], timestamp: 0,
                                                     windowNumber: 0, context: nil,
                                                     characters: "", charactersIgnoringModifiers: "",
                                                     isARepeat: false, keyCode: 124))
            let left = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                    modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil,
                                                    characters: "", charactersIgnoringModifiers: "",
                                                    isARepeat: false, keyCode: 123))

            view.keyDown(with: right)
            XCTAssertEqual(store.currentPageIndex, 2)
            view.keyDown(with: right)
            XCTAssertEqual(store.currentPageIndex, 4)
            view.keyDown(with: right)
            XCTAssertEqual(store.currentPageIndex, 4)
            view.keyDown(with: left)
            XCTAssertEqual(store.currentPageIndex, 2)
            view.keyDown(with: left)
            XCTAssertEqual(store.currentPageIndex, 0)
            view.keyDown(with: left)
            XCTAssertEqual(store.currentPageIndex, 0)
            XCTAssertFalse(store.isModified)
        }
    }

    func testTextFormChangesSupportUndoAndPersist() async throws {
        try await MainActor.run {
            let fixture = try Self.makePDF(pages: ["Form example"])
            defer { try? FileManager.default.removeItem(at: fixture) }
            let store = DocumentStore()
            store.open(url: fixture)
            let page = try XCTUnwrap(store.document?.page(at: 0))
            let field = PDFAnnotation(bounds: CGRect(x: 72, y: 640, width: 240, height: 30),
                                      forType: .widget, withProperties: nil)
            field.widgetFieldType = .text
            field.fieldName = "readerName"
            field.widgetStringValue = ""
            page.addAnnotation(field)
            store.captureVisibleWidgets()

            field.widgetStringValue = "A reader"
            store.scanFormChanges()
            XCTAssertTrue(store.isModified)
            store.undo()
            XCTAssertEqual(field.widgetStringValue, "")
            XCTAssertFalse(store.isModified)
            store.redo()
            XCTAssertEqual(field.widgetStringValue, "A reader")
            XCTAssertTrue(store.save())

            let reopened = try XCTUnwrap(PDFDocument(url: fixture))
            let savedField = reopened.page(at: 0)?.annotations.first { $0.fieldName == "readerName" }
            XCTAssertEqual(savedField?.widgetStringValue, "A reader")
        }
    }

    func testSearchFindsTextAndWrapsAcrossResults() async throws {
        let completed = expectation(description: "PDFKit search completed")
        let (store, fixture, observer) = try await MainActor.run {
            let fixture = try Self.makePDF(pages: [
                "Quiet reading begins here.",
                "A READING room for everyone.",
                "One final page."
            ])
            let store = DocumentStore()
            store.open(url: fixture)
            let observer = NotificationCenter.default.addObserver(forName: .PDFDocumentDidEndFind,
                                                                   object: store.document,
                                                                   queue: .main) { _ in completed.fulfill() }
            store.searchQuery = "reading"
            store.performSearch()
            return (store, fixture, observer)
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            try? FileManager.default.removeItem(at: fixture)
        }
        await fulfillment(of: [completed], timeout: 5)
        await MainActor.run {
            XCTAssertEqual(store.searchResults.map(\.pageIndex), [0, 1])
            XCTAssertFalse(store.isSearching)
            XCTAssertEqual(store.activeSearchIndex, 0)
            store.nextSearchResult()
            XCTAssertEqual(store.currentPageIndex, 1)
            store.nextSearchResult()
            XCTAssertEqual(store.activeSearchIndex, 0)
            store.previousSearchResult()
            XCTAssertEqual(store.activeSearchIndex, 1)
            store.selectSearchResult(100)
            XCTAssertEqual(store.activeSearchIndex, 1)
            XCTAssertFalse(store.isModified)

            store.searchQuery = "  "
            store.performSearch()
            XCTAssertTrue(store.searchResults.isEmpty)
            XCTAssertNil(store.activeSearchIndex)
            XCTAssertFalse(store.isSearching)
        }
    }

    func testWelcomeDocumentHasNoWritableSourceURL() async throws {
        try await MainActor.run {
            let fixture = try Self.makePDF(pages: ["Welcome sample"])
            defer { try? FileManager.default.removeItem(at: fixture) }
            let originalBytes = try Data(contentsOf: fixture)
            let store = DocumentStore()
            store.openWelcomeDocument(url: fixture)

            XCTAssertNotNil(store.document)
            XCTAssertNil(store.fileURL, "A bundled sample must use Save As instead of overwriting its resource.")
            XCTAssertFalse(store.isModified)
            store.rotateCurrentPage()
            XCTAssertTrue(store.isModified)
            XCTAssertEqual(try Data(contentsOf: fixture), originalBytes)
        }
    }

    @MainActor
    private static func assertDocumentFits(_ view: LeafPDFView, dimension: FitMode,
                                           file: StaticString = #filePath, line: UInt = #line) throws {
        view.layoutSubtreeIfNeeded()
        let documentView = try XCTUnwrap(view.documentView, file: file, line: line)
        let viewport = documentView.enclosingScrollView?.contentSize ?? view.bounds.size
        let rendered = view.convert(documentView.bounds, from: documentView)
        let renderedLength = dimension == .width ? rendered.width : rendered.height
        let availableLength = dimension == .width ? viewport.width : viewport.height
        XCTAssertLessThanOrEqual(renderedLength, availableLength + 1,
                                 "The rendered PDF and its margins must not overflow the fitted dimension.",
                                 file: file, line: line)
        XCTAssertGreaterThan(renderedLength, availableLength * 0.97,
                             "Fitting should use the available reading space.", file: file, line: line)
    }

    @MainActor
    private static func makePDF(pages: [String]) throws -> URL {
        let bytes = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes as CFMutableData))
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        for text in pages {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 72, y: 720)
            let attributed = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 18),
                .foregroundColor: NSColor.black
            ])
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            context.endPDFPage()
        }
        context.closePDF()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LeafTest-\(UUID().uuidString).pdf")
        try (bytes as Data).write(to: url)
        return url
    }
}
