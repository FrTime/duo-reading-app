import Foundation
import UIKit

// MARK: - Query

/// What we search the cover services for: a title, an author and an ISBN,
/// built from the book's metadata or, failing that, its file name.
public struct CoverSearchQuery: Equatable, Sendable {
    public var title: String
    public var author: String?
    /// Digits only, with a trailing "X" allowed for ISBN-10.
    public var isbn: String?

    public init(title: String, author: String? = nil, isbn: String? = nil) {
        self.title = title
        self.author = author
        self.isbn = isbn
    }

    /// True when there is nothing to search for.
    public var isEmpty: Bool {
        title.isEmpty && isbn == nil
    }

    /// Builds a query from what we know about a book. The metadata title wins;
    /// otherwise the file name is cleaned up, and "Title - Author" or
    /// "Title by Author" is split when there is no author metadata.
    public static func make(title: String?, authors: [String], identifiers: [String], fileName: String?) -> CoverSearchQuery {
        let metadataAuthor = authors.lazy.compactMap { nonBlank(collapsingWhitespace($0)) }.first
        let isbn = identifiers.lazy.compactMap { normalizedISBN($0) }.first

        if let metadataTitle = nonBlank(collapsingWhitespace(title ?? "")) {
            return CoverSearchQuery(title: metadataTitle, author: metadataAuthor, isbn: isbn)
        }

        let parsed = parseFileName(fileName ?? "")
        var cleanTitle = parsed.title
        var author = metadataAuthor
        if let suffix = parsed.author {
            if let metadataAuthor {
                // Keep the suffix as part of the title unless it is just the author again.
                if suffix.caseInsensitiveCompare(metadataAuthor) != .orderedSame {
                    cleanTitle = parsed.unsplit
                }
            } else {
                author = suffix
            }
        }
        return CoverSearchQuery(title: cleanTitle, author: author, isbn: isbn)
    }

    /// Splits a file name into a cleaned title and, when it looks like
    /// "Title - Author" or "Title by Author", an author. `unsplit` is the
    /// cleaned name before splitting.
    static func parseFileName(_ fileName: String) -> (title: String, author: String?, unsplit: String) {
        var name = fileName
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }

        // Drop a short extension such as ".epub" or ".pdf".
        if let dot = name.lastIndex(of: ".") {
            let ext = name[name.index(after: dot)...]
            if (1...5).contains(ext.count), ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                name = String(name[..<dot])
            }
        }

        name = name.replacingOccurrences(of: "_", with: " ")
        // "(z-lib.org)", "[AO3]", "(1)", "{v2}" and the like.
        name = name.replacingOccurrences(
            of: #"\[[^\]]*\]|\([^)]*\)|\{[^}]*\}"#,
            with: " ",
            options: .regularExpression
        )
        // Names like "my-fic-title" or "Some.Book.Title" use dots or hyphens as spaces.
        if !name.contains(" ") {
            name = name
                .replacingOccurrences(of: ".", with: " ")
                .replacingOccurrences(of: "-", with: " ")
        }
        // Dashes between words, and runs of hyphens, become one separator.
        name = name.replacingOccurrences(
            of: #"\s+[-–—]+\s+|\s*-{2,}\s*"#,
            with: " - ",
            options: .regularExpression
        )
        let unsplit = tidy(name)

        for separator in [" - ", " by "] {
            guard let range = unsplit.range(of: separator, options: [.backwards, .caseInsensitive]) else { continue }
            let title = tidy(String(unsplit[..<range.lowerBound]))
            let author = tidy(String(unsplit[range.upperBound...]))
            let authorWords = author.split(separator: " ").count
            if !title.isEmpty, (1...5).contains(authorWords) {
                return (title, author, unsplit)
            }
        }
        return (unsplit, nil, unsplit)
    }

    /// The ISBN in an identifier such as "urn:isbn:978-0-…", "ISBN: 0-…" or a
    /// bare 10 or 13 digit number, as digits only. Nil when the checksum fails.
    static func normalizedISBN(_ identifier: String) -> String? {
        var value = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("urn:isbn:") {
            value = String(value.dropFirst("urn:isbn:".count))
        } else if value.hasPrefix("isbn") {
            value = String(value.dropFirst("isbn".count))
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: ":- ").union(.whitespaces))
        }
        let characters = value.filter { $0 != "-" && $0 != " " }.uppercased()

        switch characters.count {
        case 10:
            var sum = 0
            for (index, character) in characters.enumerated() {
                let digit: Int
                if let number = character.wholeNumberValue, character.isASCII {
                    digit = number
                } else if character == "X", index == 9 {
                    digit = 10
                } else {
                    return nil
                }
                sum += (10 - index) * digit
            }
            return sum % 11 == 0 ? characters : nil
        case 13:
            var sum = 0
            for (index, character) in characters.enumerated() {
                guard character.isASCII, let digit = character.wholeNumberValue else { return nil }
                sum += digit * (index.isMultiple(of: 2) ? 1 : 3)
            }
            return sum % 10 == 0 ? characters : nil
        default:
            return nil
        }
    }

    private static func tidy(_ value: String) -> String {
        collapsingWhitespace(value)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-–—,;:").union(.whitespacesAndNewlines))
    }
}

private func collapsingWhitespace(_ value: String) -> String {
    value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func nonBlank(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

// MARK: - Results

/// A service we search for cover images.
public enum CoverSearchProvider: String, Sendable, CaseIterable {
    case openLibrary
    case googleBooks

    public var displayName: String {
        switch self {
        case .openLibrary: String(localized: "Open Library")
        case .googleBooks: String(localized: "Google Books")
        }
    }
}

/// One cover image a service offered.
public struct CoverSearchResult: Identifiable, Hashable, Sendable {
    public var id: String
    public var provider: CoverSearchProvider
    public var title: String
    public var authors: [String]
    public var year: Int?
    /// A small image for the results grid.
    public var thumbnailURL: URL
    /// The largest image the service offers, downloaded when the user picks it.
    public var imageURL: URL

    public init(
        id: String? = nil,
        provider: CoverSearchProvider,
        title: String,
        authors: [String] = [],
        year: Int? = nil,
        thumbnailURL: URL,
        imageURL: URL
    ) {
        self.id = id ?? "\(provider.rawValue):\(imageURL.absoluteString)"
        self.provider = provider
        self.title = title
        self.authors = authors
        self.year = year
        self.thumbnailURL = thumbnailURL
        self.imageURL = imageURL
    }
}

/// What a search found, and which services couldn't be reached.
public struct CoverSearchOutcome: Sendable {
    public var results: [CoverSearchResult]
    public var failedProviders: [CoverSearchProvider]

    public init(results: [CoverSearchResult], failedProviders: [CoverSearchProvider]) {
        self.results = results
        self.failedProviders = failedProviders
    }
}

public enum CoverSearchError: Error, Equatable {
    /// The server answered with something other than 200 OK (0 when the
    /// response wasn't HTTP at all).
    case badResponse(Int)
    /// The download isn't an image, or is a tiny placeholder.
    case notAnImage
    case tooLarge
    /// Only HTTPS downloads are allowed.
    case insecureURL
}

// MARK: - Loading

/// Fetches the bytes at a URL. A protocol so tests can supply canned responses.
public protocol HTTPDataLoading: Sendable {
    func data(from url: URL) async throws -> (Data, URLResponse)
}

/// Loads over a URLSession that keeps no cookies or cache and sends only a
/// generic User-Agent.
public struct URLSessionLoader: HTTPDataLoading {
    static let userAgent = "DuoReader/1.0 (iOS; cover search)"

    private static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpAdditionalHeaders = ["User-Agent": URLSessionLoader.userAgent]
        return URLSession(configuration: configuration)
    }()

    private let session: URLSession

    public init() {
        self.session = Self.defaultSession
    }

    public init(session: URLSession) {
        self.session = session
    }

    public func data(from url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return try await session.data(for: request)
    }
}

// MARK: - Service

/// Searches Open Library and Google Books for cover images.
///
/// Privacy: this only runs when the user starts a cover search, and sends
/// nothing but the title, author and ISBN. No API keys, accounts, cookies or
/// device details are involved.
public struct CoverSearchService: Sendable {
    /// Most results a search returns.
    public static let maxResults = 40
    /// Largest search response we decode.
    static let maxResponseBytes = 5 * 1024 * 1024
    /// Largest cover image we download.
    static let maxImageBytes = 10 * 1024 * 1024
    /// Images smaller than this on either side are placeholders, not covers.
    static let minimumImageSide: CGFloat = 50

    private let loader: any HTTPDataLoading

    public init(loader: any HTTPDataLoading = URLSessionLoader()) {
        self.loader = loader
    }

    /// Queries every provider at once. A provider that fails is listed in
    /// `failedProviders` and the others' results are still returned.
    public func search(_ query: CoverSearchQuery) async -> CoverSearchOutcome {
        guard !query.isEmpty else {
            return CoverSearchOutcome(results: [], failedProviders: [])
        }
        async let openLibrary = results(from: .openLibrary, for: query)
        async let googleBooks = results(from: .googleBooks, for: query)
        let openLibraryResults = await openLibrary
        let googleBooksResults = await googleBooks

        var lists: [[CoverSearchResult]] = []
        var failed: [CoverSearchProvider] = []
        let fetched: [(CoverSearchProvider, [CoverSearchResult]?)] = [
            (.openLibrary, openLibraryResults),
            (.googleBooks, googleBooksResults),
        ]
        for (provider, list) in fetched {
            if let list {
                lists.append(list)
            } else {
                failed.append(provider)
            }
        }
        return CoverSearchOutcome(results: Self.merge(lists), failedProviders: failed)
    }

    /// One provider's results, or nil when it failed.
    private func results(from provider: CoverSearchProvider, for query: CoverSearchQuery) async -> [CoverSearchResult]? {
        guard let url = Self.searchURL(for: provider, query: query) else { return nil }
        do {
            let data = try await Self.load(url, loader: loader, maxBytes: Self.maxResponseBytes)
            switch provider {
            case .openLibrary:
                let parsed = try Self.parseOpenLibrary(data)
                if let isbn = query.isbn, let direct = Self.openLibraryISBNCandidate(isbn, query: query) {
                    return [direct] + parsed
                }
                return parsed
            case .googleBooks:
                return try Self.parseGoogleBooks(data)
            }
        } catch {
            return nil
        }
    }

    /// Takes one result from each provider in turn, drops repeated images and
    /// stops at `limit`.
    static func merge(_ lists: [[CoverSearchResult]], limit: Int = CoverSearchService.maxResults) -> [CoverSearchResult] {
        var merged: [CoverSearchResult] = []
        var seen = Set<URL>()
        let longest = lists.map { $0.count }.max() ?? 0
        for index in 0..<longest {
            for list in lists where index < list.count {
                guard merged.count < limit else { return merged }
                let result = list[index]
                if seen.insert(result.imageURL).inserted {
                    merged.append(result)
                }
            }
        }
        return merged
    }

    /// Fetches a URL and checks for 200 OK and a sensible size.
    private static func load(_ url: URL, loader: any HTTPDataLoading, maxBytes: Int) async throws -> Data {
        let (data, response) = try await loader.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw CoverSearchError.badResponse(0)
        }
        guard http.statusCode == 200 else {
            throw CoverSearchError.badResponse(http.statusCode)
        }
        guard data.count <= maxBytes else {
            throw CoverSearchError.tooLarge
        }
        return data
    }

    // MARK: Image download

    /// Downloads a chosen cover. Rejects non-HTTPS URLs, anything that isn't
    /// an image, files over 10 MB and the tiny placeholders some services
    /// return when they have no cover.
    public static func downloadImage(_ url: URL, loader: any HTTPDataLoading = URLSessionLoader()) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else {
            throw CoverSearchError.insecureURL
        }
        let (data, response) = try await loader.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw CoverSearchError.badResponse(0)
        }
        guard http.statusCode == 200 else {
            throw CoverSearchError.badResponse(http.statusCode)
        }
        guard let mimeType = http.mimeType?.lowercased(), mimeType.hasPrefix("image/") else {
            throw CoverSearchError.notAnImage
        }
        guard data.count <= maxImageBytes else {
            throw CoverSearchError.tooLarge
        }
        guard let image = UIImage(data: data) else {
            throw CoverSearchError.notAnImage
        }
        let width = image.size.width * image.scale
        let height = image.size.height * image.scale
        guard width >= minimumImageSide, height >= minimumImageSide else {
            throw CoverSearchError.notAnImage
        }
        return data
    }

    // MARK: Request URLs

    static func searchURL(for provider: CoverSearchProvider, query: CoverSearchQuery) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        var items: [URLQueryItem] = []

        switch provider {
        case .openLibrary:
            components.host = "openlibrary.org"
            components.path = "/search.json"
            if let isbn = query.isbn {
                items.append(queryItem("isbn", isbn))
            } else {
                items.append(queryItem("title", query.title))
                if let author = query.author {
                    items.append(queryItem("author", author))
                }
            }
            items.append(queryItem("limit", "20"))
            items.append(queryItem("fields", "key,title,author_name,first_publish_year,cover_i,isbn"))
        case .googleBooks:
            components.host = "www.googleapis.com"
            components.path = "/books/v1/volumes"
            let search: String
            if let isbn = query.isbn {
                search = "isbn:\(isbn)"
            } else {
                var terms = ["intitle:\"\(withoutQuotes(query.title))\""]
                if let author = query.author {
                    terms.append("inauthor:\"\(withoutQuotes(author))\"")
                }
                search = terms.joined(separator: " ")
            }
            items.append(queryItem("q", search))
            items.append(queryItem("maxResults", "20"))
            items.append(queryItem("printType", "books"))
        }

        components.percentEncodedQueryItems = items
        return components.url
    }

    /// A query item whose value is percent-encoded strictly, so "&", "+" and
    /// "=" in a title can't break the query.
    private static func queryItem(_ name: String, _ value: String) -> URLQueryItem {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URLQueryItem(name: name, value: encoded)
    }

    private static func withoutQuotes(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "")
    }

    // MARK: Open Library

    private struct OpenLibraryResponse: Decodable {
        var docs: [Doc]?

        struct Doc: Decodable {
            var title: String?
            var authorName: [String]?
            var firstPublishYear: Int?
            var coverID: Int?

            enum CodingKeys: String, CodingKey {
                case title
                case authorName = "author_name"
                case firstPublishYear = "first_publish_year"
                case coverID = "cover_i"
            }
        }
    }

    /// Results from an Open Library search response. Works without a cover are skipped.
    static func parseOpenLibrary(_ data: Data) throws -> [CoverSearchResult] {
        let response = try JSONDecoder().decode(OpenLibraryResponse.self, from: data)
        return (response.docs ?? []).compactMap { (doc) -> CoverSearchResult? in
            guard let coverID = doc.coverID, coverID > 0,
                  let thumbnail = URL(string: "https://covers.openlibrary.org/b/id/\(coverID)-M.jpg"),
                  let image = URL(string: "https://covers.openlibrary.org/b/id/\(coverID)-L.jpg")
            else { return nil }
            return CoverSearchResult(
                provider: .openLibrary,
                title: doc.title ?? "",
                authors: doc.authorName ?? [],
                year: doc.firstPublishYear,
                thumbnailURL: thumbnail,
                imageURL: image
            )
        }
    }

    /// Open Library's cover for an ISBN, asked for directly. `default=false`
    /// makes it answer 404 rather than a placeholder when it has none.
    static func openLibraryISBNCandidate(_ isbn: String, query: CoverSearchQuery) -> CoverSearchResult? {
        guard isbn.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "X") }),
              let thumbnail = URL(string: "https://covers.openlibrary.org/b/isbn/\(isbn)-M.jpg?default=false"),
              let image = URL(string: "https://covers.openlibrary.org/b/isbn/\(isbn)-L.jpg?default=false")
        else { return nil }
        return CoverSearchResult(
            provider: .openLibrary,
            title: query.title,
            authors: query.author.map { [$0] } ?? [],
            thumbnailURL: thumbnail,
            imageURL: image
        )
    }

    // MARK: Google Books

    private struct GoogleBooksResponse: Decodable {
        var items: [Item]?

        struct Item: Decodable {
            var volumeInfo: VolumeInfo?
        }

        struct VolumeInfo: Decodable {
            var title: String?
            var authors: [String]?
            var publishedDate: String?
            var imageLinks: ImageLinks?
        }

        struct ImageLinks: Decodable {
            var smallThumbnail: String?
            var thumbnail: String?
        }
    }

    /// Results from a Google Books volumes response. Volumes without images are skipped.
    static func parseGoogleBooks(_ data: Data) throws -> [CoverSearchResult] {
        let response = try JSONDecoder().decode(GoogleBooksResponse.self, from: data)
        return (response.items ?? []).compactMap { (item) -> CoverSearchResult? in
            guard let info = item.volumeInfo,
                  let links = info.imageLinks,
                  let large = links.thumbnail ?? links.smallThumbnail,
                  let image = googleImageURL(large, zoom: "1"),
                  let thumbnail = googleImageURL(links.smallThumbnail ?? large, zoom: nil)
            else { return nil }
            let year = info.publishedDate.flatMap { Int(String($0.prefix(4))) }
            return CoverSearchResult(
                provider: .googleBooks,
                title: info.title ?? "",
                authors: info.authors ?? [],
                year: year,
                thumbnailURL: thumbnail,
                imageURL: image
            )
        }
    }

    /// Upgrades a Google Books image link to HTTPS, drops the page-curl
    /// effect and, when given, sets the zoom level.
    static func googleImageURL(_ string: String, zoom: String?) -> URL? {
        guard var components = URLComponents(string: string) else { return nil }
        switch components.scheme?.lowercased() {
        case "https": break
        case "http": components.scheme = "https"
        default: return nil
        }
        var items = (components.percentEncodedQueryItems ?? []).filter { $0.name != "edge" }
        if let zoom {
            if let index = items.firstIndex(where: { $0.name == "zoom" }) {
                items[index].value = zoom
            } else {
                items.append(URLQueryItem(name: "zoom", value: zoom))
            }
        }
        components.percentEncodedQueryItems = items.isEmpty ? nil : items
        return components.url
    }
}
