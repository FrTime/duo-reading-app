import Foundation
import SwiftData

/// Version 1 of the library store.
///
/// Changing a model means adding `DuoReaderSchemaV2` with its own copies of the
/// models, moving the `Book` typealias to it, and adding a migration stage to
/// `DuoReaderMigrationPlan`. Never edit a shipped schema version in place.
public enum DuoReaderSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [Book.self]
    }
}

public enum DuoReaderMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [DuoReaderSchemaV1.self]
    }

    public static var stages: [MigrationStage] {
        []
    }
}

public enum LibraryStore {
    /// Where the library store lives: `Application Support/Library.store`,
    /// the same place SwiftData puts a configuration named "Library".
    public static var defaultStoreURL: URL {
        URL.applicationSupportDirectory.appending(path: "Library.store")
    }

    /// The model container for the app. Pass `inMemory: true` in tests and previews.
    public static func makeContainer(inMemory: Bool = false, url: URL = defaultStoreURL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: DuoReaderSchemaV1.self)
        let configuration = inMemory
            ? ModelConfiguration("Library", schema: schema, isStoredInMemoryOnly: true, allowsSave: true, cloudKitDatabase: .none)
            : ModelConfiguration(schema: schema, url: url, allowsSave: true, cloudKitDatabase: .none)
        return try ModelContainer(
            for: schema,
            migrationPlan: DuoReaderMigrationPlan.self,
            configurations: [configuration]
        )
    }

    /// The outcome of opening the store at launch.
    public struct OpenResult {
        public let container: ModelContainer
        /// Set when the old store couldn't be opened and a new one was made.
        /// Holds where the old store was moved, for support.
        public let recoveredFrom: URL?
    }

    /// Opens the library, and if the store can't be opened (corrupt, or from a
    /// build with an incompatible schema), moves it aside and starts a fresh
    /// one. The caller then puts the books back with `readopt(booksIn:into:)`
    /// off the main thread, so a big library can't stall launch. The user keeps
    /// their books; what's lost is only what lived in the store (reading
    /// positions, highlights), and the old store is kept for support.
    public static func openOrRecover(url: URL = defaultStoreURL) throws -> OpenResult {
        do {
            return OpenResult(container: try makeContainer(url: url), recoveredFrom: nil)
        } catch {
            let backup = try moveAside(storeAt: url)
            return OpenResult(container: try makeContainer(url: url), recoveredFrom: backup)
        }
    }

    /// How many old stores to keep in `Recovered/`.
    static let backupsKept = 3

    /// Moves the store and its -shm/-wal companions into `Recovered/<timestamp>/`,
    /// then deletes all but the newest `backupsKept` backups.
    static func moveAside(storeAt url: URL) throws -> URL {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let recovered = url.deletingLastPathComponent().appending(path: "Recovered", directoryHint: .isDirectory)
        var folder = recovered.appending(path: stamp, directoryHint: .isDirectory)
        if fm.fileExists(atPath: folder.path()) {
            folder = recovered.appending(path: "\(stamp)-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for suffix in ["", "-shm", "-wal"] {
            let file = URL(fileURLWithPath: url.path() + suffix)
            if fm.fileExists(atPath: file.path()) {
                try fm.moveItem(at: file, to: folder.appending(path: file.lastPathComponent))
            }
        }
        // ISO 8601 stamps sort by name in time order.
        let backups = ((try? fm.contentsOfDirectory(at: recovered, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for old in backups.dropLast(backupsKept) where old != folder {
            try? fm.removeItem(at: old)
        }
        return folder
    }

    /// Recreates a `Book` for every file already in the books folder, keeping
    /// its id (the file's UUID name) so other features' files still match.
    /// Books converted from text are stored as EPUB, so their hash becomes the
    /// EPUB's: re-importing the original text afterwards adds a second copy
    /// rather than being caught as a duplicate.
    /// Shelf order follows when each file was added. Runs on its own context,
    /// so call it off the main thread; it saves in batches so the shelf fills
    /// in as it goes.
    public static func readopt(
        booksIn folder: URL = LibraryImporter.defaultBooksFolder,
        into container: ModelContainer
    ) async throws {
        let context = ModelContext(container)
        let keys: Set<URLResourceKey> = [.creationDateKey]
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys))) ?? [])
            .map { ($0, (try? $0.resourceValues(forKeys: keys).creationDate) ?? .distantPast) }
            .sorted { ($0.1, $0.0.lastPathComponent) < ($1.1, $1.0.lastPathComponent) }
        var order = 0
        for (file, _) in files {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let format = BookFormat(url: file),
                  let reader = MetadataReaders.reader(for: format),
                  let hash = try? LibraryImporter.sha256(of: file) else { continue }
            let book = Book(id: id, relativeFilePath: file.lastPathComponent, contentHash: hash,
                            format: format, title: "", shelfOrder: order)
            book.apply((try? await reader.readMetadata(from: file)) ?? BookMetadata(), fileURL: file)
            context.insert(book)
            order += 1
            if order.isMultiple(of: 20) { try context.save() }
        }
        try context.save()
    }
}
