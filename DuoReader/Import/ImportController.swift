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
    /// Which file of the batch is being worked on, for the progress overlay.
    private(set) var progress: ImportProgress?
    var summary: ImportSummary?

    private let importer: LibraryImporter

    init(container: ModelContainer, booksFolder: URL = LibraryImporter.defaultBooksFolder) {
        importer = LibraryImporter(modelContainer: container, booksFolder: booksFolder)
    }

    /// Types offered in the document picker. ZIPs are included because books
    /// are often shared zipped (`.fb2.zip`, comics); the importer looks inside
    /// and explains when a ZIP isn't a book.
    static var allowedContentTypes: [UTType] {
        LibraryImporter.supportedFormats
            .flatMap(\.fileExtensions)
            .compactMap { UTType(filenameExtension: $0) } + [.zip]
    }

    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        Task {
            var outcomes: [ImportOutcome] = []
            for (index, url) in urls.enumerated() {
                let accessing = url.startAccessingSecurityScopedResource()
                if CloudFiles.needsDownload(url) {
                    progress = ImportProgress(current: index + 1, total: urls.count, fileName: url.lastPathComponent, downloading: true)
                    // If it fails, the import below reports the file as unreadable.
                    try? await CloudFiles.download(url)
                }
                if accessing { url.stopAccessingSecurityScopedResource() }
                progress = ImportProgress(current: index + 1, total: urls.count, fileName: url.lastPathComponent, downloading: false)
                outcomes.append(await importer.importFile(url))
            }
            progress = nil
            isImporting = false
            show(outcomes)
        }
    }

    /// Results that arrived while an alert was on screen. SwiftUI doesn't
    /// redraw an alert that's already presented, so they wait for it to close.
    private(set) var queued: [ImportOutcome] = []

    /// How long to wait after an alert closes before presenting the next.
    var representDelay: Duration = .milliseconds(400)

    /// Shows a batch's summary. If an alert is already up (say two files were
    /// opened in a row), the new results are queued and shown, combined,
    /// once it's dismissed, so none is lost behind the first.
    func show(_ outcomes: [ImportOutcome]) {
        if let current = summary, !current.isQuietSuccess {
            queued += outcomes
        } else {
            summary = ImportSummary(outcomes: outcomes)
        }
    }

    /// Closes the import alert, then presents anything that arrived meanwhile.
    func dismissSummary() {
        summary = nil
        guard !queued.isEmpty else { return }
        let next = queued
        queued = []
        Task {
            // Let the dismissal animation finish, or the next alert is dropped.
            try? await Task.sleep(for: representDelay)
            show(next)
        }
    }
}

/// Where a batch import has got to.
struct ImportProgress: Equatable {
    var current: Int
    var total: Int
    var fileName: String
    /// Waiting for iCloud to download the file before it can be read.
    var downloading: Bool

    var label: String {
        switch (downloading, total) {
        case (true, 1): String(localized: "Downloading “\(fileName)” from iCloud…")
        case (true, _): String(localized: "Downloading \(current) of \(total) from iCloud…")
        case (false, 1): String(localized: "Importing…")
        case (false, _): String(localized: "Importing \(current) of \(total)…")
        }
    }

    /// Files finished so far, as a fraction of the batch.
    var fractionDone: Double { Double(current - 1) / Double(max(total, 1)) }
}

/// A short, human summary of an import batch.
struct ImportSummary: Identifiable, Equatable {
    let id = UUID()
    let outcomes: [ImportOutcome]
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
        self.outcomes = outcomes
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
        if imported.isEmpty && duplicates.isEmpty {
            return failures.count == 1
                ? String(localized: "Couldn’t import “\(failures[0].fileName)”")
                : String(localized: "Couldn’t import \(failures.count) files")
        }
        if !failures.isEmpty {
            return failures.count == 1
                ? String(localized: "1 file couldn’t be imported")
                : String(localized: "\(failures.count) files couldn’t be imported")
        }
        return String(localized: "Import finished")
    }

    var message: String {
        // The title already says it; just name the books.
        if imported.isEmpty && failures.isEmpty {
            return duplicates.joined(separator: "\n")
        }
        var lines: [String] = []
        if !imported.isEmpty {
            lines.append(String(localized: "Added: \(imported.count)"))
        }
        if !duplicates.isEmpty {
            lines.append(String(localized: "Already in your library: \(duplicates.joined(separator: ", "))"))
        }
        // A single failure is named in the title; just say why.
        if failures.count == 1, imported.isEmpty, duplicates.isEmpty {
            return failures[0].reason.explanation
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
        case .tooLarge: String(localized: "The file is too large to import.")
        }
    }
}
