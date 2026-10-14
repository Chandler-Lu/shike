import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import ShikeCore

struct PasteImportButton: UIViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    let receive: ([NSItemProvider]) -> Void
    func makeUIView(context: Context) -> PasteReceiver {
        let view = PasteReceiver()
        view.receive = receive
        view.updateAppearance(dark: colorScheme == .dark)
        return view
    }
    func updateUIView(_ uiView: PasteReceiver, context: Context) {
        uiView.receive = receive
        uiView.updateAppearance(dark: colorScheme == .dark)
        uiView.isUserInteractionEnabled = isEnabled
        uiView.alpha = isEnabled ? 1 : 0.45
    }
}

final class PasteReceiver: UIView {
    var receive: (([NSItemProvider]) -> Void)?
    private var control: UIPasteControl?
    private var darkAppearance: Bool?
    override init(frame: CGRect) {
        super.init(frame: frame)
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.plainText.identifier, UTType.image.identifier])
    }
    func updateAppearance(dark: Bool) {
        guard darkAppearance != dark else { return }
        darkAppearance = dark
        control?.removeFromSuperview()
        let config = UIPasteControl.Configuration()
        config.displayMode = .iconAndLabel
        // UIPasteControl renders its own backdrop; transparent base colors can
        // become an opaque black fill after the system's highlight transition.
        config.baseBackgroundColor = dark ? UIColor(red: 0.11, green: 0.14, blue: 0.17, alpha: 1) : UIColor(red: 248/255, green: 249/255, blue: 243/255, alpha: 1)
        config.baseForegroundColor = dark ? UIColor(red: 0.91, green: 0.94, blue: 0.89, alpha: 1) : UIColor(red: 40/255, green: 53/255, blue: 66/255, alpha: 1)
        let control = UIPasteControl(configuration: config)
        self.control = control
        control.target = self
        control.accessibilityIdentifier = "nativePasteControl"
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        NSLayoutConstraint.activate([control.centerXAnchor.constraint(equalTo: centerXAnchor), control.centerYAnchor.constraint(equalTo: centerYAnchor), control.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)])
        accessibilityIdentifier = "pasteImport"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func paste(itemProviders: [NSItemProvider]) { receive?(itemProviders) }
}

struct CameraPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onImage: (Data) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(parent: CameraPicker) { self.parent = parent }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.88) { parent.onImage(data) }
            parent.dismiss()
        }
    }
}
