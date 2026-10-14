import PDFKit
import XCTest
@testable import Leaf

final class OutlineNavigationTests: XCTestCase {
    func testDeletedBookmarkTargetDoesNotExposeAnInvalidPageNumberAndReturnsAfterUndo() {
        let document = PDFDocument()
        let first = PDFPage()
        let second = PDFPage()
        document.insert(first, at: 0)
        document.insert(second, at: 1)
        let root = PDFOutline()
        let chapter = PDFOutline()
        chapter.label = "Chapter one"
        chapter.destination = PDFDestination(page: first, at: NSPoint(x: 30, y: 400))
        root.insertChild(chapter, at: 0)
        document.outlineRoot = root

        XCTAssertEqual(OutlineLocation(chapter, in: document)?.pageIndex, 0)
        document.removePage(at: 0)
        XCTAssertNotNil(chapter.destination?.page, "PDFKit retains the deleted page in the bookmark.")
        XCTAssertEqual(document.index(for: first), NSNotFound)
        XCTAssertNil(OutlineLocation(chapter, in: document))

        document.insert(first, at: 0)
        let restored = OutlineLocation(chapter, in: document)
        XCTAssertEqual(restored?.pageIndex, 0)
        XCTAssertEqual(restored?.destination.point, NSPoint(x: 30, y: 400))
    }

    func testActionDestinationUsesCurrentIndexAfterPageInsertion() {
        let document = PDFDocument()
        let page = PDFPage()
        document.insert(page, at: 0)
        let item = PDFOutline()
        item.action = PDFActionGoTo(destination: PDFDestination(page: page, at: NSPoint(x: 10, y: 200)))
        XCTAssertEqual(OutlineLocation(item, in: document)?.pageIndex, 0)
        document.insert(PDFPage(), at: 0)
        XCTAssertEqual(OutlineLocation(item, in: document)?.pageIndex, 1)
    }

    func testMissingAndForeignDestinationsAreNotNavigable() {
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        XCTAssertNil(OutlineLocation(PDFOutline(), in: document))
        let foreignPage = PDFPage()
        let item = PDFOutline()
        item.destination = PDFDestination(page: foreignPage, at: .zero)
        XCTAssertNil(OutlineLocation(item, in: document))
        XCTAssertNil(OutlineLocation(item, in: nil))
    }
}
