import Foundation
import Testing
import UIKit
@testable import DuoReader

/// Answers requests from canned responses keyed by host. Hosts with no
/// response fail as if the server were unreachable.
private struct CannedLoader: HTTPDataLoading {
    struct Canned: Sendable {
        var status: Int = 200
        var contentType: String = "application/json"
        var body: Data
    }

    var routes: [String: Canned]

    func data(from url: URL) async throws -> (Data, URLResponse) {
        guard let host = url.host(), let canned = routes[host] else {
            throw URLError(.cannotConnectToHost)
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: canned.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": canned.contentType]
        )!
        return (canned.body, response)
    }
}

private let openLibraryHost = "openlibrary.org"
private let googleBooksHost = "www.googleapis.com"

private let openLibraryJSON = """
{
  "numFound": 3,
  "docs": [
    {"key": "/works/OL1W", "title": "First", "author_name": ["Ann Author"], "first_publish_year": 1999, "cover_i": 123},
    {"key": "/works/OL2W", "title": "No Cover", "author_name": ["Nobody"]},
    {"key": "/works/OL3W", "title": "Second", "cover_i": 456}
  ]
}
"""

private let googleBooksJSON = """
{
  "kind": "books#volumes",
  "items": [
    {"id": "abc", "volumeInfo": {
      "title": "G One", "authors": ["Bea Writer"], "publishedDate": "2004-05-01",
      "imageLinks": {
        "smallThumbnail": "http://books.google.com/books/content?id=abc&printsec=frontcover&img=1&zoom=5&edge=curl&source=gbs_api",
        "thumbnail": "http://books.google.com/books/content?id=abc&printsec=frontcover&img=1&zoom=1&edge=curl&source=gbs_api"
      }
    }},
    {"id": "none", "volumeInfo": {"title": "No Image"}},
    {"id": "def", "volumeInfo": {
      "title": "G Two", "publishedDate": "2010",
      "imageLinks": {"thumbnail": "https://books.google.com/books/content?id=def&img=1&zoom=1"}
    }}
  ]
}
"""

struct CoverSearchQueryTests {
    @Test func metadataWins() {
        let query = CoverSearchQuery.make(
            title: "  The Real   Title ",
            authors: ["", "Jane Doe"],
            identifiers: [],
            fileName: "Something_Else - Other Person.epub"
        )
        #expect(query == CoverSearchQuery(title: "The Real Title", author: "Jane Doe", isbn: nil))
    }

    @Test(arguments: [
        ("My_Fic_Title.epub", "My Fic Title", nil),
        ("Title - Author Name.epub", "Title", "Author Name"),
        ("Some Book (z-lib.org).pdf", "Some Book", nil),
        ("Work [AO3] (1).epub", "Work", nil),
        ("my-fic-title.epub", "my fic title", nil),
        ("Some.Dotted.Name.pdf", "Some Dotted Name", nil),
        ("The Hobbit by J.R.R. Tolkien.epub", "The Hobbit", "J.R.R. Tolkien"),
        ("Title -- Writer.epub", "Title", "Writer"),
        ("/var/mobile/Inbox/Spider-Man Stories.epub", "Spider-Man Stories", nil),
    ] as [(String, String, String?)])
    func cleansFileNames(fileName: String, title: String, author: String?) {
        let query = CoverSearchQuery.make(title: nil, authors: [], identifiers: [], fileName: fileName)
        #expect(query.title == title)
        #expect(query.author == author)
    }

    @Test func fileNameAuthorSuffixIsDroppedWhenItMatchesMetadata() {
        let query = CoverSearchQuery.make(title: nil, authors: ["author name"], identifiers: [], fileName: "Title - Author Name.epub")
        #expect(query.title == "Title")
        #expect(query.author == "author name")
    }

    @Test func fileNameSuffixIsKeptWhenMetadataNamesSomeoneElse() {
        let query = CoverSearchQuery.make(title: nil, authors: ["Someone Else"], identifiers: [], fileName: "Series - Book One.epub")
        #expect(query.title == "Series - Book One")
        #expect(query.author == "Someone Else")
    }

    @Test func emptyInputGivesEmptyQuery() {
        let query = CoverSearchQuery.make(title: "  ", authors: [], identifiers: ["urn:uuid:1234"], fileName: nil)
        #expect(query.isEmpty)
    }

    @Test func picksTheFirstValidISBN() {
        let query = CoverSearchQuery.make(
            title: "Book",
            authors: [],
            identifiers: ["urn:uuid:5f1c", "calibre:42", "urn:isbn:978-0-306-40615-7"],
            fileName: nil
        )
        #expect(query.isbn == "9780306406157")
        #expect(!query.isEmpty)
    }

    @Test(arguments: [
        ("9780306406157", "9780306406157"),
        ("978-0-306-40615-7", "9780306406157"),
        ("urn:isbn:9780306406157", "9780306406157"),
        ("URN:ISBN:0-306-40615-2", "0306406152"),
        ("isbn:0306406152", "0306406152"),
        ("ISBN 0-306-40615-2", "0306406152"),
        ("080442957X", "080442957X"),
        ("0-8044-2957-x", "080442957X"),
    ])
    func acceptsValidISBNs(input: String, expected: String) {
        #expect(CoverSearchQuery.normalizedISBN(input) == expected)
    }

    @Test(arguments: [
        "9780306406158",        // bad ISBN-13 checksum
        "0306406153",           // bad ISBN-10 checksum
        "X306406152",           // X only allowed last
        "978030640615X",        // no X in ISBN-13
        "12345",
        "urn:uuid:9780306406157",
        "",
    ])
    func rejectsInvalidISBNs(input: String) {
        #expect(CoverSearchQuery.normalizedISBN(input) == nil)
    }
}

struct CoverSearchParsingTests {
    @Test func parsesOpenLibrarySkippingMissingCovers() throws {
        let results = try CoverSearchService.parseOpenLibrary(Data(openLibraryJSON.utf8))
        #expect(results.count == 2)
        let first = try #require(results.first)
        #expect(first.provider == .openLibrary)
        #expect(first.title == "First")
        #expect(first.authors == ["Ann Author"])
        #expect(first.year == 1999)
        #expect(first.thumbnailURL.absoluteString == "https://covers.openlibrary.org/b/id/123-M.jpg")
        #expect(first.imageURL.absoluteString == "https://covers.openlibrary.org/b/id/123-L.jpg")
        #expect(results[1].authors.isEmpty)
        #expect(results[1].year == nil)
    }

    @Test func openLibraryWithNoDocsIsEmpty() throws {
        #expect(try CoverSearchService.parseOpenLibrary(Data(#"{"numFound": 0}"#.utf8)).isEmpty)
    }

    @Test func malformedJSONThrows() {
        #expect(throws: (any Error).self) {
            try CoverSearchService.parseOpenLibrary(Data("not json".utf8))
        }
        #expect(throws: (any Error).self) {
            try CoverSearchService.parseGoogleBooks(Data("[1, 2]".utf8))
        }
    }

    @Test func parsesGoogleBooksUpgradingToHTTPSAndDroppingCurl() throws {
        let results = try CoverSearchService.parseGoogleBooks(Data(googleBooksJSON.utf8))
        #expect(results.count == 2)
        let first = try #require(results.first)
        #expect(first.provider == .googleBooks)
        #expect(first.title == "G One")
        #expect(first.authors == ["Bea Writer"])
        #expect(first.year == 2004)
        #expect(first.imageURL.absoluteString == "https://books.google.com/books/content?id=abc&printsec=frontcover&img=1&zoom=1&source=gbs_api")
        #expect(first.thumbnailURL.absoluteString == "https://books.google.com/books/content?id=abc&printsec=frontcover&img=1&zoom=5&source=gbs_api")

        let second = results[1]
        #expect(second.year == 2010)
        #expect(second.thumbnailURL == second.imageURL)
        #expect(second.imageURL.absoluteString == "https://books.google.com/books/content?id=def&img=1&zoom=1")
    }

    @Test func googleImageURLAddsZoomAndRejectsOtherSchemes() {
        let url = CoverSearchService.googleImageURL("http://books.google.com/books/content?id=x", zoom: "1")
        #expect(url?.absoluteString == "https://books.google.com/books/content?id=x&zoom=1")
        #expect(CoverSearchService.googleImageURL("ftp://example.com/a.jpg", zoom: "1") == nil)
    }

    @Test func buildsOpenLibraryURLs() throws {
        let byTitle = try #require(CoverSearchService.searchURL(
            for: .openLibrary,
            query: CoverSearchQuery(title: "Pride & Prejudice", author: "Jane Austen")
        ))
        #expect(byTitle.host() == "openlibrary.org")
        #expect(byTitle.path() == "/search.json")
        let query = byTitle.query() ?? ""
        #expect(query.contains("title=Pride%20%26%20Prejudice"))
        #expect(query.contains("author=Jane%20Austen"))
        #expect(query.contains("limit=20"))

        let byISBN = try #require(CoverSearchService.searchURL(
            for: .openLibrary,
            query: CoverSearchQuery(title: "Pride", author: "Jane Austen", isbn: "9780306406157")
        ))
        let isbnQuery = byISBN.query() ?? ""
        #expect(isbnQuery.contains("isbn=9780306406157"))
        #expect(!isbnQuery.contains("title="))
    }

    @Test func buildsGoogleBooksURLs() throws {
        let byTitle = try #require(CoverSearchService.searchURL(
            for: .googleBooks,
            query: CoverSearchQuery(title: "My \"Book\"", author: "Jane Doe")
        ))
        #expect(byTitle.host() == "www.googleapis.com")
        let query = byTitle.query() ?? ""
        #expect(query.contains("q=intitle%3A%22My%20Book%22%20inauthor%3A%22Jane%20Doe%22"))
        #expect(query.contains("maxResults=20"))
        #expect(query.contains("printType=books"))
        #expect(!query.contains("key="))

        let byISBN = try #require(CoverSearchService.searchURL(
            for: .googleBooks,
            query: CoverSearchQuery(title: "My Book", isbn: "080442957X")
        ))
        #expect((byISBN.query() ?? "").contains("q=isbn%3A080442957X"))
    }
}

struct CoverSearchServiceTests {
    private func result(_ provider: CoverSearchProvider, _ number: Int) -> CoverSearchResult {
        let url = URL(string: "https://example.com/\(provider.rawValue)/\(number).jpg")!
        return CoverSearchResult(provider: provider, title: "\(number)", thumbnailURL: url, imageURL: url)
    }

    private var bothProviders: CannedLoader {
        CannedLoader(routes: [
            openLibraryHost: .init(body: Data(openLibraryJSON.utf8)),
            googleBooksHost: .init(body: Data(googleBooksJSON.utf8)),
        ])
    }

    @Test func interleavesProviders() async {
        let service = CoverSearchService(loader: bothProviders)
        let outcome = await service.search(CoverSearchQuery(title: "Anything"))
        #expect(outcome.failedProviders.isEmpty)
        #expect(outcome.results.map(\.title) == ["First", "G One", "Second", "G Two"])
        #expect(outcome.results.map(\.provider) == [.openLibrary, .googleBooks, .openLibrary, .googleBooks])
    }

    @Test func isbnAddsDirectOpenLibraryCandidateFirst() async throws {
        let service = CoverSearchService(loader: bothProviders)
        let outcome = await service.search(CoverSearchQuery(title: "Book", author: "Ann", isbn: "9780306406157"))
        let first = try #require(outcome.results.first)
        #expect(first.provider == .openLibrary)
        #expect(first.imageURL.absoluteString == "https://covers.openlibrary.org/b/isbn/9780306406157-L.jpg?default=false")
        #expect(first.thumbnailURL.absoluteString == "https://covers.openlibrary.org/b/isbn/9780306406157-M.jpg?default=false")
        #expect(outcome.results.count == 5)
    }

    @Test func oneProviderFailingKeepsTheOther() async {
        let loader = CannedLoader(routes: [googleBooksHost: .init(body: Data(googleBooksJSON.utf8))])
        let outcome = await CoverSearchService(loader: loader).search(CoverSearchQuery(title: "Anything"))
        #expect(outcome.failedProviders == [.openLibrary])
        #expect(outcome.results.map(\.title) == ["G One", "G Two"])
    }

    @Test func non200IsAFailure() async {
        let loader = CannedLoader(routes: [
            openLibraryHost: .init(body: Data(openLibraryJSON.utf8)),
            googleBooksHost: .init(status: 503, body: Data(googleBooksJSON.utf8)),
        ])
        let outcome = await CoverSearchService(loader: loader).search(CoverSearchQuery(title: "Anything"))
        #expect(outcome.failedProviders == [.googleBooks])
        #expect(outcome.results.map(\.title) == ["First", "Second"])
    }

    @Test func badJSONIsAFailure() async {
        let loader = CannedLoader(routes: [
            openLibraryHost: .init(body: Data("<html>".utf8)),
            googleBooksHost: .init(body: Data(googleBooksJSON.utf8)),
        ])
        let outcome = await CoverSearchService(loader: loader).search(CoverSearchQuery(title: "Anything"))
        #expect(outcome.failedProviders == [.openLibrary])
    }

    @Test func oversizedResponseIsAFailure() async {
        let huge = Data(count: CoverSearchService.maxResponseBytes + 1)
        let loader = CannedLoader(routes: [
            openLibraryHost: .init(body: huge),
            googleBooksHost: .init(body: Data(googleBooksJSON.utf8)),
        ])
        let outcome = await CoverSearchService(loader: loader).search(CoverSearchQuery(title: "Anything"))
        #expect(outcome.failedProviders == [.openLibrary])
        #expect(outcome.results.count == 2)
    }

    @Test func bothFailing() async {
        let outcome = await CoverSearchService(loader: CannedLoader(routes: [:])).search(CoverSearchQuery(title: "Anything"))
        #expect(outcome.results.isEmpty)
        #expect(outcome.failedProviders == [.openLibrary, .googleBooks])
    }

    @Test func emptyQueryMakesNoRequests() async {
        // No routes, so any request would fail and show up in failedProviders.
        let outcome = await CoverSearchService(loader: CannedLoader(routes: [:])).search(CoverSearchQuery(title: ""))
        #expect(outcome.results.isEmpty)
        #expect(outcome.failedProviders.isEmpty)
    }

    @Test func mergeDedupesByImageURL() {
        let shared = result(.openLibrary, 1)
        var duplicate = result(.googleBooks, 9)
        duplicate.imageURL = shared.imageURL
        let merged = CoverSearchService.merge([[shared, result(.openLibrary, 2)], [duplicate, result(.googleBooks, 3)]])
        #expect(merged.map(\.title) == ["1", "2", "3"])
    }

    @Test func mergeCapsResults() {
        let first = (0..<30).map { result(.openLibrary, $0) }
        let second = (0..<30).map { result(.googleBooks, $0) }
        let merged = CoverSearchService.merge([first, second])
        #expect(merged.count == CoverSearchService.maxResults)
        #expect(merged.count == 40)
        #expect(merged.filter { $0.provider == .openLibrary }.count == 20)
    }

    @Test func mergeHandlesUnevenLists() {
        let merged = CoverSearchService.merge([[result(.openLibrary, 1)], (1...3).map { result(.googleBooks, $0) }])
        #expect(merged.map(\.provider) == [.openLibrary, .googleBooks, .googleBooks, .googleBooks])
        #expect(CoverSearchService.merge([]).isEmpty)
    }

    @Test func providersHaveNames() {
        for provider in CoverSearchProvider.allCases {
            #expect(!provider.displayName.isEmpty)
        }
    }
}

struct CoverImageDownloadTests {
    private let imageURL = URL(string: "https://images.example.com/cover.jpg")!

    @MainActor
    private static func png(width: CGFloat, height: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func loader(status: Int = 200, contentType: String, body: Data) -> CannedLoader {
        CannedLoader(routes: ["images.example.com": .init(status: status, contentType: contentType, body: body)])
    }

    @Test @MainActor func acceptsARealCover() async throws {
        let png = Self.png(width: 200, height: 300)
        let data = try await CoverSearchService.downloadImage(imageURL, loader: loader(contentType: "image/png", body: png))
        #expect(data == png)
    }

    @Test func rejectsHTTP() async {
        let url = URL(string: "http://images.example.com/cover.jpg")!
        await #expect(throws: CoverSearchError.insecureURL) {
            try await CoverSearchService.downloadImage(url, loader: loader(contentType: "image/png", body: Data()))
        }
    }

    @Test @MainActor func rejectsNonImageMIMEType() async {
        let png = Self.png(width: 200, height: 300)
        await #expect(throws: CoverSearchError.notAnImage) {
            try await CoverSearchService.downloadImage(imageURL, loader: loader(contentType: "text/html; charset=utf-8", body: png))
        }
    }

    @Test func rejectsBytesThatAreNotAnImage() async {
        await #expect(throws: CoverSearchError.notAnImage) {
            try await CoverSearchService.downloadImage(imageURL, loader: loader(contentType: "image/jpeg", body: Data("nope".utf8)))
        }
    }

    @Test @MainActor func rejectsTinyPlaceholders() async {
        let pixel = Self.png(width: 1, height: 1)
        await #expect(throws: CoverSearchError.notAnImage) {
            try await CoverSearchService.downloadImage(imageURL, loader: loader(contentType: "image/png", body: pixel))
        }
        let thin = Self.png(width: 300, height: 20)
        await #expect(throws: CoverSearchError.notAnImage) {
            try await CoverSearchService.downloadImage(imageURL, loader: loader(contentType: "image/png", body: thin))
        }
    }

    @Test func rejectsNon200() async {
        await #expect(throws: CoverSearchError.badResponse(404)) {
            try await CoverSearchService.downloadImage(imageURL, loader: loader(status: 404, contentType: "image/jpeg", body: Data()))
        }
    }

    @Test func rejectsOversizedImages() async {
        let huge = Data(count: CoverSearchService.maxImageBytes + 1)
        await #expect(throws: CoverSearchError.tooLarge) {
            try await CoverSearchService.downloadImage(imageURL, loader: loader(contentType: "image/jpeg", body: huge))
        }
    }
}
