import SwiftUI
import WidgetKit

struct SnapshotEntry: TimelineEntry {
    var date: Date
    /// Nil when the app hasn't written a snapshot yet.
    var snapshot: WidgetSnapshot?
    /// True for the gallery's sample, which has no images on disk.
    var isSample = false
}

/// Reads the snapshot the app wrote. The app reloads the widgets whenever it
/// changes, so a timeline is one entry that never expires.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .sample, isSample: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(entry(previewing: context.isPreview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        completion(Timeline(entries: [entry(previewing: false)], policy: .never))
    }

    private func entry(previewing: Bool) -> SnapshotEntry {
        let snapshot = WidgetStore.shared()?.load()
        // The gallery shows the sample until there's a library to show.
        if previewing, snapshot?.books.isEmpty ?? true {
            return SnapshotEntry(date: .now, snapshot: .sample, isSample: true)
        }
        return SnapshotEntry(date: .now, snapshot: snapshot)
    }
}

/// Loads the small images the app wrote. Only images on screen are loaded,
/// because the extension's memory limit is tight.
enum WidgetImages {
    static func image(_ kind: WidgetStore.ImageKind, for id: UUID) -> UIImage? {
        guard let url = WidgetStore.shared()?.imageURL(kind, for: id) else { return nil }
        return UIImage(contentsOfFile: url.path(percentEncoded: false))
    }
}

extension WidgetSnapshot.Color {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
    var textColor: Color { prefersLightText ? .white : .black }
}

extension WidgetSnapshot.Book {
    /// "Title by Author, 64% read" for VoiceOver.
    var accessibilityDescription: String {
        String(localized: "\(title) by \(author), \(percent)% read")
    }
}

extension WidgetSnapshot {
    /// Shown in the widget gallery and while a widget loads. Made-up titles,
    /// drawn as plain colours.
    static let sample: WidgetSnapshot = {
        let palette: [(Double, Double, Double)] = [
            (0.55, 0.16, 0.18), (0.13, 0.29, 0.42), (0.85, 0.66, 0.30), (0.20, 0.40, 0.30),
            (0.36, 0.25, 0.45), (0.82, 0.45, 0.30), (0.25, 0.25, 0.28), (0.60, 0.70, 0.75),
        ]
        let titles = ["The Lantern Road", "Salt and Iron", "A Map of Small Hours", "Greenwood",
                      "The Quiet Archive", "Ember Season", "Night Ferry", "Paper Tides"]
        let books = (0..<36).map { index in
            let (r, g, b) = palette[index % palette.count]
            let color = WidgetSnapshot.Color(red: r, green: g, blue: b)
            return Book(
                id: UUID(), title: titles[index % titles.count], author: "Duo Reader",
                progress: index == 0 ? 0.64 : 0, thickness: [0.12, 0.18, 0.09, 0.22, 0.14][index % 5],
                baseColor: color, spineColor: color, lastOpened: index == 0 ? .now : nil
            )
        }
        return WidgetSnapshot(generatedAt: .now, shelfStyle: .spines, totalBookCount: books.count,
                              books: books, current: books[0])
    }()
}
