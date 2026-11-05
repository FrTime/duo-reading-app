import SwiftUI
import WidgetKit

/// A book's front cover from the snapshot, or a plain jacket in its colours
/// when the image isn't there (gallery sample, or covers not rendered yet).
struct CoverArtwork: View {
    var book: WidgetSnapshot.Book
    var kind: WidgetStore.ImageKind = .cover
    var cornerRadius: CGFloat = 3

    var body: some View {
        Group {
            if let image = WidgetImages.image(kind, for: book.id) {
                Image(uiImage: image)
                    .resizable()
                    .widgetAccentedRenderingMode(.accentedDesaturated)
                    .aspectRatio(2 / 3, contentMode: .fill)
            } else {
                PlainJacket(book: book)
            }
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(alignment: .leading) {
            // A hint of the hinge, like the shelf's covers.
            LinearGradient(colors: [.black.opacity(0.25), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 4)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
        .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 2)
        .accessibilityHidden(true)
    }
}

/// The title on the book's own colour.
private struct PlainJacket: View {
    var book: WidgetSnapshot.Book

    var body: some View {
        ZStack {
            book.baseColor.color
            Text(book.title)
                .font(.system(size: 9, weight: .semibold, design: .serif))
                .multilineTextAlignment(.center)
                .foregroundStyle(book.baseColor.textColor)
                .minimumScaleFactor(0.6)
                .padding(4)
        }
    }
}

/// A spine for the shelf widget.
struct SpineArtwork: View {
    var book: WidgetSnapshot.Book

    var body: some View {
        Group {
            if let image = WidgetImages.image(.spine, for: book.id) {
                Image(uiImage: image)
                    .resizable()
                    .widgetAccentedRenderingMode(.accentedDesaturated)
            } else {
                book.spineColor.color
                    .overlay {
                        LinearGradient(
                            colors: [.black.opacity(0.25), .white.opacity(0.12), .black.opacity(0.3)],
                            startPoint: .leading, endPoint: .trailing)
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 1.5))
        .accessibilityHidden(true)
    }
}

/// Shown when there's nothing to show yet.
struct EmptyLibraryView: View {
    var title: LocalizedStringKey
    var message: LocalizedStringKey
    var systemImage = "books.vertical"

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
