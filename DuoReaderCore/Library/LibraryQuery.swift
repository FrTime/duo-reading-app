import Foundation

/// How the library is ordered.
public enum LibrarySort: String, CaseIterable, Identifiable, Sendable {
    /// The user's own order, shared with the 3D shelf.
    case shelf
    case title
    case author
    case recentlyAdded
    case recentlyOpened

    public var id: String { rawValue }
}

/// Filtering and sorting for the library, kept free of SwiftUI so it's easy to test.
public enum LibraryQuery {
    /// Books whose title, authors, series, subjects or AO3 tags contain every
    /// word of `searchText`, ignoring case and accents. Empty text matches all.
    public static func filter(_ books: [Book], matching searchText: String) -> [Book] {
        let terms = searchText
            .split(whereSeparator: \.isWhitespace)
            .map { normalize(String($0)) }
        guard !terms.isEmpty else { return books }
        return books.filter { book in
            let haystack = normalize(searchableText(for: book))
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    public static func sort(_ books: [Book], by sort: LibrarySort) -> [Book] {
        switch sort {
        case .shelf:
            return books.sorted { $0.shelfOrder < $1.shelfOrder }
        case .title:
            return books.sorted { sortKey(forTitle: $0.title).localizedStandardCompare(sortKey(forTitle: $1.title)) == .orderedAscending }
        case .author:
            // By first author, then title. Books with no author go last.
            return books.sorted { a, b in
                switch (a.authors.first, b.authors.first) {
                case let (x?, y?):
                    let order = x.localizedStandardCompare(y)
                    if order != .orderedSame { return order == .orderedAscending }
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): break
                }
                return sortKey(forTitle: a.title).localizedStandardCompare(sortKey(forTitle: b.title)) == .orderedAscending
            }
        case .recentlyAdded:
            return books.sorted { $0.dateAdded > $1.dateAdded }
        case .recentlyOpened:
            // Opened books first, newest first; never-opened books after, newest added first.
            return books.sorted { a, b in
                switch (a.lastOpened, b.lastOpened) {
                case let (x?, y?): return x > y
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return a.dateAdded > b.dateAdded
                }
            }
        }
    }

    /// Puts the shelf itself in `sort` order by renumbering `shelfOrder`, so
    /// the 3D shelf (which always shows the user's own arrangement) and
    /// "My Order" follow. Returns whether any book moved.
    @discardableResult
    public static func arrangeShelf(_ books: [Book], by sort: LibrarySort) -> Bool {
        var moved = false
        for (position, book) in self.sort(books, by: sort).enumerated() where book.shelfOrder != position {
            book.shelfOrder = position
            moved = true
        }
        return moved
    }

    /// "The Hobbit" sorts under H, as in a bookshop.
    static func sortKey(forTitle title: String) -> String {
        for article in ["the ", "a ", "an "] where title.lowercased().hasPrefix(article) && title.count > article.count {
            return String(title.dropFirst(article.count))
        }
        return title
    }

    static func searchableText(for book: Book) -> String {
        var parts = [book.title, book.series ?? ""] + book.authors + book.subjects
        if let ao3 = book.ao3 {
            parts += ao3.fandoms + ao3.relationships + ao3.characters + ao3.additionalTags
        }
        return parts.joined(separator: "\n")
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
