import MusicLibrary
import PhotosUI
import SwiftUI

extension View {
    /// The system's photo picker (it needs no access to the whole library); the chosen picture,
    /// made smaller, becomes `target`'s on the server.
    func artworkPicker(isPresented: Binding<Bool>, target: @escaping () -> AppModel.ArtworkTarget?) -> some View {
        modifier(ArtworkPicker(isPresented: isPresented, target: target))
    }
}

private struct ArtworkPicker: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool
    let target: () -> AppModel.ArtworkTarget?
    @State private var item: PhotosPickerItem?

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $isPresented, selection: $item, matching: .images, preferredItemEncoding: .compatible)
            .onChange(of: item) { _, picked in
                guard let picked, let target = target() else { return }
                item = nil
                model.perform {
                    guard let data = try await picked.loadTransferable(type: Data.self), let jpeg = Self.prepared(data) else {
                        throw SourceError.unreadable
                    }
                    try await model.setArtwork(target, image: jpeg, contentType: "image/jpeg")
                    Haptics.selection()
                }
            }
    }

    /// At most 1600 pixels on its longest side, as JPEG: a phone photo is many megabytes, and a
    /// cover is never shown larger than that.
    static func prepared(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, 1600 / max(longest, 1))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: 0.85)
    }
}
