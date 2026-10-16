// Adapted from CAMouflage (MIT); see ../third-party/CAMouflage-LICENSE.
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ProducedFrame {
    let jpeg: Data
    let width: UInt16
    let height: UInt16
}

protocol FrameProducer: AnyObject {
    var fps: Int { get }
    func nextFrame() -> ProducedFrame?
    func stop()
}
extension FrameProducer { func stop() {} }

struct CameraProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct CameraSource {
    enum Kind { case image }
    let kind: Kind
    let path: String?
    let encodedData: String?

    init(json: [String: Any]) throws {
        guard let name = json["kind"] as? String else { throw CameraProviderError("source.kind is required") }
        switch name {
        case "screen": throw CameraProviderError("Screen source is unsupported in this build; use image")
        case "image": kind = .image
        default: throw CameraProviderError("Unsupported camera source '\(name)'; supported: image")
        }
        path = json["path"] as? String
        encodedData = json["dataBase64"] as? String
        if kind == .image && path == nil && encodedData == nil {
            throw CameraProviderError("Image source requires an absolute path or dataBase64")
        }
        if let path, !path.hasPrefix("/") { throw CameraProviderError("Image path must be absolute") }
    }
}

struct CameraDevice {
    let id: String
    let name: String
    let position: String
    let source: CameraSource
    var wire: [String: Any] { ["id": id, "name": name, "position": position] }

    static func configuration(_ value: Any?) throws -> [CameraDevice] {
        guard let config = value as? [String: Any], let entries = config["devices"] as? [[String: Any]],
              !entries.isEmpty, entries.count <= 8 else { throw CameraProviderError("configuration.devices must contain 1...8 cameras") }
        var ids = Set<String>()
        return try entries.map { entry in
            guard let id = entry["id"] as? String, !id.isEmpty, id.utf8.count <= 256, ids.insert(id).inserted,
                  let source = entry["source"] as? [String: Any] else { throw CameraProviderError("Each camera needs a unique id and explicit source") }
            let position = entry["position"] as? String ?? "back"
            guard ["back", "front", "unspecified"].contains(position) else { throw CameraProviderError("Invalid camera position") }
            return CameraDevice(id: id, name: entry["name"] as? String ?? "SimRun Camera", position: position,
                                source: try CameraSource(json: source))
        }
    }
}

func makeFrameProducer(for source: CameraSource, screenSize: CGSize?, clientPID: pid_t) throws -> FrameProducer {
    switch source.kind {
    case .image: return try ImageFrameProducer(source: source)
    }
}

private final class ImageFrameProducer: FrameProducer {
    let fps = 5
    private let frame: ProducedFrame
    private var active = true
    init(source: CameraSource) throws {
        let data: Data?
        if let encoded = source.encodedData { data = Data(base64Encoded: encoded) }
        else if let path = source.path { data = try? Data(contentsOf: URL(fileURLWithPath: path)) }
        else { data = nil }
        guard let data, data.count <= 32 * 1024 * 1024,
              let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
              image.width >= 2, image.height >= 2, image.width <= 8192, image.height <= 8192 else {
            throw CameraProviderError("Image source cannot be decoded or exceeds 8192 pixels per dimension")
        }
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CameraProviderError("JPEG encoder is unavailable")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CameraProviderError("JPEG encoding failed") }
        frame = ProducedFrame(jpeg: jpeg as Data, width: UInt16(image.width), height: UInt16(image.height))
    }
    func nextFrame() -> ProducedFrame? { active ? frame : nil }
    func stop() { active = false }
}
