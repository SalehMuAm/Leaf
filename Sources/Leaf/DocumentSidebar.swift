import AppKit
import PDFKit
import SwiftUI

enum SidebarTab: String, CaseIterable, Identifiable {
    case pages = "Pages", outline = "Contents", search = "Search"
    var id: Self { self }
    var icon: String {
        switch self { case .pages: return "square.grid.2x2"; case .outline: return "list.bullet"; case .search: return "magnifyingglass" }
    }
}

struct DocumentSidebar: View {
    @ObservedObject var store: DocumentStore
    @Binding var tab: SidebarTab
    var searchFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(spacing: 0) {
            Picker("Sidebar", selection: $tab) {
                ForEach(SidebarTab.allCases) { item in
                    Image(systemName: item.icon).tag(item).help(item.rawValue).accessibilityLabel(item.rawValue)
                }
            }
            .pickerStyle(.segmented).labelsHidden().padding(14)

            HStack {
                Text(tab.rawValue.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.5)
                Spacer()
                if tab == .pages { Text("\(store.pageCount)").font(.system(size: 10)).monospacedDigit() }
            }
            .foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 12)

            switch tab {
            case .pages: thumbnails
            case .outline: outline
            case .search: search
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(LeafStyle.paper)
    }

    private var thumbnails: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 22) {
                    ForEach(0..<store.pageCount, id: \.self) { index in
                        PageThumbnail(store: store, index: index).id(index)
                    }
                }
                .padding(.horizontal, 25).padding(.top, 5).padding(.bottom, 26)
            }
            .onChange(of: store.currentPageIndex) { _, index in proxy.scrollTo(index, anchor: .center) }
            .onAppear { proxy.scrollTo(store.currentPageIndex, anchor: .center) }
        }
    }

    @ViewBuilder private var outline: some View {
        if let root = store.document?.outlineRoot, root.numberOfChildren > 0 {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(0..<root.numberOfChildren, id: \.self) { index in
                        if let item = root.child(at: index) { OutlineRow(item: item, store: store) }
                    }
                }.padding(.horizontal, 10).padding(.bottom, 20)
            }
        } else {
            sidebarMessage(icon: "list.bullet.rectangle", title: "No table of contents", detail: "This PDF doesn’t include an outline. Browse its pages instead.")
        }
    }

    private var search: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a word or phrase", text: $store.searchQuery)
                    .textFieldStyle(.plain).focused(searchFocused)
                    .onSubmit { store.nextSearchResult() }
                    .accessibilityLabel("Search document")
                if !store.searchQuery.isEmpty {
                    Button { store.searchQuery = ""; store.performSearch() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
                }
            }
            .padding(8).background(.background, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.primary.opacity(0.12)))
            .padding(.horizontal, 12)
            .task(id: store.searchQuery) {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                store.performSearch()
            }
            if store.isSearching {
                ProgressView().controlSize(.small).padding(22)
                Spacer()
            } else if store.searchQuery.isEmpty {
                sidebarMessage(icon: "text.magnifyingglass", title: "Find your place", detail: "Search the text in this document. Use ⌘G to jump to the next match.")
            } else if store.searchResults.isEmpty {
                sidebarMessage(icon: "magnifyingglass", title: "No matches", detail: "Try a different word. Scanned pages may not contain searchable text.")
            } else {
                HStack {
                    Text("\(store.searchResults.count) \(store.searchResults.count == 1 ? "match" : "matches")").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(action: store.previousSearchResult) { Image(systemName: "chevron.up") }
                        .accessibilityLabel("Previous match")
                    Button(action: store.nextSearchResult) { Image(systemName: "chevron.down") }
                        .accessibilityLabel("Next match")
                }
                .buttonStyle(.borderless).padding(14)
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(store.searchResults.enumerated()), id: \.element.id) { index, hit in
                            Button { store.selectSearchResult(index) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("PAGE \(hit.pageIndex + 1)").font(.system(size: 9, weight: .semibold)).tracking(1)
                                        .foregroundStyle(LeafStyle.accent)
                                    Text(hit.excerpt).font(.system(size: 12)).lineLimit(4).multilineTextAlignment(.leading)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(store.activeSearchIndex == index ? LeafStyle.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain).help(hit.excerpt)
                        }
                    }.padding(.horizontal, 10)
                }
            }
        }
    }

    private func sidebarMessage(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary).padding(.top, 34)
            Text(title).font(.system(size: 12, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(3)
            Spacer()
        }.padding(.horizontal, 20).frame(maxWidth: .infinity)
    }
}

private struct PageThumbnail: View {
    @ObservedObject var store: DocumentStore
    let index: Int
    @State private var image: NSImage?

    private var selected: Bool { store.currentPageIndex == index }
    var body: some View {
        Button { store.goToPage(index: index) } label: {
            VStack(spacing: 9) {
                Group {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        Rectangle().fill(.white).aspectRatio(0.707, contentMode: .fit)
                    }
                }
                .frame(maxWidth: 140, maxHeight: 188)
                .shadow(color: .black.opacity(0.09), radius: 3, y: 2)
                .padding(5)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? LeafStyle.accent : .clear, lineWidth: 2))
                HStack(spacing: 5) {
                    if selected { Circle().fill(LeafStyle.accent).frame(width: 4, height: 4) }
                    Text("\(index + 1)").font(.system(size: 11, weight: selected ? .semibold : .regular)).monospacedDigit()
                }
                .foregroundStyle(selected ? LeafStyle.accent : .secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Page \(index + 1)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .task(id: "\(store.pageRevision)-\(ObjectIdentifier(store.document ?? PDFDocument()))") {
            image = store.document?.page(at: index)?.thumbnail(of: NSSize(width: 280, height: 376), for: .cropBox)
        }
    }
}

/// PDFKit keeps outline destinations alive when their page is removed. Resolve
/// against the current document before displaying or navigating to an index.
struct OutlineLocation {
    let destination: PDFDestination
    let pageIndex: Int

    init?(_ item: PDFOutline, in document: PDFDocument?) {
        guard let document,
              let destination = item.destination ?? (item.action as? PDFActionGoTo)?.destination,
              let page = destination.page else { return nil }
        let index = document.index(for: page)
        guard index != NSNotFound, (0..<document.pageCount).contains(index) else { return nil }
        self.destination = destination
        pageIndex = index
    }
}

private struct OutlineRow: View {
    let item: PDFOutline
    @ObservedObject var store: DocumentStore
    @State private var expanded = true

    private var location: OutlineLocation? { OutlineLocation(item, in: store.document) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                if item.numberOfChildren > 0 {
                    Button { expanded.toggle() } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9)).frame(width: 16, height: 24)
                    }.buttonStyle(.plain).accessibilityLabel(expanded ? "Collapse section" : "Expand section")
                }
                Button {
                    guard let location else { return }
                    store.goToPage(index: location.pageIndex)
                    store.pdfView?.go(to: location.destination)
                } label: {
                    HStack {
                        Text(item.label ?? "Untitled section").lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength: 2)
                        if let location {
                            Text("\(location.pageIndex + 1)").foregroundStyle(.tertiary).monospacedDigit()
                        }
                    }.font(.system(size: 12)).padding(.vertical, 9).padding(.horizontal, 6).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(location == nil).help(item.label ?? "Untitled section")
            }
            if expanded && item.numberOfChildren > 0 {
                ForEach(0..<item.numberOfChildren, id: \.self) { index in
                    if let child = item.child(at: index) {
                        OutlineRow(item: child, store: store).padding(.leading, 14)
                    }
                }
            }
        }
    }
}
