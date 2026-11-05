import Observation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Runs imports from the picker, drag and drop and "Open in Duo Reader", and
/// holds the summary the library shows when a batch finishes.
@MainActor
@Observable
final class ImportController {
    private(set) var isImporting = false
    var summary: ImportSummary?

    private let importer: LibraryImporter

    init(container: ModelContainer, booksFolder: URL = LibraryImporter.defaultBooksFolder) {
        importer = LibraryImporter(modelContainer: container, booksFolder: booksFolder)
    }

    /// Types offered in the document picker.
    static var allowedContentTypes: [UTType] {
        LibraryImporter.supportedFormats
            .flatMap(\.fileExtensions)
            .compactMap { UTType(filenameExtension: $0) }
    }

    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        Task {
            let outcomes = await importer.importFiles(urls)
            isImporting = false
            summary = ImportSummary(outcomes: outcomes)
        }
    }
}

/// A short, human summary of an import batch.
struct ImportSummary: Identifiable, Equatable {
    let id = UUID()
    let imported: [String]
    let duplicates: [String]
    let failures: [(fileName: String, reason: ImportFailure)]

    init(outcomes: [ImportOutcome]) {
        var imported: [String] = [], duplicates: [String] = []
        var failures: [(String, ImportFailure)] = []
        for outcome in outcomes {
            switch outcome {
            case .imported(_, let title): imported.append(title)
            case .duplicate(let title): duplicates.append(title)
            case .failed(let name, let reason): failures.append((name, reason))
            }
        }
        self.imported = imported
        self.duplicates = duplicates
        self.failures = failures
    }

    static func == (lhs: ImportSummary, rhs: ImportSummary) -> Bool { lhs.id == rhs.id }

    /// Nothing worth interrupting the user about: everything imported cleanly.
    var isQuietSuccess: Bool { duplicates.isEmpty && failures.isEmpty }

    var title: String {
        if failures.isEmpty && duplicates.isEmpty {
            return imported.count == 1
                ? String(localized: "Added “\(imported[0])”")
                : String(localized: "Added \(imported.count) books")
        }
        if imported.isEmpty && failures.isEmpty {
            return String(localized: "Already in your library")
        }
        return String(localized: "Import finished")
    }

    var message: String {
        var lines: [String] = []
        if !imported.isEmpty {
            lines.append(String(localized: "Added: \(imported.count)"))
        }
        if !duplicates.isEmpty {
            lines.append(String(localized: "Already in your library: \(duplicates.joined(separator: ", "))"))
        }
        for failure in failures {
            lines.append("\(failure.fileName): \(failure.reason.explanation)")
        }
        return lines.joined(separator: "\n")
    }
}

extension ImportFailure {
    var explanation: String {
        switch self {
        case .unsupportedFormat: String(localized: "This file type isn't supported yet.")
        case .drmProtected: String(localized: "This book is DRM-protected and can't be opened.")
        case .unreadable: String(localized: "The file looks damaged and couldn't be read.")
        case .copyFailed: String(localized: "The file couldn't be saved. Check you have free space.")
        }
    }
}
