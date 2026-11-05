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

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            CoverArtwork(book: book)
            Gauge(value: book.progress) {
                Text("Progress")
            } currentValueLabel: {
                Text("\(book.percent)%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(book.baseColor.textColor)
            .foregroundStyle(book.baseColor.textColor)
            .frame(width: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(book.accessibilityDescription)
    }
}

/// Medium: cover, title, author, progress and Resume.
private struct ContinueReadingView: View {
    var book: WidgetSnapshot.Book

    var body: some View {
        let text = book.baseColor.textColor
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
