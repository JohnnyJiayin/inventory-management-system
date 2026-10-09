import SwiftUI

/// 产品照片（私有存储桶，通过签名链接加载）
struct ProductPhotoView: View {
    let path: String?
    var size: CGFloat = 56

    @State private var url: URL?

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image): image.resizable().scaledToFill()
                    case .failure: placeholder
                    default: ProgressView()
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .background(Color(uiColor: .systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: size / 8))
        .task(id: path) {
            guard let path else { url = nil; return }
            url = try? await PhotoService.signedURL(path: path)
        }
    }

    private var placeholder: some View {
        Image(systemName: "photo")
            .font(.system(size: size * 0.35))
            .foregroundStyle(.tertiary)
    }
}
