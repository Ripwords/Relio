#if canImport(Vision)
import Foundation
import Vision

public struct VisionBarcodeReader: BarcodeReading {

    public init() {}

    public func qrPayloads(inImage data: Data) async throws -> [String] {
        var request = DetectBarcodesRequest()
        request.symbologies = [.qr]
        return try await request.perform(on: data).compactMap(\.payloadString)
    }
}
#endif
