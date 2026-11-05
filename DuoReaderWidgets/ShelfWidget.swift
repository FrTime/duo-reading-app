import SwiftUI
import WidgetKit

/// The library's shelf, in the app's order and display mode.
struct ShelfWidget: Widget {
    static let kind = "Shelf"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider()) { entry in
            ShelfWidgetView(entry: entry)
        }
        .configurationDisplayName("Your Shelf")
        .description("Your books, arranged the way they are in the app.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct ShelfWidgetView: View {
    var entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    private var rowCount: Int { family == .systemLarge ? 3 : 1 }

    var body: some View {
        content
            .containerBackground(for: .widget) { ShelfPalette.wall }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = entry.snapshot, !snapshot.books.isEmpty {
            GeometryReader { proxy in
                shelf(snapshot, size: proxy.size)
            }
        } else {
            EmptyLibraryView(title: "Your shelf is empty", message: "Add books in Duo Reader and they'll appear here.")
                .foregroundStyle(.white)
                .padding()
                .widgetURL(WidgetLink.library)
        }
    }

    private func shelf(_ snapshot: WidgetSnapshot, size: CGSize) -> some View {
        let inset = ShelfPalette.inset
        let rowWidth = size.width - inset * 2
        let rowHeight = (size.height - inset * 2) / CGFloat(rowCount)
        // The tallest book still clears the board above.
        let bookHeight = max((rowHeight - ShelfPalette.boardHeight - ShelfPalette.headroom) / WidgetShelfLayout.maxScale, 20)
        let layout = WidgetShelfLayout(
            books: snapshot.books, totalCount: snapshot.totalBookCount, style: snapshot.shelfStyle,
            rowCount: rowCount, rowWidth: rowWidth, bookHeight: bookHeight)

        return VStack(spacing: 0) {
            ForEach(Array(layout.rows.enumerated()), id: \.offset) { index, row in
                let isLast = index == layout.rows.count - 1
                ShelfRow(
                    books: row, style: snapshot.shelfStyle, bookHeight: bookHeight,
                    overflow: isLast ? layout.overflow : 0)
                    .frame(height: rowHeight)
            }
        }
        .padding(inset)
    }
}

/// One shelf: books standing on a board.
private struct ShelfRow: View {
    var books: [WidgetShelfLayout.Placed]
    var style: WidgetSnapshot.ShelfStyle
    var bookHeight: CGFloat
    var overflow: Int

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: WidgetShelfLayout.spacing) {
                ForEach(books) { placed in
                    Link(destination: WidgetLink.url(forBook: placed.book.id)) {
                        book(placed)
                    }
                    .accessibilityLabel(placed.book.accessibilityDescription)
                }
                Spacer(minLength: 0)
                if overflow > 0 {
                    Text("+\(overflow)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: WidgetShelfLayout.overflowBadgeWidth - 4)
                        .padding(.bottom, 4)
                        .accessibilityLabel("\(overflow) more books")
                }
            }
            .frame(height: bookHeight * WidgetShelfLayout.maxScale, alignment: .bottom)
            Board()
        }
    }

    @ViewBuilder
    private func book(_ placed: WidgetShelfLayout.Placed) -> some View {
        switch style {
        case .spines:
            SpineArtwork(book: placed.book)
                .frame(width: placed.width, height: placed.height)
        case .covers:
            CoverArtwork(book: placed.book, kind: .front, cornerRadius: 2)
                .frame(width: placed.width, height: placed.height)
        }
    }
}

/// The wooden board under each row.
private struct Board: View {
    var body: some View {
        LinearGradient(
            colors: [ShelfPalette.woodLight, ShelfPalette.wood, ShelfPalette.woodDark],
            startPoint: .top, endPoint: .bottom)
            .frame(height: ShelfPalette.boardHeight)
            .padding(.horizontal, -ShelfPalette.inset)
            .shadow(color: .black.opacity(0.4), radius: 2, y: 2)
    }
}

/// The app's bookcase colours (`ShelfTextures`), for the 2D widget.
enum ShelfPalette {
    static let wood = Color(.sRGB, red: 0.55, green: 0.38, blue: 0.24)
    static let woodLight = Color(.sRGB, red: 0.64, green: 0.46, blue: 0.30)
    static let woodDark = Color(.sRGB, red: 0.40, green: 0.27, blue: 0.17)
    static let wall = LinearGradient(
        colors: [Color(.sRGB, red: 0.22, green: 0.15, blue: 0.10), Color(.sRGB, red: 0.30, green: 0.21, blue: 0.14)],
        startPoint: .top, endPoint: .bottom)

    static let inset: CGFloat = 12
    static let boardHeight: CGFloat = 7
    static let headroom: CGFloat = 4
}
