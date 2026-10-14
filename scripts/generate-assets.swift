#!/usr/bin/env swift
// Regenerate Leaf's icon and welcome document using only macOS frameworks.
import AppKit
import CoreGraphics
import PDFKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources", isDirectory: true)
let scratch = root.appendingPathComponent(".build/leaf-assets", isDirectory: true)
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(calibratedRed: CGFloat((hex >> 16) & 255) / 255,
                  green: CGFloat((hex >> 8) & 255) / 255,
                  blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

let ink = NSColor(hex: 0x293C34)
let sage = NSColor(hex: 0x5C7B67)
let muted = NSColor(hex: 0x778078)
let paper = NSColor(hex: 0xFCFBF7)
let pale = NSColor(hex: 0xEDF1E9)

func leafMark(in rect: NSRect, light: Bool) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current!.cgContext.translateBy(x: rect.minX, y: rect.minY)
    NSGraphicsContext.current!.cgContext.scaleBy(x: rect.width / 512, y: rect.height / 512)
    let left = NSBezierPath()
    left.move(to: NSPoint(x: 253, y: 96))
    left.curve(to: NSPoint(x: 87, y: 159), controlPoint1: NSPoint(x: 203, y: 145), controlPoint2: NSPoint(x: 130, y: 153))
    left.curve(to: NSPoint(x: 80, y: 169), controlPoint1: NSPoint(x: 82, y: 160), controlPoint2: NSPoint(x: 80, y: 164))
    left.line(to: NSPoint(x: 80, y: 380))
    left.curve(to: NSPoint(x: 253, y: 317), controlPoint1: NSPoint(x: 151, y: 375), controlPoint2: NSPoint(x: 211, y: 358))
    left.close()
    (light ? NSColor(hex: 0xF8F5E8) : sage).setFill()
    left.fill()

    let right = NSBezierPath()
    right.move(to: NSPoint(x: 275, y: 100))
    right.curve(to: NSPoint(x: 430, y: 370), controlPoint1: NSPoint(x: 411, y: 131), controlPoint2: NSPoint(x: 458, y: 255))
    right.curve(to: NSPoint(x: 275, y: 316), controlPoint1: NSPoint(x: 363, y: 370), controlPoint2: NSPoint(x: 313, y: 349))
    right.close()
    (light ? NSColor(hex: 0xE0E8D7) : NSColor(hex: 0x9CAC91)).setFill()
    right.fill()

    let vein = NSBezierPath()
    vein.move(to: NSPoint(x: 286, y: 122))
    vein.curve(to: NSPoint(x: 403, y: 342), controlPoint1: NSPoint(x: 323, y: 207), controlPoint2: NSPoint(x: 379, y: 246))
    vein.lineWidth = 4.5
    vein.lineCapStyle = .round
    (light ? NSColor(hex: 0x6F896E).withAlphaComponent(0.6) : paper).setStroke()
    vein.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

func icon(size: Int, appIcon: Bool) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
    let scale = CGFloat(size) / 1024
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)
    if appIcon {
        let tile = NSBezierPath(roundedRect: NSRect(x: 82, y: 92, width: 860, height: 860), xRadius: 192, yRadius: 192)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.23)
        shadow.shadowOffset = NSSize(width: 0, height: -20)
        shadow.shadowBlurRadius = 24
        shadow.set()
        sage.setFill()
        tile.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: NSColor(hex: 0x6F8A72), ending: NSColor(hex: 0x3F6250))!.draw(in: tile, angle: -90)
        let rim = NSBezierPath(roundedRect: NSRect(x: 83, y: 93, width: 858, height: 858), xRadius: 191, yRadius: 191)
        NSColor.white.withAlphaComponent(0.2).setStroke()
        rim.lineWidth = 2
        rim.stroke()
        leafMark(in: NSRect(x: 182, y: 182, width: 660, height: 660), light: true)
    } else {
        leafMark(in: NSRect(x: 40, y: 40, width: 944, height: 944), light: false)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = scratch.appendingPathComponent("Leaf.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try icon(size: size, appIcon: true).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try icon(size: size * 2, appIcon: true).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try icon(size: 512, appIcon: false).write(to: resources.appendingPathComponent("LeafMark.png"))
// An ICNS container of native PNG representations also works in headless builds.
func bigEndian(_ value: Int) -> Data {
    var integer = UInt32(value).bigEndian
    return withUnsafeBytes(of: &integer) { Data($0) }
}
var iconEntries = Data()
for (type, size) in [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128),
                     ("ic08", 256), ("ic09", 512), ("ic10", 1024), ("ic11", 32),
                     ("ic12", 64), ("ic13", 256), ("ic14", 512)] {
    let pixels = icon(size: size, appIcon: true)
    iconEntries.append(type.data(using: .ascii)!)
    iconEntries.append(bigEndian(pixels.count + 8))
    iconEntries.append(pixels)
}
var iconFile = "icns".data(using: .ascii)!
iconFile.append(bigEndian(iconEntries.count + 8))
iconFile.append(iconEntries)
try iconFile.write(to: resources.appendingPathComponent("Leaf.icns"))

let pageWidth: CGFloat = 612
let pageHeight: CGFloat = 792
let margin: CGFloat = 66
let contentWidth = pageWidth - margin * 2
let pdfData = NSMutableData()
let consumer = CGDataConsumer(data: pdfData)!
var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
let context = CGContext(consumer: consumer, mediaBox: &mediaBox, [
    kCGPDFContextTitle: "A little room to read",
    kCGPDFContextAuthor: "Leaf",
    kCGPDFContextCreator: "Leaf for macOS"
] as CFDictionary)!

func font(_ size: CGFloat, serif: Bool = false, bold: Bool = false) -> NSFont {
    if serif { return NSFont(name: bold ? "Georgia-Bold" : "Georgia", size: size) ?? NSFont.systemFont(ofSize: size) }
    return NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
}

@discardableResult
func text(_ value: String, x: CGFloat = margin, top: CGFloat, width: CGFloat = contentWidth,
          size: CGFloat = 13, serif: Bool = true, bold: Bool = false,
          color: NSColor = ink, lineSpacing: CGFloat = 6, height: CGFloat = 500) -> CGFloat {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = lineSpacing
    paragraph.paragraphSpacing = 10
    let string = NSAttributedString(string: value, attributes: [
        .font: font(size, serif: serif, bold: bold), .foregroundColor: color,
        .paragraphStyle: paragraph
    ])
    let measured = string.boundingRect(with: NSSize(width: width, height: height), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
    string.draw(with: NSRect(x: x, y: pageHeight - top - measured, width: width, height: measured), options: [.usesLineFragmentOrigin, .usesFontLeading])
    return measured
}

func rule(top: CGFloat, x: CGFloat = margin, width: CGFloat = contentWidth, color: NSColor = NSColor(hex: 0xDCE2D6)) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: x, y: pageHeight - top))
    path.line(to: NSPoint(x: x + width, y: pageHeight - top))
    path.lineWidth = 0.75
    color.setStroke()
    path.stroke()
}

func beginPage(_ number: Int, section: String) {
    context.beginPDFPage(nil)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    paper.setFill()
    NSRect(x: 0, y: 0, width: pageWidth, height: pageHeight).fill()
    text("LEAF / A READER'S COMPANION", top: 39, size: 8, serif: false, bold: true, color: sage)
    text(section.uppercased(), x: 365, top: 39, width: 180, size: 8, serif: false, color: muted)
    rule(top: 734)
    text("A little room to read", top: 750, size: 8, serif: false, color: muted)
    text(String(format: "%02d", number), x: 518, top: 749, width: 28, size: 9, serif: false, color: sage)
}

func endPage() {
    NSGraphicsContext.restoreGraphicsState()
    context.endPDFPage()
}

func callout(_ title: String, body: String, top: CGFloat, height: CGFloat = 102) {
    pale.setFill()
    NSBezierPath(roundedRect: NSRect(x: margin, y: pageHeight - top - height, width: contentWidth, height: height), xRadius: 10, yRadius: 10).fill()
    text(title, x: margin + 19, top: top + 17, width: contentWidth - 38, size: 10, serif: false, bold: true, color: sage)
    text(body, x: margin + 19, top: top + 40, width: contentWidth - 38, size: 12, lineSpacing: 4)
}

beginPage(1, section: "Welcome")
leafMark(in: NSRect(x: margin - 13, y: 589, width: 84, height: 84), light: false)
text("A little room\nto read.", top: 219, size: 49, lineSpacing: 1)
text("Meet Leaf. A quiet home for your PDFs.", top: 362, size: 16, color: sage)
text("Good reading starts with a little space. Space around the page. Space between ideas. Space to follow a thought all the way to its end.", top: 419, width: 430, size: 15, lineSpacing: 8)
text("Leaf keeps the essentials close: a clear page, comfortable sizing, simple navigation, and a few useful ways to leave your mark.", top: 522, width: 430, size: 15, lineSpacing: 8)
rule(top: 652)
text("START HERE", top: 674, size: 9, serif: false, bold: true, color: sage)
text("Press the right arrow to turn the page.", x: 173, top: 671, width: 370, size: 12)
endPage()

beginPage(2, section: "Find your way")
text("One page.\nThen the next.", top: 113, size: 36, lineSpacing: 3)
text("Move at the pace of your reading. Use the arrow buttons in the toolbar, press the left and right arrow keys, or enter a page number to go directly there.", top: 226, size: 14, lineSpacing: 7)
text("INSIDE THIS LITTLE GUIDE", top: 332, size: 9, serif: false, bold: true, color: sage)
let contents: [(String, String)] = [
    ("A little room to read", "01"),
    ("One page. Then the next.", "02"),
    ("Find your comfortable view", "03"),
    ("Keep the thought", "04"),
    ("A moment of reading", "05")
]
for (index, item) in contents.enumerated() {
    let top = CGFloat(370 + index * 41)
    text(item.0, top: top, size: 13)
    text(item.1, x: 520, top: top, width: 26, size: 11, serif: false, color: sage)
    rule(top: top + 28)
}
callout("A QUICKER WAY IN", body: "Open the sidebar for page thumbnails and the document outline. Use search to find a word or a passage.", top: 600)
endPage()

beginPage(3, section: "Make it comfortable")
text("Find your\ncomfortable view.", top: 113, size: 36, lineSpacing: 3)
text("The right view makes the page feel effortless. Match the PDF to your window, then adjust until the type feels right.", top: 226, size: 14, lineSpacing: 7)
let modes: [(String, String, String)] = [
    ("01", "Fit page", "See the whole page at once. A helpful view for a slide, a diagram, or a quick overview."),
    ("02", "Fit width", "Let the page fill the available horizontal space. Read larger type and scroll down naturally."),
    ("03", "Fit height", "Let the page fill the available vertical space. Keep the top and bottom in view as you turn pages.")
]
for (index, mode) in modes.enumerated() {
    let top = CGFloat(331 + index * 98)
    text(mode.0, top: top + 1, width: 40, size: 10, serif: false, bold: true, color: sage)
    text(mode.1, x: 112, top: top, width: 420, size: 16, bold: true)
    text(mode.2, x: 112, top: top + 30, width: 420, size: 12, color: muted, lineSpacing: 4)
}
callout("YOUR READING RHYTHM", body: "Choose continuous scrolling for a flowing document, or single-page mode for a more focused view.", top: 641, height: 74)
endPage()

beginPage(4, section: "Make a mark")
text("Keep the thought.", top: 119, size: 36)
text("Some sentences deserve a second reading. Select text and highlight it. Add a note for the thought that comes next. Rotate a page if it arrives sideways.", top: 186, size: 14, lineSpacing: 7)
rule(top: 286)
text("TRY A HIGHLIGHT", top: 312, size: 9, serif: false, bold: true, color: sage)
text("Attention is the beginning of understanding.\nA small mark can be a way back to a big idea.", top: 349, width: 452, size: 19, lineSpacing: 9)
text("Select a sentence above, then choose Highlight. This is real, selectable PDF text, so you can also copy it or search for a phrase.", top: 437, size: 12, color: muted, lineSpacing: 5)
text("LEAVE YOURSELF A NOTE", top: 514, size: 9, serif: false, bold: true, color: sage)
text("What would you like to remember from your next read?", top: 548, size: 14)
rule(top: 603)
rule(top: 636)
text("Save your changes to keep your annotations. Save As makes a separate copy. Leaf edits annotations and pages; it does not reflow the original document's text.", top: 665, size: 10, serif: false, color: muted, lineSpacing: 4)
endPage()

beginPage(5, section: "The reading room")
text("A moment\nof reading.", top: 113, size: 36, lineSpacing: 3)
text("A SHORT PASSAGE TO TRY YOUR NEW VIEW", top: 229, size: 9, serif: false, bold: true, color: sage)
text("The reading room was quiet before the rain began. Along the windows, the late afternoon light settled on the tables, and the shadows of the trees moved almost too slowly to notice.", top: 274, size: 14, lineSpacing: 8)
text("There was no hurry to finish. A book lay open, a cup stood nearby, and the day had become small enough to fit inside the margins of a page. Beyond the glass, people passed with their collars raised. Inside, a sentence waited patiently to be read again.", top: 378, size: 14, lineSpacing: 8)
text("Sometimes clarity arrives this way: not as a flash, but as enough room to look carefully. One line follows another. An idea takes shape. Something that seemed difficult becomes a little easier to see.", top: 509, size: 14, lineSpacing: 8)
rule(top: 643)
text("Make yourself comfortable.\nThe rest of the page is yours.", top: 665, size: 14, color: sage, lineSpacing: 4)
endPage()

context.closePDF()
let document = PDFDocument(data: pdfData as Data)!
let outline = PDFOutline()
for (index, entry) in contents.enumerated() {
    let child = PDFOutline()
    child.label = entry.0
    child.destination = PDFDestination(page: document.page(at: index)!, at: NSPoint(x: 0, y: pageHeight))
    outline.insertChild(child, at: index)
}
document.outlineRoot = outline
guard document.write(to: resources.appendingPathComponent("Welcome.pdf")) else { fatalError("Could not write welcome PDF") }
print("Generated Resources/Leaf.icns, Resources/LeafMark.png, and Resources/Welcome.pdf (\(document.pageCount) pages).")
