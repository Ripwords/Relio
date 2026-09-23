import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import TaxKit
import TaxCapture

/// Where a receipt comes from.
enum ReceiptSource: Hashable {
    case camera
    case photo
    case file
}

/// The camera, the photo library and Files, each producing a `CaptureInput`, all read by
/// the same pipeline. The editor's documents section and Home's scan button both use it,
/// so a receipt is read the same way whichever door it came in by.
struct ReceiptCaptureModifier: ViewModifier {

    @Binding var source: ReceiptSource?
    let ruleSet: RuleSet?
    let onRead: @MainActor (ReceiptReading) async -> Void
    let onError: @MainActor (String) -> Void

    @State private var pickedPhoto: PhotosPickerItem?
    @State private var isReading = false

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: isShowing(.camera)) {
                DocumentCameraView { result in
                    source = nil
                    switch result {
                    case .scanned(let pages): Task { await read(.scannedPages(pages)) }
                    case .cancelled: break
                    case .failed: onError("The camera stopped before the scan finished. Try again.")
                    }
                }
                .ignoresSafeArea()
            }
            .photosPicker(isPresented: isShowing(.photo), selection: $pickedPhoto,
                          matching: .images)
            .fileImporter(isPresented: isShowing(.file),
                          allowedContentTypes: [.image, .pdf]) { result in
                Task { await importFile(result) }
            }
            .onChange(of: pickedPhoto) { _, item in
                guard let item else { return }
                pickedPhoto = nil
                Task { await importPhoto(item) }
            }
            .overlay {
                if isReading {
                    ProgressView("Reading the receipt…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .allowsHitTesting(!isReading)
    }

    /// `source` is the single piece of state; each presenter sees only its own case.
    private func isShowing(_ kind: ReceiptSource) -> Binding<Bool> {
        Binding(get: { source == kind },
                set: { if !$0, source == kind { source = nil } })
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            onError("That photo could not be read. Try another.")
            return
        }
        await read(.image(data))
    }

    /// The security-scoped URL has to be opened and closed around the read, or the bytes
    /// come back empty for anything outside the app's own container.
    private func importFile(_ result: Result<URL, any Error>) async {
        guard case .success(let url) = result else {
            onError("That file could not be opened. Try another.")
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            onError("That file could not be read. Try another.")
            return
        }
        let isPDF = UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true
        await read(isPDF ? .pdf(data) : .image(data))
    }

    private func read(_ input: CaptureInput) async {
        isReading = true
        defer { isReading = false }
        switch await CapturePipeline.read(input, ruleSet: ruleSet) {
        case .read(let reading): await onRead(reading)
        case .failed(let message): onError(message)
        }
    }
}

extension View {
    func receiptCapture(source: Binding<ReceiptSource?>,
                        ruleSet: RuleSet?,
                        onRead: @escaping @MainActor (ReceiptReading) async -> Void,
                        onError: @escaping @MainActor (String) -> Void) -> some View {
        modifier(ReceiptCaptureModifier(source: source, ruleSet: ruleSet,
                                        onRead: onRead, onError: onError))
    }
}

/// "Scan a receipt", beside "Add an entry". The camera is listed only where it can open.
struct ReceiptSourceMenu: View {

    @Binding var source: ReceiptSource?

    var body: some View {
        Menu {
            if DocumentCameraView.isSupported {
                Button { source = .camera } label: {
                    Label("Scan with the camera", systemImage: "doc.viewfinder")
                }
            }
            Button { source = .photo } label: {
                Label("Choose a photo", systemImage: "photo")
            }
            Button { source = .file } label: {
                Label("Choose a file", systemImage: "folder")
            }
        } label: {
            Image(systemName: "doc.viewfinder")
        }
        .accessibilityLabel("Scan a receipt")
    }
}
