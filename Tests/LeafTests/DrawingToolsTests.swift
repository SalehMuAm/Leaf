import AppKit
import PDFKit
import XCTest
@testable import Leaf

final class DrawingToolsTests: XCTestCase {
    func testModesAreExclusiveAndDoNotModifyTheDocument() async throws {
        try await MainActor.run {
            let (store, page) = try Self.makeDocument()
            XCTAssertTrue(store.beginTextPlacement(text: "Place this", fontSize: 16))
            XCTAssertTrue(store.beginDrawing(tool: .pen))
            XCTAssertNil(store.pendingTextBox)
            XCTAssertEqual(store.activeDrawingTool, .pen)
            XCTAssertTrue(store.beginDrawing(tool: .rectangle))
            XCTAssertEqual(store.activeDrawingTool, .rectangle)
            XCTAssertTrue(store.beginTextPlacement(text: "Back to text", fontSize: 16))
            XCTAssertNil(store.activeDrawingTool)
            XCTAssertTrue(store.beginDrawing(tool: .arrow))
            store.endDrawing()
            XCTAssertNil(store.activeDrawingTool)
            XCTAssertTrue(page.annotations.isEmpty)
            XCTAssertFalse(store.isModified)
            XCTAssertFalse(store.canUndo)

            let url = FileManager.default.temporaryDirectory.appendingPathComponent("LeafDrawing-\(UUID()).pdf")
            defer { try? FileManager.default.removeItem(at: url) }
            try XCTUnwrap(store.document?.dataRepresentation()).write(to: url)
            XCTAssertTrue(store.beginDrawing(tool: .ellipse))
            store.openWelcomeDocument(url: url)
            XCTAssertNil(store.activeDrawingTool)
        }
    }

    func testEveryToolCreatesAnUndoableNativeAnnotation() async throws {
        try await MainActor.run {
            let expectedTypes: [DrawingTool: String] = [
                .pen: "Ink", .rectangle: "Square", .ellipse: "Circle", .line: "Line", .arrow: "Line"
            ]
            for tool in DrawingTool.allCases {
                let (store, page) = try Self.makeDocument()
                store.drawingColor = NSColor(srgbRed: 0.8, green: 0.1, blue: 0.2, alpha: 1)
                store.drawingLineWidth = 4
                XCTAssertTrue(store.beginDrawing(tool: tool))
                XCTAssertTrue(store.addDrawing(tool: tool, points: Self.points, on: page))
                let annotation = try XCTUnwrap(page.annotations.first)
                XCTAssertEqual(annotation.type, expectedTypes[tool])
                XCTAssertEqual(annotation.border?.lineWidth, 4)
                XCTAssertTrue(annotation.shouldPrint)
                XCTAssertTrue(page.bounds(for: .cropBox).contains(annotation.bounds))
                XCTAssertEqual(store.activeDrawingTool, tool, "Drawing should stay active for another stroke.")
                XCTAssertTrue(store.isModified)
                store.undo()
                XCTAssertTrue(page.annotations.isEmpty)
                XCTAssertFalse(store.isModified)
                store.redo()
                XCTAssertTrue(page.annotations.first === annotation)
                XCTAssertTrue(store.isModified)
            }
        }
    }

    func testPreviewAndRelativePathGeometryDoNotMutateThePage() async throws {
        try await MainActor.run {
            let (store, page) = try Self.makeDocument()
            let ink = try XCTUnwrap(drawingAnnotation(tool: .pen, points: Self.points, on: page,
                                                      color: .systemBlue, lineWidth: 2))
            let path = try XCTUnwrap(ink.paths?.first)
            XCTAssertEqual(path.elementCount, Self.points.count)
            XCTAssertEqual(path.bounds.minX + ink.bounds.minX, 100, accuracy: 0.001)
            XCTAssertEqual(path.bounds.minY + ink.bounds.minY, 100, accuracy: 0.001)
            XCTAssertEqual(path.bounds.maxX + ink.bounds.minX, 250, accuracy: 0.001)
            XCTAssertEqual(path.bounds.maxY + ink.bounds.minY, 200, accuracy: 0.001)
            for tool in [DrawingTool.line, .arrow] {
                let annotation = try XCTUnwrap(drawingAnnotation(tool: tool, points: Self.points, on: page,
                                                                 color: .systemBlue, lineWidth: 2))
                XCTAssertEqual(annotation.startPoint.x + annotation.bounds.minX, 100, accuracy: 0.001)
                XCTAssertEqual(annotation.startPoint.y + annotation.bounds.minY, 100, accuracy: 0.001)
                XCTAssertEqual(annotation.endPoint.x + annotation.bounds.minX, 250, accuracy: 0.001)
                XCTAssertEqual(annotation.endPoint.y + annotation.bounds.minY, 200, accuracy: 0.001)
                XCTAssertEqual(annotation.endLineStyle, tool == .arrow ? .closedArrow : .none)
            }
            XCTAssertTrue(page.annotations.isEmpty)
            XCTAssertFalse(store.isModified)
            XCTAssertFalse(store.canUndo)
        }
    }

    func testDrawingsSurviveSavingAndDeletionCanBeUndone() async throws {
        try await MainActor.run {
            let previousRecents = UserDefaults.standard.object(forKey: "recentPDFs")
            defer { UserDefaults.standard.set(previousRecents, forKey: "recentPDFs") }
            let (store, page) = try Self.makeDocument()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("LeafDrawing-\(UUID()).pdf")
            defer { try? FileManager.default.removeItem(at: url) }
            store.fileURL = url
            page.rotation = 90
            store.drawingLineWidth = 3
            store.drawingColor = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1)
            for tool in DrawingTool.allCases {
                XCTAssertTrue(store.addDrawing(tool: tool, points: Self.points, on: page))
            }
            XCTAssertTrue(store.save())
            XCTAssertFalse(store.isModified)
            let reopened = try XCTUnwrap(PDFDocument(url: url))
            let reopenedPage = try XCTUnwrap(reopened.page(at: 0))
            XCTAssertEqual(reopenedPage.rotation, 90)
            XCTAssertEqual(reopenedPage.annotations.count, DrawingTool.allCases.count)
            for (original, saved) in zip(page.annotations, reopenedPage.annotations) {
                XCTAssertEqual(saved.type, original.type)
                XCTAssertEqual(saved.bounds, original.bounds)
                XCTAssertEqual(saved.border?.lineWidth, 3)
                let savedColor = try XCTUnwrap(saved.color.usingColorSpace(.sRGB))
                XCTAssertEqual(savedColor.redComponent, 0.2, accuracy: 0.001)
                XCTAssertEqual(savedColor.greenComponent, 0.4, accuracy: 0.001)
                XCTAssertEqual(savedColor.blueComponent, 0.8, accuracy: 0.001)
                if original.type == "Ink" {
                    XCTAssertEqual(saved.paths?.first?.elementCount, Self.points.count)
                } else if original.type == "Line" {
                    XCTAssertEqual(saved.startPoint, original.startPoint)
                    XCTAssertEqual(saved.endPoint, original.endPoint)
                    XCTAssertEqual(saved.endLineStyle, original.endLineStyle)
                }
            }
            let annotation = try XCTUnwrap(page.annotations.first)
            XCTAssertTrue(store.removeDrawing(annotation))
            XCTAssertEqual(page.annotations.count, 4)
            XCTAssertTrue(store.isModified)
            store.undo()
            XCTAssertTrue(page.annotations.contains { $0 === annotation })
            XCTAssertFalse(store.isModified)
            store.redo()
            XCTAssertFalse(page.annotations.contains { $0 === annotation })
        }
    }

    func testDegenerateInvalidAndForeignGesturesDoNotCreateEdits() async throws {
        try await MainActor.run {
            let (store, page) = try Self.makeDocument()
            let (_, foreignPage) = try Self.makeDocument()
            for tool in DrawingTool.allCases {
                for points in [[], [NSPoint(x: 100, y: 100)], [NSPoint(x: 100, y: 100), NSPoint(x: 100, y: 100)],
                               [NSPoint(x: 100, y: 100), NSPoint(x: CGFloat.nan, y: 100)]] {
                    XCTAssertFalse(store.addDrawing(tool: tool, points: points, on: page))
                }
                XCTAssertFalse(store.addDrawing(tool: tool, points: Self.points, on: foreignPage))
            }
            for width in [CGFloat.nan, .infinity, 0, -2, 100] {
                store.drawingLineWidth = width
                XCTAssertFalse(store.addDrawing(tool: .pen, points: Self.points, on: page))
            }
            store.drawingLineWidth = 2
            let flat = [NSPoint(x: 100, y: 100), NSPoint(x: 250, y: 100)]
            XCTAssertFalse(store.addDrawing(tool: .rectangle, points: flat, on: page))
            XCTAssertFalse(store.addDrawing(tool: .ellipse, points: flat, on: page))
            XCTAssertTrue(page.annotations.isEmpty)
            XCTAssertFalse(store.isModified)
            XCTAssertFalse(store.canUndo)

            // A closed pen stroke has matching endpoints but still draws a shape.
            XCTAssertTrue(store.addDrawing(tool: .pen, points: Self.points + [Self.points[0]], on: page))
            XCTAssertEqual(page.annotations.count, 1)
        }
    }

    func testCropClampingWorksOnEveryRotationAndForTinyPages() async throws {
        try await MainActor.run {
            let (store, page) = try Self.makeDocument()
            let crop = NSRect(x: 40, y: 50, width: 300, height: 400)
            page.setBounds(crop, for: .cropBox)
            for rotation in [0, 90, 180, 270] {
                page.rotation = rotation
                for tool in DrawingTool.allCases {
                    let annotation = try XCTUnwrap(drawingAnnotation(tool: tool,
                        points: [NSPoint(x: -300, y: -400), NSPoint(x: 800, y: 900)],
                        on: page, color: .black, lineWidth: 4))
                    XCTAssertTrue(crop.contains(annotation.bounds), "\(tool) at \(rotation) must remain inside the crop box.")
                }
            }
            page.setBounds(NSRect(x: 0, y: 0, width: 3, height: 3), for: .cropBox)
            for tool in DrawingTool.allCases {
                XCTAssertFalse(store.addDrawing(tool: tool, points: Self.points, on: page))
            }
            XCTAssertFalse(store.isModified)
        }
    }

    func testPermissionsAndAnnotationTypeAreRespectedWhenDeleting() async throws {
        try await MainActor.run {
            let (store, page) = try Self.makeDocument()
            let note = PDFAnnotation(bounds: NSRect(x: 10, y: 10, width: 24, height: 24), forType: .text, withProperties: nil)
            page.addAnnotation(note)
            XCTAssertFalse(store.removeDrawing(note))
            let drawing = try XCTUnwrap(drawingAnnotation(tool: .rectangle, points: Self.points,
                                                         on: page, color: .black, lineWidth: 2))
            page.addAnnotation(drawing)
            drawing.isReadOnly = true
            XCTAssertFalse(store.removeDrawing(drawing))
            drawing.isReadOnly = false

            let restricted = NonCommentableDocument()
            let restrictedPage = try XCTUnwrap(page.copy() as? PDFPage)
            restricted.insert(restrictedPage, at: 0)
            store.document = restricted
            XCTAssertFalse(store.beginDrawing(tool: .pen))
            XCTAssertFalse(store.addDrawing(tool: .arrow, points: Self.points, on: restrictedPage))
            XCTAssertFalse(store.removeDrawing(try XCTUnwrap(restrictedPage.annotations.last)))
            XCTAssertNotNil(store.errorMessage)
            XCTAssertFalse(store.canUndo)
            XCTAssertFalse(store.isModified)
        }
    }

    func testOffPageLinesPreserveTheirDirectionInsteadOfBendingToTheEdge() async throws {
        try await MainActor.run {
            let (_, page) = try Self.makeDocument()
            for tool in [DrawingTool.line, .arrow] {
                let annotation = try XCTUnwrap(drawingAnnotation(tool: tool,
                    points: [NSPoint(x: 100, y: 100), NSPoint(x: 900, y: 500)],
                    on: page, color: .black, lineWidth: 2))
                let start = annotation.startPoint
                let end = annotation.endPoint
                XCTAssertEqual((end.y - start.y) / (end.x - start.x), 0.5, accuracy: 0.0001,
                               "Clipping must preserve the angle the user drew.")
                XCTAssertTrue(page.bounds(for: .cropBox).contains(annotation.bounds))
            }
        }
    }

    func testPenLeavingAndReenteringPageDoesNotInventAnEdgeStroke() async throws {
        try await MainActor.run {
            let (store, page) = try Self.makeDocument()
            let points = [NSPoint(x: 100, y: 100), NSPoint(x: 700, y: 200),
                          NSPoint(x: 700, y: 500), NSPoint(x: 100, y: 600)]
            XCTAssertTrue(store.addDrawing(tool: .pen, points: points, on: page))
            let annotation = try XCTUnwrap(page.annotations.first)
            XCTAssertEqual(annotation.paths?.count, 2,
                           "The off-page portion must separate the two visible strokes.")
            let paths = try XCTUnwrap(annotation.paths)
            XCTAssertEqual(paths[0].elementCount, 2)
            XCTAssertEqual(paths[1].elementCount, 2)
            XCTAssertEqual(paths[0].bounds.maxY + annotation.bounds.minY, 185, accuracy: 0.001)
            XCTAssertEqual(paths[1].bounds.minY + annotation.bounds.minY, 515, accuracy: 0.001)
            let reopened = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(store.document?.dataRepresentation())))
            XCTAssertEqual(reopened.page(at: 0)?.annotations.first?.paths?.count, 2,
                           "Saving must retain the gap instead of joining the clipped strokes.")
            store.undo()
            XCTAssertTrue(page.annotations.isEmpty)
            XCTAssertFalse(store.isModified)
        }
    }

    func testEntirelyOffPagePathsDoNotLeaveMarksAlongThePageBoundary() async throws {
        try await MainActor.run {
            let (store, page) = try Self.makeDocument()
            for tool in [DrawingTool.pen, .line, .arrow] {
                XCTAssertFalse(store.addDrawing(tool: tool,
                    points: [NSPoint(x: 900, y: 100), NSPoint(x: 900, y: 600)], on: page))
                XCTAssertFalse(store.addDrawing(tool: tool,
                    points: [NSPoint(x: -CGFloat.greatestFiniteMagnitude, y: 100),
                             NSPoint(x: CGFloat.greatestFiniteMagnitude, y: 600)], on: page))
            }
            XCTAssertTrue(page.annotations.isEmpty)
            XCTAssertFalse(store.isModified)
            XCTAssertFalse(store.canUndo)
        }
    }

    func testDrawingOnLargeOffsetPageKeepsPageCoordinatesAfterSaving() async throws {
        try await MainActor.run {
            let (store, page) = try Self.makeDocument()
            page.setBounds(NSRect(x: 0, y: 0, width: 14_400, height: 14_400), for: .mediaBox)
            let crop = NSRect(x: 500, y: 750, width: 13_000, height: 12_500)
            page.setBounds(crop, for: .cropBox)
            page.rotation = 270
            XCTAssertTrue(store.addDrawing(tool: .pen,
                points: [NSPoint(x: 1_000, y: 1_000), NSPoint(x: 10_000, y: 8_000),
                         NSPoint(x: 14_000, y: 15_000)], on: page))
            let original = try XCTUnwrap(page.annotations.first)
            XCTAssertTrue(crop.contains(original.bounds))
            let reopened = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(store.document?.dataRepresentation())))
            let saved = try XCTUnwrap(reopened.page(at: 0)?.annotations.first)
            XCTAssertEqual(reopened.page(at: 0)?.rotation, 270)
            let originalPath = try XCTUnwrap(original.paths?.first?.bounds)
            let savedPath = try XCTUnwrap(saved.paths?.first?.bounds)
            for (actual, expected) in [(saved.bounds.minX, original.bounds.minX),
                                       (saved.bounds.minY, original.bounds.minY),
                                       (saved.bounds.maxX, original.bounds.maxX),
                                       (saved.bounds.maxY, original.bounds.maxY),
                                       (savedPath.minX, originalPath.minX),
                                       (savedPath.minY, originalPath.minY),
                                       (savedPath.maxX, originalPath.maxX),
                                       (savedPath.maxY, originalPath.maxY)] {
                XCTAssertEqual(actual, expected, accuracy: 0.01)
            }
        }
    }

    private static let points = [NSPoint(x: 100, y: 100), NSPoint(x: 180, y: 160), NSPoint(x: 250, y: 200)]

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

private final class NonCommentableDocument: PDFDocument {
    override var allowsCommenting: Bool { false }
}
