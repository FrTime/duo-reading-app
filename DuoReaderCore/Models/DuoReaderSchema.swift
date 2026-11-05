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
    /// build with an incompatible schema), moves it aside, starts a fresh one
    /// and puts the books from `booksFolder` back on the shelf. The user keeps
    /// their books; what's lost is only what lived in the store (reading
    /// positions, highlights), and the old store is kept for support.
    @MainActor
    public static func openOrRecover(
        url: URL = defaultStoreURL,
        booksFolder: URL = LibraryImporter.defaultBooksFolder
    ) throws -> OpenResult {
        do {
            return OpenResult(container: try makeContainer(url: url), recoveredFrom: nil)
        } catch {
            let backup = try moveAside(storeAt: url)
            let container = try makeContainer(url: url)
            try readopt(booksIn: booksFolder, into: container.mainContext)
            return OpenResult(container: container, recoveredFrom: backup)
        }
    }

    /// Moves the store and its -shm/-wal companions into `Recovered/<timestamp>/`.
    static func moveAside(storeAt url: URL) throws -> URL {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let folder = url.deletingLastPathComponent().appending(path: "Recovered/\(stamp)", directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for suffix in ["", "-shm", "-wal"] {
            let file = URL(fileURLWithPath: url.path() + suffix)
            if fm.fileExists(atPath: file.path()) {
                try fm.moveItem(at: file, to: folder.appending(path: file.lastPathComponent))
            }
        }
        return folder
    }

    /// Recreates a `Book` for every file already in the books folder, keeping
    /// its id (the file's UUID name) so other features' files still match.
    @MainActor
    static func readopt(booksIn folder: URL, into context: ModelContext) throws {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var order = 0
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let format = BookFormat(url: file),
                  let reader = MetadataReaders.reader(for: format),
                  let hash = try? LibraryImporter.sha256(of: file) else { continue }
            let book = Book(id: id, relativeFilePath: file.lastPathComponent, contentHash: hash,
                            format: format, title: "", shelfOrder: order)
            book.apply((try? reader.readMetadata(from: file)) ?? BookMetadata(), fileURL: file)
            context.insert(book)
            order += 1
        }
        try context.save()
    }
}
