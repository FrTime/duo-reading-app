import Foundation
import SwiftData

/// Changes to the library that touch both the store and the files on disk.
@MainActor
public enum LibraryActions {
    /// Called with the book's id after it's deleted, so other features
    /// (cover designs, bookmarks) can clean up their own files.
    public static var onDelete: [(UUID) -> Void] = []

    /// Deletes the book, its file and anything registered in `onDelete`.
    public static func delete(
        _ book: Book,
        in context: ModelContext,
        booksFolder: URL = LibraryImporter.defaultBooksFolder
    ) throws {
        let id = book.id
        let file = booksFolder.appending(path: book.relativeFilePath)
        context.delete(book)
        try context.save()
        // The row is gone; a leftover file is harmless but wasteful, so don't fail on it.
        try? FileManager.default.removeItem(at: file)
        for handler in onDelete { handler(id) }
    }

    /// The file for a book in the library folder.
    public static func fileURL(for book: Book, booksFolder: URL = LibraryImporter.defaultBooksFolder) -> URL {
        booksFolder.appending(path: book.relativeFilePath)
    }
}
