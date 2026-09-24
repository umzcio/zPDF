//
//  RecentFileCard.swift
//  zPDF
//
//  Purpose: One card in the Home recents grid — thumbnail well, name,
//  "last opened · size" subtitle, star toggle. Tap opens the file in a tab.
//  Phase: 2 — REAL. The well renders the PDF's first page (security-scoped
//  bookmark resolved off-main, rendered via the engine, cached in a static
//  NSCache); the placeholder icon shows while loading or on failure.
//

import AppKit
import SwiftUI

struct RecentFileCard: View {
    @Environment(AppState.self) private var appState
    let file: RecentFile

    @State private var thumbnail: NSImage?

    /// Rendered first-page thumbnails, keyed by file id + well size, so
    /// scrolling the grid never re-renders a card.
    private static let thumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        return cache
    }()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Button(action: open) {
                VStack(spacing: 0) {
                    thumbnailWell
                    metadata
                }
                .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.large))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(file.name)")
            .help("Open \(file.name)")
            .modifier(KeyboardFocusRing())

            starButton
                .padding(6)
        }
        .background(DesignTokens.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.large))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.large)
                .stroke(DesignTokens.Colors.hairline, lineWidth: 1)
        )
    }

    private var thumbnailWell: some View {
        GeometryReader { proxy in
            ZStack {
                DesignTokens.Colors.thumbnailWell
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(DesignTokens.Colors.accent)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .task(id: proxy.size) {
                await loadThumbnail(fitting: proxy.size)
            }
        }
        .frame(height: 118)
    }

    /// Resolve the bookmark, open the document, and render page 1 into the
    /// well — all off the main actor. Cancellation-safe: a scrolled-away or
    /// resized card abandons its result instead of mutating stale state.
    private func loadThumbnail(fitting size: CGSize) async {
        guard thumbnail == nil, size.width > 0, size.height > 0 else { return }
        let cacheKey = "\(file.id.uuidString)-\(Int(size.width))x\(Int(size.height))" as NSString
        if let cached = Self.thumbnailCache.object(forKey: cacheKey) {
            thumbnail = cached
            return
        }
        // Render at 2x so thumbnails stay sharp on Retina displays.
        let renderSize = CGSize(width: size.width * 2, height: size.height * 2)
        let file = self.file
        let rendered = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let url = file.resolveURL() else { return nil }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            // The engine is stateless; a fresh instance keeps this closure
            // free of non-Sendable captures (the `any PDFEngine` existential
            // on AppState cannot cross into a `sending` closure).
            let engine = PDFKitEngine()
            guard let document = try? engine.openDocument(at: url),
                  let page = engine.page(at: 0, in: document) else {
                return nil
            }
            return engine.thumbnail(for: page, size: renderSize)
        }.value
        guard !Task.isCancelled, let rendered else { return }
        Self.thumbnailCache.setObject(rendered, forKey: cacheKey)
        thumbnail = rendered
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(file.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(file.formattedLastOpened) · \(file.formattedFileSize)")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.mutedText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 9, leading: 10, bottom: 10, trailing: 38))
    }

    private var starButton: some View {
        Button {
            appState.recentFiles.toggleStar(file)
        } label: {
            Image(systemName: file.isStarred ? "star.fill" : "star")
                .font(.system(size: 13))
                .foregroundStyle(file.isStarred ? DesignTokens.Colors.starActive : DesignTokens.Colors.mutedText)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(KeyboardFocusRing())
        .help(file.isStarred ? "Remove from starred files" : "Add to starred files")
        .accessibilityLabel(file.isStarred ? "Unstar \(file.name)" : "Star \(file.name)")
    }

    private func open() {
        appState.openRecent(file)
    }
}

#Preview {
    RecentFileCard(file: RecentFile(bookmarkData: Data(),
                                    name: "Quarterly-Report.pdf",
                                    lastOpened: Date().addingTimeInterval(-7200),
                                    fileSize: 2_400_000,
                                    isStarred: true))
        .environment(AppState())
        .frame(width: 200)
        .padding()
}
