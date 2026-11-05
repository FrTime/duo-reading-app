import ImageIO
import SwiftUI
import UIKit

/// Decodes and downsamples cover images off the main thread, caching the
/// results so scrolling a large library doesn't decode full-size covers.
final class CoverThumbnailCache: @unchecked Sendable {
    static let shared = CoverThumbnailCache()
    // NSCache is thread-safe.
    private let cache = NSCache<NSString, UIImage>()

    init() { cache.countLimit = 300 }

    func image(for id: UUID, data: Data, maxPixel: Int) async -> UIImage? {
        // Keyed by content too, so a new cover from the cover builder isn't
        // served from a stale cache entry.
        let key = "\(id.uuidString)-\(maxPixel)-\(data.hashValue)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image = await Task.detached(priority: .userInitiated) {
            Self.downsample(data, maxPixel: maxPixel)
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    func removeAll() { cache.removeAllObjects() }

    static func downsample(_ data: Data, maxPixel: Int) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// A book's cover, or a generated one with its title when the file has none.
struct BookCoverView: View {
    let book: Book
    var maxPixel: Int = 400

    @State private var image: UIImage?

    var body: some View {
        // A fixed 2:3 slot; the cover fills it and anything outside is
        // cropped, so wide covers (PDF pages, landscape art) don't spill out.
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    GeneratedCover(title: book.title, author: book.authors.first, seed: book.id, compact: maxPixel < 200)
                }
            }
            .clipShape(.rect(cornerRadius: 4))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
            // The thumbnail is small and stored inline, so reading it here is
            // cheap; the full cover (external storage) is never touched.
            .task(id: book.coverThumbnailData) {
                guard let data = book.coverThumbnailData else { image = nil; return }
                image = await CoverThumbnailCache.shared.image(for: book.id, data: data, maxPixel: maxPixel)
            }
            .accessibilityHidden(true)
    }
}

/// A plain cloth-style cover in a colour picked from the book's id, so each
/// book keeps the same colour. The cover builder (#39) replaces this.
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
