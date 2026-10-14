import Foundation
import UniformTypeIdentifiers
import UIKit
import ImageIO
import ShikeCore

enum ItemLoader {
    static func load(_ providers: [NSItemProvider]) async throws -> (String, [String]) {
        var text: [String] = []
        var images: [String] = []
        var handedOff = false
        defer { if !handedOff { images.forEach(ImageStaging.remove) } }
        for provider in providers {
            try Task.checkCancellation()
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                guard images.count < 5 else { throw ShikeError.message("一次最多导入 5 张图片，请分批导入。") }
                let data = try await imageData(from: provider)
                guard data.count <= 30_000_000 else { throw ShikeError.message("单张图片超过 30 MB，请压缩或裁剪后再试。") }
                try Task.checkCancellation()
                images.append(try ImageStaging.write(data))
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                text.append(try await textValue(from: provider))
            }
        }
        guard !text.isEmpty || !images.isEmpty else { throw ShikeError.message("请选择文字或图片后再导入。暂不支持网页链接或 PDF。") }
        handedOff = true
        return (text.joined(separator: "\n\n"), images)
    }

    private static func textValue(from provider: NSItemProvider) async throws -> String {
        if provider.canLoadObject(ofClass: NSString.self) {
            if let value: String = try? await withCheckedThrowingContinuation({ continuation in
                provider.loadObject(ofClass: NSString.self) { object, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let value = object as? String { continuation.resume(returning: value) }
                    else { continuation.resume(throwing: ShikeError.message("无法读取文字。")) }
                }
            }) { return value }
        }
        try Task.checkCancellation()
        let type = provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .plainText) == true
        } ?? UTType.plainText.identifier
        let object: NSSecureCoding = try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                if let error { continuation.resume(throwing: error) }
                else if let item { continuation.resume(returning: item) }
                else { continuation.resume(throwing: ShikeError.message("无法读取粘贴或分享的文字。")) }
            }
        }
        if let value = object as? String { return value }
        let data: Data
        if let url = object as? URL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard url.isFileURL else { throw ShikeError.message("请选择文字内容，暂不支持网页链接。") }
            if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 2_000_000 {
                throw ShikeError.message("文字文件过大，请分段导入。")
            }
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } else if let bytes = object as? Data { data = bytes }
        else { throw ShikeError.message("无法读取粘贴或分享的文字，请先复制为纯文本。") }
        guard data.count <= 2_000_000 else { throw ShikeError.message("文字内容过大，请分段导入。") }
        let isUTF16 = type == UTType.utf16PlainText.identifier || type == "public.utf16-external-plain-text" ||
            data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        if let value = String(data: data, encoding: isUTF16 ? .utf16 : .utf8) { return value }
        throw ShikeError.message("文字编码无法识别，请先复制为纯文本。")
    }

    private static func imageData(from provider: NSItemProvider) async throws -> Data {
        // Concrete image representations preserve efficient file decoding. A generic
        // public.image representation can be a keyed UIImage archive, not image bytes.
        if let type = provider.registeredTypeIdentifiers.first(where: {
            $0 != UTType.image.identifier && UTType($0)?.conforms(to: .image) == true
        }) {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: ShikeError.message("无法读取图片内容。")) }
                }
            }
            if CGImageSourceCreateWithData(data as CFData, nil) != nil { return data }
        }
        let object: NSSecureCoding = try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, error in
                if let error { continuation.resume(throwing: error) }
                else if let item { continuation.resume(returning: item) }
                else { continuation.resume(throwing: ShikeError.message("无法读取分享的图片。")) }
            }
        }
        if let image = object as? UIImage, let data = image.jpegData(compressionQuality: 0.92) { return data }
        if let url = object as? URL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try Data(contentsOf: url, options: .mappedIfSafe)
        }
        if let data = object as? Data, CGImageSourceCreateWithData(data as CFData, nil) != nil { return data }
        throw ShikeError.message("分享的图片格式无法识别，请保存到相册后再导入。")
    }
}

