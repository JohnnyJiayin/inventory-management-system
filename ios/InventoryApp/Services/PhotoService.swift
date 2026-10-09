import Foundation
import Supabase
import UIKit

/// 产品照片：私有存储桶 + 有时效的签名链接（架构设计 9.2）
enum PhotoService {
    /// 照片上传前压缩到约 300KB
    static let targetBytes = 300 * 1024

    /// 压缩并上传，返回存储路径
    static func upload(_ image: UIImage) async throws -> String {
        guard let data = ImageCompressor.jpeg(image, maxBytes: targetBytes) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let path = "models/\(UUID().uuidString.lowercased()).jpg"
        try await supabase.storage.from(AppConfig.photoBucket)
            .upload(path, data: data, options: FileOptions(contentType: "image/jpeg"))
        return path
    }

    /// 尽力删除（失败不影响业务）
    static func remove(path: String) async {
        _ = try? await supabase.storage.from(AppConfig.photoBucket).remove(paths: [path])
        await SignedURLCache.shared.invalidate(path)
    }

    static func signedURL(path: String) async throws -> URL {
        try await SignedURLCache.shared.url(for: path)
    }
}

/// 签名链接缓存：有效期 1 小时，提前 5 分钟刷新
actor SignedURLCache {
    static let shared = SignedURLCache()
    private var cache: [String: (url: URL, expires: Date)] = [:]
    private let lifetime = 3600

    func url(for path: String) async throws -> URL {
        if let hit = cache[path], hit.expires > Date().addingTimeInterval(300) {
            return hit.url
        }
        let url = try await supabase.storage.from(AppConfig.photoBucket)
            .createSignedURL(path: path, expiresIn: lifetime)
        cache[path] = (url, Date().addingTimeInterval(TimeInterval(lifetime)))
        return url
    }

    func invalidate(_ path: String) {
        cache[path] = nil
    }
}

enum ImageCompressor {
    /// 先把长边缩到 1600px，再逐步降低 JPEG 质量直到不超过 maxBytes；
    /// 质量降到下限仍超出时继续缩小尺寸。
    static func jpeg(_ image: UIImage, maxBytes: Int) -> Data? {
        var maxSide: CGFloat = 1600
        while maxSide >= 400 {
            let scaled = resize(image, maxSide: maxSide)
            var quality: CGFloat = 0.8
            while quality >= 0.3 {
                if let data = scaled.jpegData(compressionQuality: quality), data.count <= maxBytes {
                    return data
                }
                quality -= 0.1
            }
            maxSide *= 0.75
        }
        return resize(image, maxSide: 400).jpegData(compressionQuality: 0.3)
    }

    private static func resize(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
