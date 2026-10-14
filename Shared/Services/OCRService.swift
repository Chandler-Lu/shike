import Foundation
import Vision
import ImageIO
import ShikeCore

enum OCRService {
    static func recognizeFile(_ url: URL) async throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try await recognize(data)
    }
    static func recognize(_ data: Data) async throws -> String {
        let worker = Task.detached(priority: .userInitiated) { () throws -> String in
            try Task.checkCancellation()
            return try autoreleasepool {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                    throw ShikeError.message("无法打开这张图片，请选择 JPEG、PNG 或 HEIC 图片。")
                }
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
                let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
                guard width > 0, height > 0, width <= 60_000, height <= 60_000 else {
                    throw ShikeError.message("图片尺寸无法处理，请裁剪后再试。")
                }
                let pixelLimit = 8_000_000.0
                let scale = min(1, sqrt(pixelLimit / (Double(width) * Double(height))))
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: min(Int(Double(max(width, height)) * scale), 8000),
                    kCGImageSourceShouldCacheImmediately: true
                ]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    throw ShikeError.message("图片解码失败，请换一张图片重试。")
                }
                // Long screenshots are recognized in overlapping bands to preserve small text.
                let bandHeight = 2400
                let overlap = 120
                var lines: [String] = []
                var top = 0
                while top < image.height {
                    try Task.checkCancellation()
                    let h = min(bandHeight, image.height - top)
                    guard let band = image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: h)) else { break }
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    let supported = try request.supportedRecognitionLanguages()
                    request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"].filter(supported.contains)
                    request.automaticallyDetectsLanguage = true
                    try VNImageRequestHandler(cgImage: band).perform([request])
                    let recognized = (request.results ?? []).sorted {
                        let delta = $0.boundingBox.midY - $1.boundingBox.midY
                        return abs(delta) > 0.012 ? delta > 0 : $0.boundingBox.minX < $1.boundingBox.minX
                    }.compactMap { $0.topCandidates(1).first?.string }
                    // Remove only duplicated boundary lines, not repeated events elsewhere.
                    var duplicatePrefix = 0
                    if !lines.isEmpty {
                        for size in stride(from: min(8, min(lines.count, recognized.count)), through: 1, by: -1) {
                            if Array(lines.suffix(size)) == Array(recognized.prefix(size)) { duplicatePrefix = size; break }
                        }
                    }
                    lines.append(contentsOf: recognized.dropFirst(duplicatePrefix))
                    if top + h == image.height { break }
                    top += bandHeight - overlap
                }
                let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw ShikeError.message("图片中没有识别到文字，请选择更清晰的图片，或直接输入内容。") }
                return text
            }
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
}
