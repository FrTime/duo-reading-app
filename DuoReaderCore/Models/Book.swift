import Foundation
import SwiftData

extension DuoReaderSchemaV1 {
    /// A book in the library: one imported file plus everything we know about it.
    ///
    /// The file is copied into the app's container on import and referenced by
    /// a path relative to the library folder, so the app never depends on a
    /// security-scoped bookmark to a file it doesn't own.
    @Model
    public final class Book {
        @Attribute(.unique) public var id: UUID
        /// Path of the imported file relative to the library folder.
        public var relativeFilePath: String
        /// SHA-256 of the original file, used to spot duplicate imports.
        public var contentHash: String
        public var formatRawValue: String

        public var title: String
        public var authors: [String]
        public var series: String?
        public var seriesIndex: Double?
        public var language: String?
        public var publisher: String?
        public var summary: String?
        /// Subjects from the file's metadata, e.g. AO3 fandoms and tags.
        public var subjects: [String]

        public var dateAdded: Date
        public var lastOpened: Date?
        /// Reading progress from 0 to 1.
        public var progress: Double
        /// Position on the shelf. Lower comes first.
        public var shelfOrder: Int

        public var format: BookFormat {
            get { BookFormat(rawValue: formatRawValue) ?? .epub }
            set { formatRawValue = newValue.rawValue }
        }

        public init(
            id: UUID = UUID(),
            relativeFilePath: String,
            contentHash: String,
            format: BookFormat,
            title: String,
            authors: [String] = [],
            subjects: [String] = [],
            dateAdded: Date = .now,
            shelfOrder: Int = 0
        ) {
            self.id = id
            self.relativeFilePath = relativeFilePath
            self.contentHash = contentHash
            self.formatRawValue = format.rawValue
            self.title = title
            self.authors = authors
            self.subjects = subjects
            self.dateAdded = dateAdded
            self.progress = 0
            self.shelfOrder = shelfOrder
        }

        /// Title and authors for display, e.g. "Title — A, B".
        public var displayAuthors: String {
            authors.isEmpty ? String(localized: "Unknown author") : authors.formatted(.list(type: .and))
        }
    }
}

/// The current version of `Book`. Views and services use this name, never the
/// versioned one, so a schema bump only touches `DuoReaderSchema.swift`.
public typealias Book = DuoReaderSchemaV1.Book
