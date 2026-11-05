import SwiftUI
import UIKit

/// A book's front cover at 2:3, from `CoverLibrary`: the user's design, the
/// file's own artwork, or a generated cover. It redraws when the cover is
/// edited. Used by the grid, the list, the shelf card, the cover editor and
/// the outer display.
struct BookCoverView: View {
    let book: Book
    /// Largest side to decode, in pixels. Pass `nil` for the full render
    /// (1400 px wide, sharp on the Duo's outer display).
    var maxPixel: Int? = 400
    var covers: CoverLibrary = .shared

    @State private var image: UIImage?

    var body: some View {
        let revision = covers.revision(for: book.id)
        // A fixed 2:3 slot; the cover fills it and anything outside is cropped.
        Color.clear
            .aspectRatio(CoverDesign.frontAspectRatio, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                } else {
                    // Shown for the moment it takes to load the cover.
                    GeneratedCover(title: book.title, author: book.authors.first, seed: book.id, compact: (maxPixel ?? 400) < 200)
                }
            }
            .clipShape(.rect(cornerRadius: 4))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
            .task(id: CoverKey(id: book.id, revision: revision, maxPixel: maxPixel)) {
                image = await covers.image(.front, for: book, maxPixels: maxPixel)
            }
            .accessibilityHidden(true)
    }

    private struct CoverKey: Equatable {
        var id: UUID
        var revision: Int
        var maxPixel: Int?
    }
}

/// A plain cloth-style placeholder in a colour picked from the book's id,
/// shown while the real cover loads.
struct GeneratedCover: View {
    let title: String
    let author: String?
    let seed: UUID
    /// Small thumbnails show just the title's initial, since words won't fit.
    var compact = false

    private static let palette: [Color] = [
        Color(red: 0.42, green: 0.17, blue: 0.18), Color(red: 0.13, green: 0.27, blue: 0.40),
        Color(red: 0.16, green: 0.33, blue: 0.24), Color(red: 0.36, green: 0.27, blue: 0.13),
        Color(red: 0.25, green: 0.20, blue: 0.38), Color(red: 0.18, green: 0.18, blue: 0.20),
    ]

    var body: some View {
        let index = Int(seed.uuid.0) % Self.palette.count
        ZStack {
            Self.palette[index]
            if compact {
                Text(LibraryQuery.sortKey(forTitle: title).first.map(String.init) ?? "")
                    .font(.system(.title3, design: .serif, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            } else {
                VStack(spacing: 6) {
                    Text(title)
                        .font(.system(.caption, design: .serif, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(5)
                        .minimumScaleFactor(0.6)
                    if let author {
                        Text(author)
                            .font(.system(.caption2, design: .serif))
                            .lineLimit(2)
                            .opacity(0.8)
                    }
                }
                .foregroundStyle(.white.opacity(0.92))
                .padding(10)
            }
        }
    }
}
