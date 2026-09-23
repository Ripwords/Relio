import SwiftUI
import VisionKit

/// VisionKit's document camera: edge detection, perspective correction and multi-page
/// capture, none of which Relio should rebuild.
struct DocumentCameraView: UIViewControllerRepresentable {

    enum Result {
        /// One upright JPEG per page, in order.
        case scanned([Data])
        case cancelled
        case failed
    }

    /// False on the simulator and on hardware without a camera. The menu hides the
    /// option rather than offering something that cannot open.
    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    let onFinish: @MainActor (Result) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
        let onFinish: @MainActor (Result) -> Void

        init(onFinish: @escaping @MainActor (Result) -> Void) {
            self.onFinish = onFinish
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            let pages = (0..<scan.pageCount).compactMap {
                scan.imageOfPage(at: $0).jpegData(compressionQuality: 0.9)
            }
            onFinish(pages.isEmpty ? .cancelled : .scanned(pages))
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish(.cancelled)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: any Error) {
            onFinish(.failed)
        }
    }
}
