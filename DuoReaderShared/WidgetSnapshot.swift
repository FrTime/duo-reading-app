import Foundation

// Compiled into both the app and the widget extension. The extension never
// opens the SwiftData store: the app writes this snapshot, plus small cover
// and spine images, into the App Group and asks WidgetKit to reload.

/// What the widgets show, written by the app whenever the library changes.
struct WidgetSnapshot: Codable, Sendable, Equatable {
    static let currentVersion = 1

    var version: Int = currentVersion
    var generatedAt: Date
    /// How the app's shelf stands its books.
    var shelfStyle: ShelfStyle
    /// Every book in the library, including ones past `books`.
    var totalBookCount: Int
    /// Books in shelf order, capped at `WidgetSnapshot.maxShelfBooks`.
    var books: [Book]
    /// The book to resume, which may sit past the cap in shelf order.
    var current: Book?

    /// More than the large widget can ever show, so the shelf always fills.
    static let maxShelfBooks = 120

    enum ShelfStyle: String, Codable, Sendable {
        case spines
        case covers

        /// Reads the app's `shelf.displayMode` setting. Spines are the default.
        init(storedValue: String?) {
            self = storedValue.flatMap(ShelfStyle.init(rawValue:)) ?? .spines
        }
    }

    struct Book: Codable, Sendable, Equatable, Identifiable {
        var id: UUID
        var title: String
        var author: String
        /// 0 to 1.
        var progress: Double
        /// Spine width as a fraction of the cover's width.
        var thickness: Double
        var baseColor: Color
        var spineColor: Color
        var lastOpened: Date?

        var percent: Int { Int((min(max(progress, 0), 1) * 100).rounded(.down)) }
        var isFinished: Bool { progress >= Self.finishedThreshold }

        /// Readers rarely land on exactly 100%, so the last half percent counts as done.
        static let finishedThreshold = 0.995
    }

    /// An sRGB colour, 0 to 1.
    struct Color: Codable, Sendable, Equatable {
        var red: Double
        var green: Double
        var blue: Double

        /// Whether white text reads better than black on this colour.
        var prefersLightText: Bool {
            0.2126 * red + 0.7152 * green + 0.0722 * blue < 0.55
        }
    }

    /// The book to resume: the most recently opened unfinished one, else the
    /// most recently opened one. Nil when nothing has been opened.
    static func pickCurrent(from books: [Book]) -> Book? {
        let opened = books.filter { $0.lastOpened != nil }
            .sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
        return opened.first { !$0.isFinished } ?? opened.first
    }

    /// Equal apart from when it was written.
    func hasSameContent(as other: WidgetSnapshot?) -> Bool {
        guard var other else { return false }
        other.generatedAt = generatedAt
        return self == other
    }
}

/// Where the snapshot and its images live in the App Group container.
struct WidgetStore: Sendable {
    static let appGroupID = "group.com.timothymace.duoreader"

    /// The images kept for each book.
    enum ImageKind: String, CaseIterable, Sendable {
        /// Small front, for face-out books on the shelf widget.
        case front
        /// The spine, for spine-out books on the shelf widget.
        case spine
        /// Larger front, only for the book being read.
        case cover

        /// Longest side in pixels. Widgets are drawn at 3x and the extension
        /// has a tight memory limit, so these are as small as looks sharp.
        var maxPixels: Int {
            switch self {
            case .front: 330
            case .spine: 330
            case .cover: 600
            }
        }
    }

    let root: URL

    init(root: URL) {
        self.root = root
    }

    /// The shared store, or nil if the App Group isn't available (a build
    /// without the entitlement).
    static func shared() -> WidgetStore? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
            .map { WidgetStore(root: $0.appending(path: "Widgets", directoryHint: .isDirectory)) }
    }

    var snapshotURL: URL { root.appending(path: "snapshot.json", directoryHint: .notDirectory) }
    var imagesFolder: URL { root.appending(path: "Images", directoryHint: .isDirectory) }

    func imageURL(_ kind: ImageKind, for bookID: UUID) -> URL {
        imagesFolder.appending(path: "\(bookID.uuidString)-\(kind.rawValue).jpg", directoryHint: .notDirectory)
    }

    func load() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? Self.decoder.decode(WidgetSnapshot.self, from: data),
              snapshot.version == WidgetSnapshot.currentVersion else { return nil }
        return snapshot
    }

    func save(_ snapshot: WidgetSnapshot) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(snapshot)
        // Readable after first unlock, so lock screen widgets can still reload.
        try data.write(to: snapshotURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Links from a widget back into the app.
enum WidgetLink {
    static let scheme = "duoreader"

    /// Opens a book where it was left.
    static func url(forBook id: UUID) -> URL {
        URL(string: "\(scheme)://book/\(id.uuidString)")!
    }

    /// Opens the library.
    static let library = URL(string: "\(scheme)://library")!

    static func isWidgetLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme
    }

    /// The book a link opens, if it's a book link.
    static func bookID(from url: URL) -> UUID? {
        guard isWidgetLink(url), url.host()?.lowercased() == "book" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 1 else { return nil }
        return UUID(uuidString: parts[0])
    }
}

/// Fits books onto the shelf widget's rows, in order, left to right.
/// Pure maths so it's unit-tested; sizes are in points.
struct WidgetShelfLayout: Equatable, Sendable {
    struct Placed: Equatable, Sendable, Identifiable {
        var book: WidgetSnapshot.Book
        var width: Double
        var id: UUID { book.id }
    }

    var rows: [[Placed]]
    /// Books that didn't fit, shown as "+N".
    var overflow: Int

    static let spacing = 1.5
    /// Thinner spines than this can't be tapped or told apart.
    static let minimumSpineWidth = 9.0
    /// Room kept at the end of the last row for the "+N" badge.
    static let overflowBadgeWidth = 34.0

    init(rows: [[Placed]], overflow: Int) {
        self.rows = rows
        self.overflow = overflow
    }

    init(books: [WidgetSnapshot.Book], totalCount: Int, style: WidgetSnapshot.ShelfStyle,
         rowCount: Int, rowWidth: Double, bookHeight: Double) {
        let total = max(totalCount, books.count)
        var rows = Self.fit(books, style: style, rowCount: rowCount, rowWidth: rowWidth,
                            lastRowWidth: rowWidth, bookHeight: bookHeight)
        if rows.joined().count < total {
            // Make room for the badge and fit again.
            rows = Self.fit(books, style: style, rowCount: rowCount, rowWidth: rowWidth,
                            lastRowWidth: rowWidth - Self.overflowBadgeWidth, bookHeight: bookHeight)
        }
        self.init(rows: rows, overflow: total - rows.joined().count)
    }

    static func width(of book: WidgetSnapshot.Book, style: WidgetSnapshot.ShelfStyle, bookHeight: Double) -> Double {
        let coverWidth = bookHeight * 2 / 3
        switch style {
        case .covers: return coverWidth
        case .spines: return max(coverWidth * book.thickness, minimumSpineWidth)
        }
    }

    private static func fit(_ books: [WidgetSnapshot.Book], style: WidgetSnapshot.ShelfStyle, rowCount: Int,
                            rowWidth: Double, lastRowWidth: Double, bookHeight: Double) -> [[Placed]] {
        var rows: [[Placed]] = Array(repeating: [], count: max(rowCount, 1))
        var row = 0
        var used = 0.0
        for book in books {
            let width = width(of: book, style: style, bookHeight: bookHeight)
            while row < rows.count {
                let limit = row == rows.count - 1 ? lastRowWidth : rowWidth
                let needed = used == 0 ? width : used + spacing + width
                if needed <= limit + 0.0001 {
                    rows[row].append(Placed(book: book, width: width))
                    used = needed
                    break
                }
                row += 1
                used = 0
            }
            if row >= rows.count { break }
        }
        return rows
    }
}
