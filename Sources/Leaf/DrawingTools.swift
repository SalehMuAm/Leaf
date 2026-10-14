import AppKit
import PDFKit

enum DrawingTool: String, CaseIterable, Identifiable {
    case pen, rectangle, ellipse, line, arrow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pen: return "Pen"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .arrow: return "Arrow"
        }
    }

    var systemImage: String {
        switch self {
        case .pen: return "pencil.tip"
        case .rectangle: return "rectangle"
        case .ellipse: return "oval"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        }
    }
}

/// Creates an unattached annotation, so the same geometry can be used for a
/// live preview without modifying the document or adding undo entries.
@MainActor
func drawingAnnotation(tool: DrawingTool, points: [NSPoint], on page: PDFPage,
                       color: NSColor, lineWidth: CGFloat) -> PDFAnnotation? {
    guard points.count >= 2, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
          lineWidth.isFinite, (0.5...24).contains(lineWidth) else { return nil }
    let crop = page.bounds(for: .cropBox)
    guard !crop.isEmpty, crop.minX.isFinite, crop.minY.isFinite,
          crop.maxX.isFinite, crop.maxY.isFinite else { return nil }

    // Ink and line strokes extend either side of their path. Arrowheads need
    // additional room, including when the user drags right to a page edge.
    let padding: CGFloat
    switch tool {
    case .arrow: padding = max(6, lineWidth * 4) + 1
    case .pen, .line: padding = lineWidth / 2 + 1
    case .rectangle, .ellipse: padding = lineWidth / 2
    }
    guard crop.width > padding * 2 + 2, crop.height > padding * 2 + 2 else { return nil }
    let drawingArea = crop.insetBy(dx: padding, dy: padding)
    let paths: [[NSPoint]]
    switch tool {
    case .pen:
        paths = clippedDrawingPaths(points, within: drawingArea)
    case .line, .arrow:
        guard let segment = clippedDrawingSegment(from: points[0], to: points[points.count - 1],
                                                   within: drawingArea) else { return nil }
        paths = [[segment.0, segment.1]]
    case .rectangle, .ellipse:
        paths = [[points[0], points[points.count - 1]].map { point in
            NSPoint(x: min(max(point.x, drawingArea.minX), drawingArea.maxX),
                    y: min(max(point.y, drawingArea.minY), drawingArea.maxY))
        }]
    }
    let usedPoints = paths.flatMap { $0 }
    guard let firstPoint = usedPoints.first else { return nil }
    var minX = firstPoint.x, maxX = firstPoint.x
    var minY = firstPoint.y, maxY = firstPoint.y
    for point in usedPoints.dropFirst() {
        minX = min(minX, point.x); maxX = max(maxX, point.x)
        minY = min(minY, point.y); maxY = max(maxY, point.y)
    }
    let pathBounds = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    if tool == .rectangle || tool == .ellipse {
        guard pathBounds.width >= 2, pathBounds.height >= 2 else { return nil }
    } else {
        guard hypot(pathBounds.width, pathBounds.height) >= 2 else { return nil }
    }

    let bounds: NSRect
    let type: PDFAnnotationSubtype
    switch tool {
    case .pen:
        bounds = pathBounds.insetBy(dx: -padding, dy: -padding)
        type = .ink
    case .rectangle:
        bounds = pathBounds
        type = .square
    case .ellipse:
        bounds = pathBounds
        type = .circle
    case .line, .arrow:
        bounds = pathBounds.insetBy(dx: -padding, dy: -padding)
        type = .line
    }
    let annotation = PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
    annotation.color = color.usingColorSpace(.sRGB) ?? color
    let border = PDFBorder()
    border.lineWidth = lineWidth
    border.style = .solid
    annotation.border = border
    annotation.shouldPrint = true
    annotation.modificationDate = Date()

    func relative(_ point: NSPoint) -> NSPoint {
        NSPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
    }
    switch tool {
    case .pen:
        for stroke in paths {
            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: relative(stroke[0]))
            for point in stroke.dropFirst() { path.line(to: relative(point)) }
            annotation.add(path)
        }
    case .rectangle, .ellipse:
        annotation.interiorColor = nil
    case .line, .arrow:
        annotation.startPoint = relative(usedPoints[0])
        annotation.endPoint = relative(usedPoints[usedPoints.count - 1])
        annotation.startLineStyle = .none
        annotation.endLineStyle = tool == .arrow ? .closedArrow : .none
        if tool == .arrow { annotation.interiorColor = annotation.color }
    }
    return annotation
}

/// Clip each segment instead of pinning individual samples to a page edge.
/// Leaving and re-entering the page creates separate visible strokes; joining
/// those boundary points would invent a line the user never drew.
private func clippedDrawingPaths(_ points: [NSPoint], within bounds: NSRect) -> [[NSPoint]] {
    var paths: [[NSPoint]] = []
    for (start, end) in zip(points, points.dropFirst()) {
        guard let segment = clippedDrawingSegment(from: start, to: end, within: bounds),
              hypot(segment.1.x - segment.0.x, segment.1.y - segment.0.y) > 0.0001 else { continue }
        if let last = paths.last?.last,
           hypot(last.x - segment.0.x, last.y - segment.0.y) < 0.0001 {
            paths[paths.count - 1].append(segment.1)
        } else {
            paths.append([segment.0, segment.1])
        }
    }
    return paths
}

/// Liang–Barsky clipping preserves a line's direction when its endpoint is
/// outside the page. Naive x/y clamping would change the slope of that line.
private func clippedDrawingSegment(from start: NSPoint, to end: NSPoint,
                                   within bounds: NSRect) -> (NSPoint, NSPoint)? {
    let dx = end.x - start.x, dy = end.y - start.y
    guard dx.isFinite, dy.isFinite else { return nil }
    var lower: CGFloat = 0, upper: CGFloat = 1
    let edges = [(-dx, start.x - bounds.minX), (dx, bounds.maxX - start.x),
                 (-dy, start.y - bounds.minY), (dy, bounds.maxY - start.y)]
    for (direction, distance) in edges {
        if direction == 0 {
            if distance < 0 { return nil }
        } else {
            let fraction = distance / direction
            if direction < 0 { lower = max(lower, fraction) }
            else { upper = min(upper, fraction) }
            if lower > upper { return nil }
        }
    }
    func point(at fraction: CGFloat) -> NSPoint {
        NSPoint(x: min(bounds.maxX, max(bounds.minX, start.x + fraction * dx)),
                y: min(bounds.maxY, max(bounds.minY, start.y + fraction * dy)))
    }
    return (point(at: lower), point(at: upper))
}

func isDrawingAnnotation(_ annotation: PDFAnnotation) -> Bool {
    ["Ink", "Square", "Circle", "Line"].contains(annotation.type ?? "")
}
