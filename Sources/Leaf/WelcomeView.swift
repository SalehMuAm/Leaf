import AppKit
import SwiftUI

struct WelcomeView: View {
    @ObservedObject var store: DocumentStore

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 9) {
                        Image(systemName: "leaf").font(.system(size: 22, weight: .light))
                        Text("leaf").font(.system(size: 27, weight: .medium, design: .serif)).tracking(-1)
                    }
                    .foregroundStyle(LeafStyle.accent)
                    Spacer(minLength: 30)
                    Text("A little room\nto read.")
                        .font(.system(size: 51, weight: .regular, design: .serif)).tracking(-1.8).lineSpacing(-3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Your documents. A quieter view.")
                        .font(.system(size: 15)).foregroundStyle(.secondary).padding(.top, 20)
                    Text("Open a PDF and settle in. Leaf keeps the tools\nyou need close, and the page at the center.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(6).padding(.top, 9)
                    HStack(spacing: 12) {
                        Button(action: store.openPanel) { Label("Open a PDF", systemImage: "folder").padding(.horizontal, 8).padding(.vertical, 4) }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                        Text("⌘O").font(.system(size: 12)).foregroundStyle(.tertiary)
                    }.padding(.top, 28)
                    Button {
                        if let url = LeafResources.welcomeURL { store.openWelcomeDocument(url: url) }
                    } label: {
                        HStack(spacing: 7) { Text("Take a look around"); Image(systemName: "arrow.right") }
                            .font(.system(size: 12)).foregroundStyle(LeafStyle.accent)
                    }
                    .buttonStyle(.plain).padding(.top, 20)
                    Spacer(minLength: 36)
                    Label("Made for the pleasure of reading", systemImage: "sun.max")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 48).padding(.leading, 54).padding(.trailing, 20)
                .frame(width: max(430, geometry.size.width * 0.48), alignment: .leading)
                VStack(spacing: 0) {
                    readingIllustration
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if !store.recentURLs.isEmpty { recentDocuments.padding(.horizontal, 36).padding(.bottom, 28) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LeafStyle.accent.opacity(0.055))
            }
        }
    }

    private var readingIllustration: some View {
        VStack(spacing: 24) {
            ZStack {
                RoundedRectangle(cornerRadius: 2).fill(LeafStyle.paper)
                    .frame(width: 222, height: 290).rotationEffect(.degrees(7)).offset(x: 13, y: 3)
                    .shadow(color: .black.opacity(0.05), radius: 15, y: 8)
                VStack(alignment: .leading, spacing: 0) {
                    HStack { Text("THE ART OF ATTENTION").tracking(2); Spacer(); Image(systemName: "leaf") }
                        .font(.system(size: 6, weight: .medium)).foregroundStyle(LeafStyle.accent)
                    Rectangle().fill(LeafStyle.accent.opacity(0.25)).frame(height: 0.5).padding(.top, 12)
                    Text("Less noise.\nMore meaning.")
                        .font(.system(size: 26, design: .serif)).tracking(-0.7).foregroundStyle(Color(white: 0.18))
                        .padding(.top, 29)
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(0..<7, id: \.self) { index in
                            Rectangle().fill(index == 3 ? LeafStyle.accent.opacity(0.22) : Color.black.opacity(0.10))
                                .frame(width: index == 6 ? 98 : 167, height: index == 3 ? 8 : 2)
                        }
                    }.padding(.top, 23)
                    Spacer()
                    HStack { Rectangle().fill(Color.black.opacity(0.12)).frame(width: 30, height: 1); Spacer(); Text("01").font(.system(size: 7)).foregroundStyle(.gray) }
                }
                .padding(28).frame(width: 224, height: 300)
                .background(Color(red: 0.998, green: 0.992, blue: 0.970))
                .overlay(Rectangle().stroke(.black.opacity(0.06), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.10), radius: 20, x: 0, y: 10)
                .rotationEffect(.degrees(-5))
            }
            Text("DROP A PDF ANYWHERE").font(.system(size: 9, weight: .medium)).tracking(1.8).foregroundStyle(.secondary)
        }
        .padding(.top, 25)
        .accessibilityElement(children: .ignore).accessibilityLabel("Drop a PDF anywhere in this window to open it")
    }

    private var recentDocuments: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECENT DOCUMENTS").font(.system(size: 9, weight: .medium)).tracking(1.2).foregroundStyle(.secondary).padding(.bottom, 4)
            ForEach(Array(store.recentURLs.prefix(3)), id: \.self) { url in
                Button { store.open(url: url) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.richtext").foregroundStyle(LeafStyle.accent)
                        Text(url.deletingPathExtension().lastPathComponent).lineLimit(1)
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }.font(.system(size: 12)).padding(9).contentShape(Rectangle())
                }.buttonStyle(.plain).help(url.path)
            }
        }
    }
}
