import SwiftUI

/// The reader's side panels: settings, contents and search.
enum ReaderPanel: String, Identifiable {
    case settings, contents, search
    var id: Self { self }
}

/// Title and Done around a reader panel.
///
/// Presented as a sheet, the panel gets its own navigation stack. Docked on
/// the open Duo's right-hand screen it sits inside the reader's navigation
/// stack, where a nested stack's bar would merge into the reader's (hidden)
/// one, so the title and Done go in a header of its own instead.
struct ReaderPanelContainer<Content: View>: View {
    let title: LocalizedStringKey
    /// Closes the panel when it's docked. Nil when it's a sheet.
    let onDone: (() -> Void)?
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let onDone {
            VStack(spacing: 0) {
                HStack {
                    Text(title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button(action: onDone) {
                        Label("Done", systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)
                content
                    .frame(maxHeight: .infinity)
            }
            .accessibilityAction(.escape, onDone)
        } else {
            NavigationStack {
                content
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button {
                                dismiss()
                            } label: {
                                Label("Done", systemImage: "checkmark")
                            }
                        }
                    }
            }
        }
    }
}
