import Foundation
import PDFKit

enum PageRange {
    /// Page numbers in the UI are one-based. The result is unique, zero-based,
    /// and in document order, regardless of the order in which ranges are typed.
    static func parse(_ input: String, totalPages: Int) throws -> [Int] {
        guard totalPages > 0 else { throw RangeError.noPages }
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
        guard !normalized.isEmpty else { throw RangeError.empty }
        var pages = Set<Int>()
        for item in normalized.split(separator: ",", omittingEmptySubsequences: false) {
            let token = String(item).trimmingCharacters(in: .whitespacesAndNewlines)
            let endpoints = token.split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(endpoints.count) else { throw RangeError.malformed(token) }
            let first = try pageNumber(endpoints[0], totalPages: totalPages, token: token)
            if endpoints.count == 1 {
                pages.insert(first - 1)
            } else {
                let last = try pageNumber(endpoints[1], totalPages: totalPages, token: token)
                guard first <= last else { throw RangeError.reversed(token) }
                for page in first...last { pages.insert(page - 1) }
            }
        }
        return pages.sorted()
    }

    private static func pageNumber(_ input: Substring, totalPages: Int, token: String) throws -> Int {
        let digits = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw RangeError.malformed(token)
        }
        guard let number = Int(digits), (1...totalPages).contains(number) else {
            throw RangeError.outOfBounds(totalPages)
        }
        return number
    }

    private enum RangeError: LocalizedError {
        case empty, noPages
        case malformed(String), reversed(String), outOfBounds(Int)

        var errorDescription: String? {
            switch self {
            case .empty:
                return "Enter the pages to extract, such as 1, 3–5."
            case .noPages:
                return "Open a PDF with pages to extract."
            case .malformed(let token):
                return token.isEmpty
                    ? "Enter a page number between each comma."
                    : "“\(token)” isn’t a page or range. Use a format such as 1, 3–5."
            case .reversed(let token):
                return "“\(token)” runs backwards. Put the lower page number first."
            case .outOfBounds(let totalPages):
                return "Page numbers must be between 1 and \(totalPages)."
            }
        }
    }
}

extension DocumentStore {
    var canExtractPages: Bool {
        guard let document else { return false }
        return !document.isLocked && document.pageCount > 0
            && document.allowsCopying && document.allowsDocumentAssembly
    }

    /// Save a separate PDF. Extraction does not move pages, reset the source's
    /// saved revision, or replace the source's undo history or recent-file entry.
    @discardableResult
    func extractPages(_ indices: [Int], to url: URL) -> Bool {
        guard let document, !document.isLocked else {
            errorMessage = "Open and unlock a PDF before extracting pages."
            return false
        }
        guard document.allowsCopying && document.allowsDocumentAssembly else {
            errorMessage = "The owner of this PDF has disabled copying or extracting pages."
            return false
        }
        let pages = Set(indices).sorted()
        guard !pages.isEmpty, pages.allSatisfy({ (0..<document.pageCount).contains($0) }) else {
            errorMessage = "Choose at least one page within this PDF’s page range."
            return false
        }
        guard url.isFileURL else {
            errorMessage = "Choose a file location for the extracted PDF."
            return false
        }
        let accessStarted = url.startAccessingSecurityScopedResource()
        defer { if accessStarted { url.stopAccessingSecurityScopedResource() } }
        if let source = fileURL ?? document.documentURL, Self.isSameFile(source, url) {
            errorMessage = "Choose a different filename so the extracted pages don’t replace the open PDF."
            return false
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            errorMessage = "Choose a PDF filename inside the destination folder."
            return false
        }

        commitPendingEdits()
        let extracted = PDFDocument()
        extracted.documentAttributes = document.documentAttributes
        for index in pages {
            guard let copy = document.page(at: index)?.copy() as? PDFPage else {
                errorMessage = "Page \(index + 1) couldn’t be copied. The original PDF has not been changed."
                return false
            }
            extracted.insert(copy, at: extracted.pageCount)
        }

        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".leaf-extract-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        do {
            guard extracted.write(to: temporaryURL),
                  let verified = PDFDocument(url: temporaryURL),
                  verified.pageCount == pages.count else {
                throw ExtractionError.writeFailed
            }
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: url)
            }
            return true
        } catch {
            errorMessage = "The pages couldn’t be extracted. \(error.localizedDescription) Choose another filename or location."
            return false
        }
    }

    private static func isSameFile(_ first: URL, _ second: URL) -> Bool {
        let first = first.standardizedFileURL.resolvingSymlinksInPath()
        let second = second.standardizedFileURL.resolvingSymlinksInPath()
        if first == second { return true }
        // File identities also catch hard links and case variants on volumes
        // whose names are case-insensitive.
        guard let lhs = try? FileManager.default.attributesOfItem(atPath: first.path),
              let rhs = try? FileManager.default.attributesOfItem(atPath: second.path),
              let lhsFile = lhs[.systemFileNumber] as? NSNumber,
              let rhsFile = rhs[.systemFileNumber] as? NSNumber,
              let lhsVolume = lhs[.systemNumber] as? NSNumber,
              let rhsVolume = rhs[.systemNumber] as? NSNumber else { return false }
        return lhsFile == rhsFile && lhsVolume == rhsVolume
    }
}

private enum ExtractionError: LocalizedError {
    case writeFailed
    var errorDescription: String? { "PDFKit could not write a complete PDF file." }
}
