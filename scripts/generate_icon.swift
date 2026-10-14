import AppKit
import ImageIO
import UniformTypeIdentifiers

// Original vector artwork, rendered into the app icon without external assets.
let output = CommandLine.arguments[1]
let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 4096,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.scaleBy(x: 10.24, y: 10.24)
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(red: r/255, green: g/255, blue: b/255, alpha: 1) }
context.setFillColor(color(248,249,243)); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
context.setLineCap(.round); context.setLineJoin(.round)
context.setFillColor(color(246,221,117))
context.fill(CGRect(x: 13, y: 61, width: 76, height: 18))
context.setStrokeColor(color(40,53,66)); context.setLineWidth(2.2)
context.move(to: CGPoint(x: 24, y: 17))
context.addCurve(to: CGPoint(x: 82, y: 19), control1: CGPoint(x: 43, y: 16), control2: CGPoint(x: 63, y: 20))
context.addQuadCurve(to: CGPoint(x: 87, y: 25), control: CGPoint(x: 88, y: 18))
context.addLine(to: CGPoint(x: 86, y: 75))
context.addQuadCurve(to: CGPoint(x: 80, y: 82), control: CGPoint(x: 87, y: 82))
context.addLine(to: CGPoint(x: 23, y: 83))
context.addQuadCurve(to: CGPoint(x: 17, y: 75), control: CGPoint(x: 16, y: 83))
context.addLine(to: CGPoint(x: 18, y: 24))
context.addQuadCurve(to: CGPoint(x: 24, y: 17), control: CGPoint(x: 17, y: 16))
context.strokePath()
context.move(to: CGPoint(x: 18, y: 65)); context.addLine(to: CGPoint(x: 86, y: 64)); context.strokePath()
context.setLineWidth(3.5)
context.move(to: CGPoint(x: 34, y: 89)); context.addLine(to: CGPoint(x: 33, y: 74)); context.strokePath()
context.move(to: CGPoint(x: 69, y: 88)); context.addLine(to: CGPoint(x: 70, y: 73)); context.strokePath()
context.setStrokeColor(color(49,89,199)); context.setLineWidth(6)
context.move(to: CGPoint(x: 33, y: 43)); context.addLine(to: CGPoint(x: 46, y: 31)); context.addLine(to: CGPoint(x: 70, y: 53)); context.strokePath()
let image = context.makeImage()!
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
precondition(CGImageDestinationFinalize(destination))
