import Foundation
import SwiftData
import UIKit
import WidgetKit

/// Keeps the widgets' snapshot in step with the library.
///
/// The app calls `refresh()` when it goes to the background, and
/// `refreshSoon()` after the store saves. Refreshes run one at a time; a
/// request that arrives during one runs once more afterwards. WidgetKit is
/// only asked to reload when something the widgets show has changed.
@MainActor
final class WidgetSnapshotWriter {
    /// What the writer needs from a book's cover design.
    struct CoverInfo: Sendable {
        var thickness: Double
        var baseColor: RGBAColor
        var spineColor: RGBAColor
        /// Where the rendered front and spine are, if they've been rendered.
        var frontURL: URL?
        var spineURL: URL?
    }

    private let container: ModelContainer
    private let store: WidgetStore?
    private let coverInfo: @MainActor (Book) async -> CoverInfo
    private let shelfStyle: @MainActor () -> WidgetSnapshot.ShelfStyle
    private let reload: @MainActor () -> Void

    private var running: Task<Void, Never>?
    private var runAgain = false
    private var scheduled: Task<Void, Never>?

    init(
        container: ModelContainer,
        store: WidgetStore? = WidgetStore.shared(),
        coverInfo: (@MainActor (Book) async -> CoverInfo)? = nil,
        shelfStyle: @escaping @MainActor () -> WidgetSnapshot.ShelfStyle = {
            WidgetSnapshot.ShelfStyle(storedValue: UserDefaults.standard.string(forKey: "shelf.displayMode"))
        },
        reload: @escaping @MainActor () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    ) {
        self.container = container
        self.store = store
        self.coverInfo = coverInfo ?? Self.coverInfoFromLibrary
        self.shelfStyle = shelfStyle
        self.reload = reload
    }

    /// Refreshes after `delay`, folding any further requests in that time into one.
    func refreshSoon(after delay: Duration = .seconds(5)) {
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Writes a fresh snapshot now, or straight after the one in progress.
    func refresh() async {
        if let running {
            runAgain = true
            await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.runAgain = false
                await self.writeSnapshot()
            } while self.runAgain
            self.running = nil
        }
        running = task
        await task.value
    }

    // MARK: - Writing

    private func writeSnapshot() async {
        guard let store else { return }
        let context = container.mainContext
        let descriptor = FetchDescriptor<Book>(sortBy: [SortDescriptor(\.shelfOrder), SortDescriptor(\.dateAdded)])
        guard let books = try? context.fetch(descriptor) else { return }

        // Only the books the widgets can show need their covers prepared.
        let currentCandidate = WidgetSnapshot.pickCurrent(from: books.map { Self.entry(for: $0, cover: nil) })
        var shown = Array(books.prefix(WidgetSnapshot.maxShelfBooks))
        if let id = currentCandidate?.id, !shown.contains(where: { $0.id == id }),
           let book = books.first(where: { $0.id == id }) {
            shown.append(book)
        }

        var infos: [UUID: CoverInfo] = [:]
        for book in shown {
            infos[book.id] = await coverInfo(book)
        }
        // The books may have changed while covers were prepared.
        let live = shown.filter { !$0.isDeleted && $0.modelContext != nil }
        let entries = live.map { Self.entry(for: $0, cover: infos[$0.id]) }
        let shelf = Array(entries.prefix(WidgetSnapshot.maxShelfBooks))
        let current = currentCandidate.flatMap { candidate in entries.first { $0.id == candidate.id } }

        let snapshot = WidgetSnapshot(
            generatedAt: .now,
            shelfStyle: shelfStyle(),
            totalBookCount: books.count,
            books: shelf,
            current: current
        )

        var jobs: [ImageJob] = []
        for entry in shelf {
            guard let info = infos[entry.id] else { continue }
            if let url = info.frontURL { jobs.append(ImageJob(source: url, destination: store.imageURL(.front, for: entry.id), maxPixels: WidgetStore.ImageKind.front.maxPixels)) }
            if let url = info.spineURL { jobs.append(ImageJob(source: url, destination: store.imageURL(.spine, for: entry.id), maxPixels: WidgetStore.ImageKind.spine.maxPixels)) }
        }
        if let current, let url = infos[current.id]?.frontURL {
            jobs.append(ImageJob(source: url, destination: store.imageURL(.cover, for: current.id), maxPixels: WidgetStore.ImageKind.cover.maxPixels))
        }

        let folder = store.imagesFolder
        let imagesChanged = await Task.detached(priority: .utility) {
            Self.writeImages(jobs, into: folder)
        }.value

        let previous = store.load()
        let contentChanged = !snapshot.hasSameContent(as: previous)
        if contentChanged {
            do {
                try store.save(snapshot)
            } catch {
                return
            }
        }
        if contentChanged || imagesChanged {
            reload()
        }
    }

    static func entry(for book: Book, cover: CoverInfo?) -> WidgetSnapshot.Book {
        let base = cover?.baseColor ?? RGBAColor(red: 0.35, green: 0.33, blue: 0.4)
        let spine = cover?.spineColor ?? base
        return WidgetSnapshot.Book(
            id: book.id,
            title: book.title.isEmpty ? String(localized: "Untitled") : book.title,
            author: book.displayAuthors,
            progress: book.progress,
            thickness: cover?.thickness ?? 0.12,
            baseColor: WidgetSnapshot.Color(base),
            spineColor: WidgetSnapshot.Color(spine),
            lastOpened: book.lastOpened
        )
    }

    // MARK: - Images

    struct ImageJob: Sendable {
        var source: URL
        var destination: URL
        var maxPixels: Int
    }

    /// Downsizes each image that's missing or older than its source, and
    /// deletes images no job asked for (books that were removed or scrolled
    /// past the cap). Returns whether anything changed.
    nonisolated static func writeImages(_ jobs: [ImageJob], into folder: URL) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var changed = false
        for job in jobs {
            guard let sourceDate = modificationDate(of: job.source) else { continue }
            if let existing = modificationDate(of: job.destination), existing >= sourceDate { continue }
            guard let image = CoverStore.loadImage(at: job.source, maxPixels: job.maxPixels),
                  let data = image.jpegData(compressionQuality: 0.85) else { continue }
            if (try? data.write(to: job.destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil {
                changed = true
            }
        }
        let wanted = Set(jobs.map { $0.destination.standardizedFileURL.lastPathComponent })
        let present = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in present where !wanted.contains(file.lastPathComponent) {
            if (try? fm.removeItem(at: file)) != nil { changed = true }
        }
        return changed
    }

    nonisolated private static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    // MARK: - Covers

    private static let coverStore = CoverStore(root: CoverStore.defaultRoot())

    private static func coverInfoFromLibrary(_ book: Book) async -> CoverInfo {
        // Preparing the design renders the faces if they've never been drawn.
        let design = await CoverLibrary.shared.design(for: book)
        let front = coverStore.renderedURL(.front, for: book.id)
        let spine = coverStore.renderedURL(.spine, for: book.id)
        let fm = FileManager.default
        return CoverInfo(
            thickness: design.thickness,
            baseColor: design.baseColor,
            spineColor: design.spineColor,
            frontURL: fm.fileExists(atPath: front.path(percentEncoded: false)) ? front : nil,
            spineURL: fm.fileExists(atPath: spine.path(percentEncoded: false)) ? spine : nil
        )
    }
}

extension WidgetSnapshot.Color {
    init(_ color: RGBAColor) {
        self.init(red: color.red, green: color.green, blue: color.blue)
    }
}
