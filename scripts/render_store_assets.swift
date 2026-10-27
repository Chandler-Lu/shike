// Native pixel export and deterministic typography for the 2026-10-27 store refresh.
// swift scripts/render_store_assets.swift OUTPUT_DIRECTORY
// swift scripts/render_store_assets.swift --opaque WIDTH HEIGHT SOURCE DESTINATION [...]
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let fontURL = root.appendingPathComponent("Shared/Resources/Fonts/LXGWWenKai-Regular.ttf")
CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
let ink = NSColor(srgbRed: 40/255, green: 53/255, blue: 66/255, alpha: 1)
let safeArea = CGRect(x: 1921, y: 660, width: 1402, height: 962)

func load(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("Unreadable image: \(url.path)")
    }
    return image
}

func save(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Cannot write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
}

func canvas(_ width: Int, _ height: Int, draw: () -> Void) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                           bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()!
}

func picture(_ image: CGImage, in rect: CGRect) {
    NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        .draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
              hints: [.interpolation: NSImageInterpolation.high])
}

func text(_ value: String, in rect: CGRect, size: CGFloat, handwritten: Bool = true) {
    let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
    let font = handwritten ? NSFont(name: "LXGWWenKai-Regular", size: size)! : NSFont.systemFont(ofSize: size)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink, .paragraphStyle: paragraph]
    let bounds = (value as NSString).boundingRect(with: rect.size, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
    precondition(bounds.height <= rect.height && bounds.width <= rect.width, "Text overflows: \(value)")
    (value as NSString).draw(in: rect, withAttributes: attributes)
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--opaque" {
    precondition(args.count >= 5 && (args.count - 3) % 2 == 0)
    let width = Int(args[1])!, height = Int(args[2])!
    for index in stride(from: 3, to: args.count, by: 2) {
        let source = load(URL(fileURLWithPath: args[index]))
        precondition(source.width == width && source.height == height, "Native size mismatch; never resize UI")
        // Draw at exactly 1:1 into an opaque sRGB bitmap. No cropping or enhancement.
        let result = canvas(width, height) { picture(source, in: CGRect(x: 0, y: 0, width: width, height: height)) }
        try save(result, to: URL(fileURLWithPath: args[index + 1]))
    }
    exit(0)
}

let output = URL(fileURLWithPath: args.first ?? "docs/app-store/refresh-2026-10-27", isDirectory: true)
let mascot = load(output.appendingPathComponent("sources/companions-clean.png"))
let titleRect = CGRect(x: 1981, y: 704, width: 1282, height: 186)
let artRect = CGRect(x: 2202, y: 892, width: 840, height: 560)
let taglineRect = CGRect(x: 1981, y: 1490, width: 1282, height: 100)
for rect in [titleRect, artRect, taglineRect] { precondition(safeArea.contains(rect), "Artwork leaves Apple's safe area") }
let master = canvas(5244, 2950) {
    text("拾刻计划", in: titleRect, size: 150)
    picture(mascot, in: artRect)
    text("轻轻收好每个重要日子", in: taglineRect, size: 82)
}
try save(master, to: output.appendingPathComponent("universal-5244x2950.png"))
let overlay = canvas(5244, 2950) {
    picture(master, in: CGRect(x: 0, y: 0, width: 5244, height: 2950))
    NSColor(srgbRed: 0.10, green: 0.55, blue: 0.35, alpha: 1).setStroke()
    let border = NSBezierPath(rect: safeArea); border.lineWidth = 6; border.stroke()
    text("Apple Art Safe Area · 1402 × 962", in: CGRect(x: 1722, y: 1700, width: 1800, height: 100), size: 60, handwritten: false)
}
try save(overlay, to: output.appendingPathComponent("previews/safe-area-overlay.png"))
// These are local crop stress checks, not App Store Connect screenshots.
let crops: [(String, CGRect)] = [
    ("phone-header-crop", CGRect(x: 1572, y: 240, width: 2100, height: 1400)),
    ("search-3x2-crop", CGRect(x: 1572, y: 420, width: 2100, height: 1400)),
    ("wide-header-21x9-crop", CGRect(x: 0, y: 352, width: 5244, height: 2247))
]
for (name, rect) in crops {
    precondition(rect.contains(safeArea))
    try save(master.cropping(to: rect)!, to: output.appendingPathComponent("previews/\(name).png"))
}
let names = ["import", "results", "review", "editor", "settings", "planning", "calendar", "countdowns"]
for (folder, width, height, columns, cellWidth) in [("zh-Hans", 1179, 2556, 4, 340), ("iphone-duo-zh-Hans", 2853, 2007, 2, 800), ("ipad-13-zh-Hans", 2752, 2064, 2, 800)] {
    let paths = names.enumerated().map { output.appendingPathComponent("screenshots/\(folder)/store-\(String(format: "%02d", $0.offset + 1))-\($0.element).png") }
    guard paths.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { continue }
    let imageHeight = cellWidth * height / width
    let cellHeight = imageHeight + 56
    let overview = canvas(columns * (cellWidth + 24) + 24, (8 / columns) * cellHeight + 24) {
        for (index, path) in paths.enumerated() {
            let x = 24 + (index % columns) * (cellWidth + 24), y = 24 + (index / columns) * cellHeight
            picture(load(path), in: CGRect(x: x, y: y, width: cellWidth, height: imageHeight))
            text("\(index + 1) · \(names[index])", in: CGRect(x: x, y: y + imageHeight + 8, width: cellWidth, height: 35), size: 20, handwritten: false)
        }
    }
    try save(overview, to: output.appendingPathComponent("previews/\(folder)-overview.png"))
}
print("Rendered universal artwork, safe-area checks and available screenshot overviews.")
