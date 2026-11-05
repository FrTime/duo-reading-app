import SwiftUI

/// What people around you see on iPhone Duo's outer screen while you read:
/// the book's front cover, filling the panel, on the cover's own colour where
/// the 2:3 cover is narrower than the screen.
struct OuterCoverView: View {
    let book: Book
    @State private var image: UIImage?
    @State private var background: Color = .black

    var body: some View {
        ZStack {
            background
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Cover of \(book.title)"))
        .accessibilityAddTraits(.isImage)
        // Re-render when the cover is edited while the book is open.
        .task(id: CoverLibrary.shared.revision(for: book.id)) {
            background = await CoverLibrary.shared.backgroundColor(for: book)
            // The outer panel is 1398 px wide; the full render is 1400.
            image = await CoverLibrary.shared.frontCover(for: book)
        }
    }
}

/// Settings for the outer-screen cover, shown in the reader's "Aa" sheet on
/// iPhone Duo only.
struct OuterCoverSettingsSection: View {
    @AppStorage(OuterCoverSettingsSection.storageKey) private var isEnabled = false
    let status: OuterCoverPolicy.Status
    let camera: OuterCoverCamera
    @Environment(\.openURL) private var openURL

    static let storageKey = "reader.showsCoverOnOutside"

    var body: some View {
        if status != .unsupported {
            Section {
                Toggle("Show Cover on the Outside", isOn: $isEnabled)
                    .onChange(of: isEnabled) { _, enabled in
                        if enabled { Task { await camera.requestAccess() } }
                    }
                if status == .blocked {
                    Button("Allow Camera in Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            } header: {
                Text("iPhone Duo")
            } footer: {
                Text(footer)
            }
        }
    }

    private var footer: LocalizedStringKey {
        switch status {
        case .blocked:
            "Camera access is off for Duo Reader, so the cover can't show on the outside. iOS only lets apps use the outer screen while the camera is on."
        default:
            "While the Duo is open, people around you see this book's cover on the outer screen. iOS only allows this while the camera is on, so the camera indicator shows and it uses some extra battery. Nothing is shown, recorded or saved."
        }
    }
}
