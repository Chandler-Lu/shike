#if DEBUG
import SwiftUI

// Tests the real system Share sheet and the separate extension process.
// This entry point is absent in Release and hidden without an explicit launch argument.
struct ShareFixtureSheet: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 650), format: format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 650))
            let text = "2026年10月14日 14:00 - 15:30\n产品设计评审，三楼会议室\n带上新的交互稿\n\n2026年10月15日 10:00\n和小林在街角咖啡馆喝咖啡"
            (text as NSString).draw(in: CGRect(x: 50, y: 45, width: 1100, height: 560), withAttributes: [.font: UIFont.systemFont(ofSize: 46), .foregroundColor: UIColor.black])
        }
        return UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
