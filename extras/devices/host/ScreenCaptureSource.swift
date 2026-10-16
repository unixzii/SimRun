import AppKit
import ScreenCaptureKit
import CoreImage

/// Capture only the desktop pixels behind the corresponding SimRun viewport.
/// Host screen permission is separate from the simulated App camera permission.
final class ScreenCaptureSource: NSObject, ObservableObject {
    static let shared = ScreenCaptureSource()
    let fps = 15
    @Published private(set) var status = "Screen recording not started"
    @Published private(set) var frameCount: UInt64 = 0
    var onUnavailable: ((String) -> Void)?

    private let frameQueue = DispatchQueue(label: "dev.simrun.camera.screen")
    private let context = CIContext()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let lock = NSLock()
    // The pixel state is shared by the capture queue and frame socket queue.
    private var latest: CIImage?
    private var encoded: ProducedFrame?
    private var acceptedStream: ObjectIdentifier?
    private var outputSize = CGSize.zero
    private var pixelOffset = CGPoint.zero
    private var acceptFramesAfter: UInt64 = 0
    private var capturedFrames: UInt64 = 0
    // All remaining management state is confined to the main queue.
    private var consumers: [UUID: pid_t] = [:]
    private var stream: SCStream?
    private var filter: SCContentFilter?
    private var selecting = false
    private var epoch: UInt64 = 0
    private var followTimer: DispatchSourceTimer?
    private var lastGeometry: WindowGeometry?
    private var updatingGeometry = false

    private struct WindowGeometry: Equatable {
        let appPID: pid_t
        let hostPID: pid_t
        let windowID: UInt32
        let displayID: UInt32
        let rect: CGRect
        let scale: CGFloat
    }
    private struct CapturePlan {
        let configuration: SCStreamConfiguration
        let geometry: WindowGeometry
        let output: CGSize
        let offset: CGPoint
    }

    private func geometry() -> WindowGeometry? {
        guard let pid = consumers.values.first else { return nil }
        return Self.geometry(clientPID: pid)
    }

    private static func geometry(clientPID pid: pid_t) -> WindowGeometry? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/SimRun/window-geometry/\(pid).json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["schema"] as? Int) == 1, (json["appPid"] as? pid_t) == pid,
              (json["visible"] as? Bool) == true,
              let host = json["hostPid"] as? pid_t, host > 0, kill(host, 0) == 0,
              let window = json["windowID"] as? UInt32,
              let display = json["displayID"] as? UInt32,
              let scale = json["backingScale"] as? Double, scale.isFinite, scale > 0,
              let rect = json["screenRect"] as? [String: Double],
              let x = rect["x"], let y = rect["y"], let w = rect["width"], let h = rect["height"],
              [x,y,w,h].allSatisfy({ $0.isFinite }), w > 0, h > 0, w <= 8192, h <= 8192
        else { return nil }
        return WindowGeometry(appPID: pid, hostPID: host, windowID: window, displayID: display,
                              rect: CGRect(x: x, y: y, width: w, height: h), scale: scale)
    }

    /// Read the same authoritative viewport used by capture, without starting
    /// ScreenCaptureKit or inventing a camera size when no window is available.
    static func frameSize(clientPID: pid_t) -> CGSize? {
        guard let geometry = geometry(clientPID: clientPID) else { return nil }
        let size = CGSize(width: floor(geometry.rect.width * geometry.scale / 2) * 2,
                          height: floor(geometry.rect.height * geometry.scale / 2) * 2)
        guard size.width >= 2, size.height >= 2, size.width <= 8192, size.height <= 8192 else { return nil }
        return size
    }

    func acquire(clientPID: pid_t?) -> UUID {
        let token = UUID()
        DispatchQueue.main.async { [self] in
            guard let clientPID, clientPID > 0 else { onUnavailable?("A SimRun App PID is required"); return }
            consumers[token] = clientPID
            if stream == nil && !selecting { useMainDisplay() }
        }
        return token
    }
    func release(_ token: UUID) {
        DispatchQueue.main.async { [self] in
            consumers.removeValue(forKey: token)
            if consumers.isEmpty { stopCapture() }
        }
    }

    /// Snapshot the current native pixels. Off-display parts are black; there
    /// is no scale transform and no placeholder frame after permission loss.
    func latestFrame() -> ProducedFrame? {
        lock.lock(); defer { lock.unlock() }
        if let encoded { return encoded }
        guard let image = latest else { return nil }
        let width = Int(outputSize.width), height = Int(outputSize.height)
        guard width >= 2, height >= 2, width <= 8192, height <= 8192 else { return nil }
        let copyWidth = min(CGFloat(width) - pixelOffset.x, image.extent.width)
        let copyHeight = min(CGFloat(height) - pixelOffset.y, image.extent.height)
        guard copyWidth > 0, copyHeight > 0 else { return nil }
        let crop = CGRect(x: image.extent.minX, y: image.extent.maxY - copyHeight,
                          width: copyWidth, height: copyHeight)
        let pixels = image.cropped(to: crop).transformed(by: CGAffineTransform(
            translationX: pixelOffset.x - crop.minX,
            y: CGFloat(height) - copyHeight - crop.minY - pixelOffset.y))
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let output = pixels.composited(over: CIImage(color: .black).cropped(to: canvas)).cropped(to: canvas)
        guard let jpeg = context.jpegRepresentation(of: output, colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9]) else { return nil }
        let frame = ProducedFrame(jpeg: jpeg, width: UInt16(width), height: UInt16(height))
        encoded = frame
        return frame
    }

    /// May be called from the panel before the test App starts its camera.
    func requestPermission() {
        dispatchPrecondition(condition: .onQueue(.main))
        if CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() {
            if consumers.isEmpty { status = "Screen Recording authorized; open the camera in the test App" }
            else { useMainDisplay() }
        } else {
            status = "Enable SimRun in System Settings > Screen & System Audio Recording"
        }
    }

    /// Resolve the display from authoritative SimRun geometry, never by title.
    func useMainDisplay() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !selecting else { return }
        stopCapture()
        guard let geometry = geometry() else { fail("A visible SimRun window is required"); return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            fail("Host Screen Recording permission is required; enable SimRun in System Settings")
            return
        }
        selecting = true
        let currentEpoch = epoch
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self, self.epoch == currentEpoch else { return }
                self.selecting = false
                guard let current = self.geometry() else { self.fail("SimRun window is no longer visible"); return }
                guard current.displayID == geometry.displayID else { self.useMainDisplay(); return }
                guard let display = content?.displays.first(where: { $0.displayID == geometry.displayID }) else {
                    self.fail(error?.localizedDescription ?? "Display is unavailable"); return
                }
                let excluded = content?.windows.filter {
                    $0.owningApplication?.processID == current.hostPID ||
                    $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
                } ?? []
                guard excluded.contains(where: { $0.windowID == current.windowID }) else {
                    self.fail("SimRun window geometry is no longer current"); return
                }
                let excludedApplications = content?.applications.filter {
                    $0.processID == current.hostPID || $0.processID == ProcessInfo.processInfo.processIdentifier
                } ?? []
                self.begin(filter: SCContentFilter(display: display, excludingApplications: excludedApplications, exceptingWindows: []))
            }
        }
    }

    private func fail(_ reason: String) {
        stopCapture()
        status = reason
        NSLog("[screen-camera] %@", reason)
        onUnavailable?(reason)
    }
    private func stopCapture() {
        epoch &+= 1
        selecting = false; updatingGeometry = false
        followTimer?.cancel(); followTimer = nil
        let old = stream
        stream = nil; filter = nil; lastGeometry = nil
        lock.lock()
        acceptedStream = nil; latest = nil; encoded = nil; acceptFramesAfter = 0
        lock.unlock()
        old?.stopCapture { _ in }
    }

    private func capturePlan(filter: SCContentFilter) -> CapturePlan? {
        guard let geometry = geometry() else { return nil }
        let scale = CGFloat(filter.pointPixelScale)
        guard scale > 0 else { return nil }
        let display = CGDisplayBounds(geometry.displayID)
        let rect = CGRect(x: (geometry.rect.minX * scale).rounded() / scale,
                          y: (geometry.rect.minY * scale).rounded() / scale,
                          width: floor(geometry.rect.width * scale) / scale,
                          height: floor(geometry.rect.height * scale) / scale)
        let clipped = rect.intersection(display)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
        // NV12 requires even dimensions. Trim at most one right/bottom pixel.
        let output = CGSize(width: floor(rect.width * scale / 2) * 2,
                            height: floor(rect.height * scale / 2) * 2)
        guard output.width >= 2, output.height >= 2, output.width <= 8192, output.height <= 8192 else { return nil }
        let offset = CGPoint(x: (clipped.minX - rect.minX) * scale, y: (clipped.minY - rect.minY) * scale)
        let config = SCStreamConfiguration()
        config.sourceRect = clipped.offsetBy(dx: -display.minX, dy: -display.minY)
        config.width = max(2, Int(floor(clipped.width * scale)))
        config.height = max(2, Int(floor(clipped.height * scale)))
        config.scalesToFit = false
        config.destinationRect = CGRect(x: 0, y: 0, width: config.width, height: config.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.capturesAudio = false; config.captureMicrophone = false
        config.showsCursor = true; config.captureDynamicRange = .SDR
        return CapturePlan(configuration: config, geometry: geometry, output: output, offset: offset)
    }

    private func begin(filter: SCContentFilter) {
        guard !consumers.isEmpty, let plan = capturePlan(filter: filter) else {
            fail("SimRun crop is unavailable or outside the display"); return
        }
        self.filter = filter
        lastGeometry = plan.geometry
        let currentEpoch = epoch
        let next = SCStream(filter: filter, configuration: plan.configuration, delegate: self)
        do { try next.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue) }
        catch { fail(error.localizedDescription); return }
        stream = next
        lock.lock()
        acceptedStream = ObjectIdentifier(next); outputSize = plan.output; pixelOffset = plan.offset
        lock.unlock()
        status = "Starting native-pixel screen camera"
        NSLog("[screen-camera] native crop %.1f,%.1f %ldx%ld output %.0fx%.0f; no resampling", plan.configuration.sourceRect.minX, plan.configuration.sourceRect.minY, plan.configuration.width, plan.configuration.height, plan.output.width, plan.output.height)
        next.startCapture { [weak self, weak next] error in
            DispatchQueue.main.async {
                guard let self, self.epoch == currentEpoch, let next, self.stream === next else { return }
                if let error { self.fail(error.localizedDescription); return }
                self.status = "Live native pixels \(Int(plan.output.width))×\(Int(plan.output.height))"
                let timer = DispatchSource.makeTimerSource(queue: .main)
                timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
                timer.setEventHandler { [weak self] in self?.refreshGeometry() }
                timer.resume(); self.followTimer = timer
            }
        }
    }

    // Called before requiring an image buffer: blank/suspended/stopped samples
    // may have none. They must invalidate cached photographs immediately.
    private enum FrameDisposition { case accept, ignore, interrupt }
    private func handleFrameStatus(_ status: SCFrameStatus, from identity: ObjectIdentifier) -> FrameDisposition {
        lock.lock(); defer { lock.unlock() }
        guard acceptedStream == identity else { return .ignore }
        switch status {
        case .complete, .started: return .accept
        case .idle: return .ignore
        case .blank, .suspended, .stopped:
            acceptedStream = nil; latest = nil; encoded = nil
            return .interrupt
        @unknown default:
            acceptedStream = nil; latest = nil; encoded = nil
            return .interrupt
        }
    }

    private func refreshGeometry() {
        guard !updatingGeometry, let stream, let filter else { return }
        guard let geometry = geometry() else { fail("SimRun window is hidden or no longer available"); return }
        guard geometry != lastGeometry else { return }
        if geometry.displayID != lastGeometry?.displayID { useMainDisplay(); return }
        guard let plan = capturePlan(filter: filter) else { fail("SimRun crop is outside the display"); return }
        updatingGeometry = true
        let currentEpoch = epoch
        lock.lock(); latest = nil; encoded = nil; acceptFramesAfter = UInt64.max; lock.unlock()
        stream.updateConfiguration(plan.configuration) { [weak self, weak stream] error in
            DispatchQueue.main.async {
                guard let self, self.epoch == currentEpoch, self.stream === stream else { return }
                self.updatingGeometry = false
                if let error { self.fail(error.localizedDescription); return }
                self.lastGeometry = plan.geometry
                self.lock.lock()
                self.outputSize = plan.output; self.pixelOffset = plan.offset
                self.acceptFramesAfter = mach_absolute_time()
                self.lock.unlock()
                self.status = "Live native pixels \(Int(plan.output.width))×\(Int(plan.output.height))"
                NSLog("[screen-camera] followed window crop %.1f,%.1f %ldx%ld output %.0fx%.0f", plan.configuration.sourceRect.minX, plan.configuration.sourceRect.minY, plan.configuration.width, plan.configuration.height, plan.output.width, plan.output.height)
            }
        }
    }
}

extension ScreenCaptureSource: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        let wasActive = acceptedStream == ObjectIdentifier(stream)
        if wasActive { acceptedStream = nil; latest = nil; encoded = nil }
        lock.unlock()
        guard wasActive else { return }
        DispatchQueue.main.async { [self] in
            guard self.stream === stream else { return }
            fail(error.localizedDescription)
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw)
        else { return }
        switch handleFrameStatus(status, from: ObjectIdentifier(stream)) {
        case .ignore: return
        case .interrupt:
            DispatchQueue.main.async { [self] in
                guard self.stream === stream else { return }
                fail("Screen capture became blank, suspended, or stopped; reopen the camera to resume")
            }
            return
        case .accept: break
        }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        guard acceptedStream == ObjectIdentifier(stream),
              ((attachments.first?[.displayTime] as? NSNumber)?.uint64Value ?? 0) >= acceptFramesAfter
        else { lock.unlock(); return }
        latest = CIImage(cvPixelBuffer: buffer); encoded = nil
        capturedFrames &+= 1
        let count = capturedFrames
        lock.unlock()
        if count == 1 || count % 15 == 0 {
            DispatchQueue.main.async { [weak self] in self?.frameCount = count }
            NSLog("[screen-camera] captured real frame %llu (%dx%d)", count, CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
        }
    }
}

final class ScreenFrameProducer: FrameProducer {
    let fps = 15
    private var token: UUID?
    init(size: CGSize? = nil, clientPID: pid_t? = nil) {
        // The viewport's host pixels determine the output, not iPhone Retina size.
        token = ScreenCaptureSource.shared.acquire(clientPID: clientPID)
    }
    func nextFrame() -> ProducedFrame? { token == nil ? nil : ScreenCaptureSource.shared.latestFrame() }
    func stop() {
        guard let token else { return }
        self.token = nil
        ScreenCaptureSource.shared.release(token)
    }
    deinit { stop() }
}
