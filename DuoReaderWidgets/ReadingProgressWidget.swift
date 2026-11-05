import SwiftUI
import WidgetKit

/// Lock screen widgets for the book being read.
struct ReadingProgressWidget: Widget {
    static let kind = "ReadingProgress"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider()) { entry in
            ReadingProgressView(entry: entry)
                .containerBackground(for: .widget) { AccessoryWidgetBackground() }
        }
        .configurationDisplayName("Reading Progress")
        .description("How far you are through the book you're reading.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct ReadingProgressView: View {
    var entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let book = entry.snapshot?.current
        Group {
            switch family {
            case .accessoryCircular: circular(book)
            case .accessoryRectangular: rectangular(book)
            default: inline(book)
            }
        }
        .widgetURL(book.map { WidgetLink.url(forBook: $0.id) } ?? WidgetLink.library)
    }

    private func circular(_ book: WidgetSnapshot.Book?) -> some View {
        Gauge(value: book?.progress ?? 0) {
            Image(systemName: "book.closed")
        } currentValueLabel: {
            if let book {
                Text("\(book.percent)")
            } else {
                Image(systemName: "book.closed")
            }
        }
        .gaugeStyle(.accessoryCircular)
        .accessibilityLabel(book.map { $0.accessibilityDescription } ?? String(localized: "No book open"))
    }

    @ViewBuilder
    private func rectangular(_ book: WidgetSnapshot.Book?) -> some View {
        if let book {
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.headline)
                    .widgetAccentable()
                    .lineLimit(1)
                    .privacySensitive()
                Text(book.author)
                    .font(.caption)
                    .lineLimit(1)
                    .privacySensitive()
                HStack(spacing: 6) {
                    ProgressView(value: book.progress)
                    Text("\(book.percent)%")
                        .font(.caption.monospacedDigit())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Label("No book open", systemImage: "book.closed")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func inline(_ book: WidgetSnapshot.Book?) -> some View {
        if let book {
            ViewThatFits {
                Label("\(book.percent)% · \(book.title)", systemImage: "book.closed")
                Label("\(book.percent)% read", systemImage: "book.closed")
            }
            .privacySensitive()
        } else {
            Label("No book open", systemImage: "book.closed")
        }
    }
}
