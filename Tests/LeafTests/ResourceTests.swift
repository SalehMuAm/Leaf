import Foundation
import PDFKit
import XCTest
@testable import Leaf

final class ResourceTests: XCTestCase {
    func testWelcomeAndArtworkResolveOutsideTheCheckout() throws {
        let files = FileManager.default
        let originalDirectory = files.currentDirectoryPath
        let outsideDirectory = files.temporaryDirectory.appendingPathComponent("LeafResources-\(UUID().uuidString)")
        try files.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        defer {
            files.changeCurrentDirectoryPath(originalDirectory)
            try? files.removeItem(at: outsideDirectory)
        }
        XCTAssertTrue(files.changeCurrentDirectoryPath(outsideDirectory.path))

        let welcome = try XCTUnwrap(LeafResources.welcomeURL)
        let document = try XCTUnwrap(PDFDocument(url: welcome))
        XCTAssertGreaterThan(document.pageCount, 0)
        XCTAssertTrue(document.string?.contains("Leaf") == true)

        let mark = try XCTUnwrap(LeafResources.url(forResource: "LeafMark", withExtension: "png"))
        XCTAssertEqual(Array(try Data(contentsOf: mark).prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])

        let icon = try XCTUnwrap(LeafResources.url(forResource: "Leaf", withExtension: "icns"))
        XCTAssertEqual(String(data: try Data(contentsOf: icon).prefix(4), encoding: .ascii), "icns")
    }
}
