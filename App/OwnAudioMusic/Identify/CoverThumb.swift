import SwiftUI

/// A match's cover, small: the first of `urls` that loads, else a plain placeholder. People
/// tell editions and recordings apart by their cover first.
struct CoverThumb: View {
    let urls: [URL]
    var size: CGFloat = 44

    @State private var index = 0

    var body: some View {
        Group {
            if index < urls.count {
                AsyncImage(url: urls[index]) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder.onAppear { index += 1 }
                    default:
                        placeholder.overlay(ProgressView().controlSize(.mini))
                    }
                }
                .id(index)
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(.quaternary)
            .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
    }
}
