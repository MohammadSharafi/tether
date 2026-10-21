import SwiftUI
import PhotosUI

/// Downscales a photo to what Claude reads well (long side 1568 px) and re-encodes it as JPEG.
func prepareImage(_ data: Data) -> Attachment? {
    guard let image = UIImage(data: data) else { return nil }
    let scale = min(1, 1568 / max(image.size.width, image.size.height))
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    return resized.jpegData(compressionQuality: 0.8).map { Attachment(jpeg: $0) }
}

struct AttachmentButton: View {
    @Binding var attachments: [Attachment]
    var showsTitle = false
    @State private var items: [PhotosPickerItem] = []

    var body: some View {
        PhotosPicker(selection: $items, maxSelectionCount: max(1, 4 - attachments.count), matching: .images) {
            if showsTitle {
                Label("Add photos", systemImage: "photo.on.rectangle")
            } else {
                Image(systemName: "photo.on.rectangle")
                    .font(.title2)
                    .padding(.bottom, 4)
                    .accessibilityLabel("Add photos")
            }
        }
        .disabled(attachments.count >= 4)
        .onChange(of: items) {
            let picked = items
            items = []
            Task {
                for item in picked {
                    if let data = try? await item.loadTransferable(type: Data.self), let a = prepareImage(data), attachments.count < 4 {
                        attachments.append(a)
                    }
                }
            }
        }
    }
}

struct AttachmentStrip: View {
    @Binding var attachments: [Attachment]

    var body: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(attachments) { a in
                        if let image = UIImage(data: a.jpeg) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(alignment: .topTrailing) {
                                    Button("Remove photo", systemImage: "xmark.circle.fill") {
                                        attachments.removeAll { $0.id == a.id }
                                    }
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                                    .padding(2)
                                }
                        }
                    }
                }
            }
        }
    }
}

/// Button plus previews, for forms.
struct AttachmentPicker: View {
    @Binding var attachments: [Attachment]

    var body: some View {
        AttachmentButton(attachments: $attachments, showsTitle: true)
        AttachmentStrip(attachments: $attachments)
    }
}
