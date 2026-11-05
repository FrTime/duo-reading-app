import Foundation
@preconcurrency import ReadiumShared
@preconcurrency import ReadiumStreamer

/// Why a book couldn't be opened for reading.
enum ReaderOpenError: Error, Equatable {
    /// The imported file is gone from the library folder.
    case fileMissing
    /// The reader doesn't render this format yet (it needs converting first).
    case unsupportedFormat
    /// The file is DRM-protected. DRM removal is out of scope.
    case drmProtected
    /// The file is damaged or isn't what its extension says.
    case unreadable

    var title: LocalizedStringResource {
        switch self {
        case .fileMissing: "This book's file is missing"
        case .unsupportedFormat: "This format can't be opened yet"
        case .drmProtected: "This book is DRM-protected"
        case .unreadable: "This book couldn't be opened"
        }
    }

    var message: LocalizedStringResource {
        switch self {
        case .fileMissing:
            "The file may have been removed. Import the book again to read it."
        case .unsupportedFormat:
            "Duo Reader opens EPUB and PDF files today. Support for more formats is on the way."
        case .drmProtected:
            "Books bought from stores like Kindle or Apple Books are locked to those apps. Try a DRM-free copy."
        case .unreadable:
            "The file may be damaged. Try importing it again, or check that it opens in another app."
        }
    }
}

/// Opens imported files as Readium publications.
///
/// Everything happens on the device: the HTTP client is only there because
/// Readium's parsers require one, and it is never used for local files.
@MainActor
final class PublicationLoader {
    static let shared = PublicationLoader()

    private let httpClient: HTTPClient
    // Readium's retriever and opener aren't Sendable, but they're immutable
    // once built and Readium runs their async methods off the main actor.
    nonisolated(unsafe) private let assetRetriever: AssetRetriever
    nonisolated(unsafe) private let opener: PublicationOpener

    init() {
        httpClient = DefaultHTTPClient()
        assetRetriever = AssetRetriever(httpClient: httpClient)
        opener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            )
        )
    }

    /// Opens the file at `url`, which must be a local EPUB or PDF.
    func open(_ url: URL) async throws(ReaderOpenError) -> Publication {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw .fileMissing
        }
        guard let fileURL = FileURL(url: url) else {
            throw .unreadable
        }

        let asset: Asset
        switch await assetRetriever.retrieve(url: fileURL) {
        case let .success(retrieved):
            asset = retrieved
        case .failure:
            // The format was checked before opening, so a file Readium can't
            // recognise is damaged rather than unsupported.
            throw .unreadable
        }

        let publication: Publication
        switch await opener.open(asset: asset, allowUserInteraction: false) {
        case let .success(opened):
            publication = opened
        case .failure:
            throw .unreadable
        }

        guard !publication.isRestricted else {
            throw .drmProtected
        }
        return publication
    }
}
