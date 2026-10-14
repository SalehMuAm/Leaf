import AppKit
import SwiftUI

@main
struct LeafApp: App {
    @NSApplicationDelegateAdaptor(LeafAppDelegate.self) private var appDelegate
    @StateObject private var store = DocumentStore()

    var body: some Scene {
        Window("Leaf", id: "reader") {
            ReaderView(store: store)
                .frame(minWidth: 820, minHeight: 580)
                .onAppear { appDelegate.connect(store) }
                .onOpenURL { store.open(url: $0) }
        }
        .defaultSize(width: 1220, height: 840)
        .windowToolbarStyle(.unified)
        .commands { LeafCommands(store: store) }
    }
}

@MainActor
final class LeafAppDelegate: NSObject, NSApplicationDelegate {
    weak var store: DocumentStore?
    private var pendingURL: URL?

    func connect(_ store: DocumentStore) {
        self.store = store
        if let url = pendingURL {
            pendingURL = nil
            store.open(url: url)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let store { store.open(url: url) } else { pendingURL = url }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        store?.confirmDiscardIfNeeded() == false ? .terminateCancel : .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct LeafCommands: Commands {
    @ObservedObject var store: DocumentStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open PDF…", action: store.openPanel).keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(store.recentURLs, id: \.self) { url in
                    Button(url.lastPathComponent) { store.open(url: url) }
                }
                if store.recentURLs.isEmpty { Text("No recent documents") }
            }
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { store.save() }.keyboardShortcut("s")
                .disabled(store.document == nil)
            Button("Save As…") { store.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(store.document == nil)
            Divider()
            Button("Extract Pages…") { NotificationCenter.default.post(name: .leafExtractPages, object: nil) }
                .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!store.canExtractPages)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…", action: store.printDocument).keyboardShortcut("p")
                .disabled(store.document == nil)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo", action: store.undo).keyboardShortcut("z").disabled(!store.canUndo)
            Button("Redo", action: store.redo).keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!store.canRedo)
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find in Document…") { NotificationCenter.default.post(name: .leafShowSearch, object: nil) }
                .keyboardShortcut("f").disabled(store.document == nil)
            Button("Find Next", action: store.nextSearchResult).keyboardShortcut("g").disabled(store.searchResults.isEmpty)
            Button("Find Previous", action: store.previousSearchResult)
                .keyboardShortcut("g", modifiers: [.command, .shift]).disabled(store.searchResults.isEmpty)
        }
        CommandMenu("Read") {
            Button("Previous Page", action: store.previousPage).keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(store.currentPageIndex <= 0 || store.document == nil)
            Button("Next Page", action: store.nextPage).keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(store.currentPageIndex >= store.pageCount - 1)
            Divider()
            Button("Fit Page") { store.setFitMode(.page) }.keyboardShortcut("0")
            Button("Fit Width") { store.setFitMode(.width) }.keyboardShortcut("1")
            Button("Fit Height") { store.setFitMode(.height) }.keyboardShortcut("2")
            Button("Actual Size") { store.setFitMode(.actual) }.keyboardShortcut("3")
            Button("Zoom In", action: store.zoomIn).keyboardShortcut("+")
            Button("Zoom Out", action: store.zoomOut).keyboardShortcut("-")
            Divider()
            ForEach(ReadingLayout.allCases) { layout in
                Button(layout.label) { store.setLayout(layout) }
            }
            Divider()
            Button(store.isFocusMode ? "Leave Focus Mode" : "Enter Focus Mode") { store.isFocusMode.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button(store.showSidebar ? "Hide Sidebar" : "Show Sidebar") { store.showSidebar.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
        }
        CommandMenu("Annotate") {
            Button("Highlight Selection", action: store.highlightSelection)
                .keyboardShortcut("h", modifiers: [.command, .shift]).disabled(!store.selectionAvailable)
            Button("Add Note…") { NotificationCenter.default.post(name: .leafAddNote, object: nil) }
                .keyboardShortcut("n", modifiers: [.command, .shift]).disabled(store.document == nil)
            Button("Add Text Box…") { NotificationCenter.default.post(name: .leafAddTextBox, object: nil) }
                .keyboardShortcut("t", modifiers: [.command, .shift]).disabled(store.document == nil)
            Divider()
            Button("Draw with Pen") { store.beginDrawing(tool: .pen) }
                .keyboardShortcut("d", modifiers: [.command, .shift]).disabled(store.document == nil)
            Menu("Shapes") {
                ForEach(DrawingTool.allCases.filter { $0 != .pen }) { tool in
                    Button(tool.title) { store.beginDrawing(tool: tool) }
                }
            }.disabled(store.document == nil)
            if store.activeDrawingTool != nil {
                Button("Finish Drawing", action: store.endDrawing)
            }
            Divider()
            Button("Rotate Page Clockwise", action: store.rotateCurrentPage)
                .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(store.document == nil)
            Button("Insert Pages from PDF…", action: store.insertPages).disabled(store.document == nil)
            Button("Delete Current Page…", action: store.deleteCurrentPage).disabled(store.pageCount <= 1)
        }
        CommandGroup(replacing: .help) {
            Button("Welcome to Leaf") {
                if let url = LeafResources.welcomeURL { store.openWelcomeDocument(url: url) }
            }
        }
    }
}

extension Notification.Name {
    static let leafShowSearch = Notification.Name("leaf.showSearch")
    static let leafAddNote = Notification.Name("leaf.addNote")
    static let leafAddTextBox = Notification.Name("leaf.addTextBox")
    static let leafExtractPages = Notification.Name("leaf.extractPages")
}

enum LeafResources {
    static var welcomeURL: URL? {
        url(forResource: "Welcome", withExtension: "pdf")
    }

    static func url(forResource name: String, withExtension fileExtension: String) -> URL? {
        // The distribution app copies its assets directly into Contents/Resources.
        if let url = Bundle.main.url(forResource: name, withExtension: fileExtension) { return url }

        // Also support embedding only SwiftPM's resource bundle in an app. Look
        // beside the app resources and at the bundle root rather than relying on
        // the development build path baked into SwiftPM's generated accessor.
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap({ $0 }) {
            let bundleURL = base.appendingPathComponent("Leaf_Leaf.bundle", isDirectory: true)
            if let bundle = Bundle(url: bundleURL),
               let url = bundle.url(forResource: name, withExtension: fileExtension) { return url }
        }

        #if SWIFT_PACKAGE
        // swift run, direct executable launches, and package tests find their
        // resources beside the executable regardless of the working directory.
        if Bundle.main.bundleURL.pathExtension != "app" {
            return Bundle.module.url(forResource: name, withExtension: fileExtension)
        }
        #endif
        return nil
    }
}
