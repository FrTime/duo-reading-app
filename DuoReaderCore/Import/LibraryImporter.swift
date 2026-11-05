import CryptoKit
import Foundation
import SwiftData

/// What happened to one file the user tried to import.
public enum ImportOutcome: Sendable, Equatable {
    case imported(PersistentIdentifier, title: String)
    /// The same file (by content) is already in the library.
    case duplicate(title: String)
    case failed(fileName: String, reason: ImportFailure)
}

public enum ImportFailure: Error, Sendable, Equatable {
    /// We don't read this format yet.
    case unsupportedFormat
    /// The file is DRM-protected. DRM removal is out of scope.
    case drmProtected
    /// The file is damaged or isn't what its extension says.
    case unreadable
    /// The file couldn't be copied into the library (permissions, disk space).
    case copyFailed
}

/// Copies files into the library and creates their `Book`s, off the main actor.
///
/// Files are copied into `booksFolder` under a fresh UUID name, so the app owns
/// its copy and never depends on access to the original location.
@ModelActor
public actor LibraryImporter {
    private var booksFolder: URL = LibraryImporter.defaultBooksFolder

    public init(modelContainer: ModelContainer, booksFolder: URL) {
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(modelContainer))
        self.modelContainer = modelContainer
        self.booksFolder = booksFolder
    }

    /// `Application Support/Books`. Included in backups: these are the user's files.
    public static var defaultBooksFolder: URL {
        URL.applicationSupportDirectory.appending(path: "Books", directoryHint: .isDirectory)
    }

    /// Formats the importer accepts today: those with a metadata reader.
    public static var supportedFormats: [BookFormat] {
        BookFormat.allCases.filter { MetadataReaders.reader(for: $0) != nil }
    }

    /// Imports each file in order and reports what happened to each.
    public func importFiles(_ urls: [URL]) -> [ImportOutcome] {
        urls.map(importFile)
    }

    public func importFile(_ url: URL) -> ImportOutcome {
        let fileName = url.lastPathComponent
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let format = BookFormat(url: url),
              let reader = MetadataReaders.reader(for: format) else {
            return .failed(fileName: fileName, reason: .unsupportedFormat)
        }

        let hash: String
        do {
            hash = try Self.sha256(of: url)
        } catch {
            return .failed(fileName: fileName, reason: .unreadable)
        }

        if let existing = try? existingBook(withHash: hash) {
            return .duplicate(title: existing.title)
        }

        let metadata: BookMetadata
        do {
            metadata = try reader.readMetadata(from: url)
        } catch MetadataError.drmProtected {
            return .failed(fileName: fileName, reason: .drmProtected)
        } catch {
            return .failed(fileName: fileName, reason: .unreadable)
        }

        let id = UUID()
        let relativePath = "\(id.uuidString).\(format.fileExtensions[0])"
        let destination = booksFolder.appending(path: relativePath)
        do {
            try FileManager.default.createDirectory(at: booksFolder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            return .failed(fileName: fileName, reason: .copyFailed)
        }

        let book = Book(
            id: id,
            relativeFilePath: relativePath,
            contentHash: hash,
            format: format,
            title: "",
            shelfOrder: nextShelfOrder()
        )
        book.apply(metadata, fileURL: url)
        modelContext.insert(book)
        do {
            try modelContext.save()
        } catch {
            modelContext.delete(book)
            try? FileManager.default.removeItem(at: destination)
            return .failed(fileName: fileName, reason: .copyFailed)
        }
        return .imported(book.persistentModelID, title: book.title)
    }

    // MARK: - Helpers

    private func existingBook(withHash hash: String) throws -> Book? {
        var descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.contentHash == hash })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func nextShelfOrder() -> Int {
        var descriptor = FetchDescriptor<Book>(sortBy: [SortDescriptor(\.shelfOrder, order: .reverse)])
        descriptor.fetchLimit = 1
        let last = (try? modelContext.fetch(descriptor).first?.shelfOrder) ?? -1
        return last + 1
    }

    /// SHA-256 of a file, read in 1 MB chunks so large PDFs don't load into memory.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
