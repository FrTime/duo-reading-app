import SwiftUI

/// A book's front cover at 2:3, kept up to date as the cover is edited.
///
/// Used by the shelf's detail card, the cover editor and the outer display.
struct BookCoverView: View {
    let book: Book
    /// Caps the decoded size. Leave nil for the full 1400 px render.
    var pixelWidth: CGFloat?
    var covers: CoverLibrary = .shared

    @State private var image: UIImage?

    var body: some View {
        let revision = covers.revision(for: book.id)
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.quaternary)
            }
        }
        .aspectRatio(CoverDesign.frontAspectRatio, contentMode: .fit)
        .clipped()
        .task(id: "\(book.id.uuidString)-\(revision)") {
            image = await covers.frontCover(for: book, pixelWidth: pixelWidth)
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Cover of \(book.title)"))
        .accessibilityAddTraits(.isImage)
    }
}

#Preview {
    let container = try! LibraryStore.makeContainer(inMemory: true)
    let book = Book(relativeFilePath: "x.epub", contentHash: "x", format: .epub, title: "The Long Way Round", authors: ["Ada Writer"])
    container.mainContext.insert(book)
    return BookCoverView(book: book)
        .frame(width: 200)
        .padding()
        .modelContainer(container)
}
