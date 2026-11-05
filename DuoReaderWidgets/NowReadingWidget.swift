import SwiftUI
import WidgetKit

/// The book being read: its cover and how far along you are. The medium size
/// adds the title, author and a Resume button. Also used in StandBy.
struct NowReadingWidget: Widget {
    static let kind = "NowReading"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider()) { entry in
            NowReadingWidgetView(entry: entry)
        }
        .configurationDisplayName("Now Reading")
        .description("The cover of the book you're reading and how far you've got.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct NowReadingWidgetView: View {
    var entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let book = entry.snapshot?.current {
            Group {
                switch family {
                case .systemMedium: ContinueReadingView(book: book)
                default: NowReadingSmallView(book: book)
                }
            }
            .widgetURL(WidgetLink.url(forBook: book.id))
            .containerBackground(for: .widget) { BookBackground(book: book) }
        } else {
            EmptyLibraryView(
                title: "Nothing open yet",
                message: entry.snapshot?.books.isEmpty ?? true
                    ? "Add a book in Duo Reader to start reading."
                    : "Open a book in Duo Reader and it'll show here.",
                systemImage: "book.closed")
                .widgetURL(WidgetLink.library)
                .containerBackground(.fill.tertiary, for: .widget)
        }
    }
}

/// Small: the cover, with a progress ring beside it.
private struct NowReadingSmallView: View {
    var book: WidgetSnapshot.Book
    @Environment(\.showsWidgetContainerBackground) private var showsBackground

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            CoverArtwork(book: book)
            // Drawn by hand: the accessory gauge styles have a fixed size of
            // about 58 pt, which pushed past the widget's margins.
            ProgressRing(progress: book.progress, percent: book.percent,
                         color: book.baseColor.textColor(showsBackground: showsBackground))
                .frame(width: 40, height: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(book.accessibilityDescription)
    }
}

/// A ring that fills with progress, with the percentage inside.
private struct ProgressRing: View {
    var progress: Double
    var percent: Int
    var color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.3), lineWidth: 4)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .widgetAccentable()
            Text("\(percent)%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .minimumScaleFactor(0.7)
                .foregroundStyle(color)
        }
        .padding(2)
    }
}

/// Medium: cover, title, author, progress and Resume.
private struct ContinueReadingView: View {
    var book: WidgetSnapshot.Book
    @Environment(\.showsWidgetContainerBackground) private var showsBackground

    var body: some View {
        let text = book.baseColor.textColor(showsBackground: showsBackground)
        HStack(spacing: 14) {
            CoverArtwork(book: book)
            VStack(alignment: .leading, spacing: 3) {
                Text("Continue reading")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(text.opacity(0.7))
                Text(book.title)
                    .font(.system(.headline, design: .serif))
                    .lineLimit(2)
                Text(book.author)
                    .font(.caption)
                    .foregroundStyle(text.opacity(0.75))
                    .lineLimit(1)
                Spacer(minLength: 4)
                ProgressView(value: book.progress)
                    .tint(text)
                HStack {
                    Text("\(book.percent)% read")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(text.opacity(0.75))
                    Spacer()
                    Link(destination: WidgetLink.url(forBook: book.id)) {
                        Label("Resume", systemImage: "book.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(text.opacity(0.18), in: Capsule())
                    }
                    .accessibilityLabel("Resume \(book.title)")
                }
            }
            .foregroundStyle(text)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }
}

/// The book's own colour, darkened toward the bottom.
private struct BookBackground: View {
    var book: WidgetSnapshot.Book

    var body: some View {
        ZStack {
            book.baseColor.color
            LinearGradient(colors: [.clear, .black.opacity(0.25)], startPoint: .top, endPoint: .bottom)
        }
    }
}
