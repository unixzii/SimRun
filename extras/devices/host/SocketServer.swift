// Protocol derived from CAMouflage (MIT); transport is local to SimRun.
// See ../third-party/CAMouflage-LICENSE. No SimBridgeKit dependency.
import Foundation
import Darwin

/// All sockets, clients, sessions and producers are confined to ioQueue.
final class CameraSocketServer {
    private let ioQueue = DispatchQueue(label: "dev.simrun.camera.io")
    private let controlPath = "/tmp/simrun-camera-\(getuid()).sock"
    private let framePath = "/tmp/simrun-camera-\(getuid())-frames.sock"
    private var listeners: [DispatchSourceRead] = []
    private var ownedPaths: [String] = []
    private var lockFD: Int32 = -1
    private var controlFD: Int32 = -1
    private var controlPID: pid_t = 0
    private var controlSource: DispatchSourceRead?
    private var controlBuffer = Data()
    private var helloReceived = false
    private var helloTimeout: DispatchWorkItem?
    private var connectionEpoch: UInt64 = 0
    private var devices: [CameraDevice] = []
    private var sessions: [UInt32: Session] = [:]
    var onStatus: ((String) -> Void)?

    private final class Session {
        let id: UInt32
        let deviceID: String
        let size: CGSize?
        let clientPID: pid_t
        var producer: FrameProducer
        var fd: Int32 = -1
        var timer: DispatchSourceTimer?
        var lastPTS: UInt64 = 0
        init(id: UInt32, deviceID: String, size: CGSize?, clientPID: pid_t, producer: FrameProducer) {
            self.id = id; self.deviceID = deviceID; self.size = size; self.clientPID = clientPID; self.producer = producer
        }
        func stop() {
            timer?.cancel(); timer = nil
            producer.stop()
            if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd); fd = -1 }
        }
    }

    func start() throws {
        try ioQueue.sync {
            guard listeners.isEmpty else { return }
            do {
                try acquireOwnership()
                try listen(path: controlPath, frames: false)
                try listen(path: framePath, frames: true)
                status("Ready; no camera source configured")
            } catch {
                cleanup()
                throw error
            }
        }
    }

    func stop() { ioQueue.sync { cleanup() } }

    private func status(_ value: String) {
        NSLog("[simrun-camera-provider] %@", value)
        DispatchQueue.main.async { [weak self] in self?.onStatus?(value) }
    }

    private func acquireOwnership() throws {
        let path = "/tmp/simrun-camera-\(getuid()).lock"
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CameraProviderError("Cannot open camera ownership lock") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
              fchmod(fd, 0o600) == 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw CameraProviderError("Another camera provider is active or the lock is not owned by this user")
        }
        lockFD = fd
    }

    private func unlinkOwnedSocket(_ path: String) {
        var info = stat()
        if lstat(path, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFSOCK { unlink(path) }
    }

    private func listen(path: String, frames: Bool) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let count = path.utf8CString.count
        guard count <= MemoryLayout.size(ofValue: address.sun_path) else { throw CameraProviderError("Socket path is too long") }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.utf8CString.withUnsafeBufferPointer { bytes in
                UnsafeMutableRawPointer(pointer).copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            }
        }
        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFSOCK, existing.st_uid == getuid() else {
                throw CameraProviderError("Refusing socket path not owned by this user: \(path)")
            }
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            guard probe >= 0 else { throw CameraProviderError("Cannot probe existing socket") }
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            let probeError = errno
            close(probe)
            guard connected != 0, probeError == ECONNREFUSED || probeError == ENOENT else {
                throw CameraProviderError("Another camera provider owns \(path)")
            }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CameraProviderError("socket() failed: \(errno)") }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { close(fd); throw CameraProviderError("bind() failed: \(errno)") }
        guard chmod(path, 0o600) == 0, Darwin.listen(fd, 4) == 0 else {
            close(fd); unlink(path); throw CameraProviderError("Cannot listen on private camera socket")
        }
        ownedPaths.append(path)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [weak self] in self?.accept(listener: fd, frames: frames) }
        source.setCancelHandler { close(fd) }
        listeners.append(source); source.resume()
    }

    private func peer(_ fd: Int32) -> pid_t? {
        var uid: uid_t = 0, gid: gid_t = 0, pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(),
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { return nil }
        return pid
    }

    private func configure(_ fd: Int32) -> Bool {
        var enabled: Int32 = 1
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 &&
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 &&
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0
    }

    private func accept(listener: Int32, frames: Bool) {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return }
        guard configure(fd), let pid = peer(fd) else { close(fd); return }
        if frames { acceptFrames(fd, pid: pid); return }
        guard controlFD < 0 else {
            _ = sendJSON(["type":"connectionRejected", "code":"clientBusy"], to: fd)
            close(fd)
            return
        }
        controlFD = fd; controlPID = pid; helloReceived = false; connectionEpoch &+= 1
        controlBuffer.removeAll()
        let epoch = connectionEpoch
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [weak self] in
            guard let self, self.controlFD == fd, self.connectionEpoch == epoch else { return }
            self.readControl()
        }
        controlSource = source; source.resume()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.connectionEpoch == epoch, !self.helloReceived else { return }
            self.disconnect()
        }
        helloTimeout = timeout
        ioQueue.asyncAfter(deadline: .now() + 3, execute: timeout)
        status("Client connected: PID \(pid); waiting for hello")
    }

    private func readControl() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let n = read(controlFD, &buffer, buffer.count)
        if n < 0 && errno == EINTR { return }
        guard n > 0 else { disconnect(); return }
        controlBuffer.append(contentsOf: buffer.prefix(n))
        guard controlBuffer.count <= 32 * 1024 * 1024 else { disconnect(); return }
        while let newline = controlBuffer.firstIndex(of: 10) {
            let line = Data(controlBuffer.prefix(upTo: newline))
            controlBuffer.removeSubrange(...newline)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { disconnect(); return }
            handle(json)
            if controlFD < 0 { return }
        }
    }

    private static func integer(_ value: Any?, max: Double) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite && value > 0 && value <= max && value.rounded(.towardZero) == value ? value : nil
    }

    private func handle(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { disconnect(); return }
        if type == "hello" {
            guard !helloReceived, let pid = Self.integer(message["pid"], max: Double(Int32.max)), pid_t(pid) == controlPID else {
                _ = sendJSON(["type":"connectionRejected", "code":"identityMismatch"], to: controlFD)
                disconnect(); return
            }
            helloReceived = true; helloTimeout?.cancel(); helloTimeout = nil
            status("Client ready: PID \(controlPID)")
            return
        }
        guard helloReceived else { disconnect(); return }
        switch type {
        case "listDevices": send(["type":"didListDevices", "devices":devices.map(\.wire)])
        case "setMockConfiguration":
            do {
                let next = try CameraDevice.configuration(message["configuration"])
                // Validate image decoding before replacing a working configuration.
                for device in next where device.source.kind == .image {
                    let probe = try makeFrameProducer(for: device.source, screenSize: nil, clientPID: controlPID)
                    probe.stop()
                }
                devices = next
                for id in Array(sessions.keys) {
                    guard let session = sessions[id] else { continue }
                    guard let device = devices.first(where: { $0.id == session.deviceID }) else { interrupt(id, reason: "Camera removed by configuration"); continue }
                    do {
                        let nextProducer = try makeFrameProducer(for: device.source, screenSize: session.size, clientPID: session.clientPID)
                        session.producer.stop(); session.producer = nextProducer
                        if session.fd >= 0 { startTimer(session) }
                    } catch { interrupt(id, reason: error.localizedDescription) }
                }
                send(["type":"didSetMockConfiguration", "ok":true])
                send(["type":"devicesChanged", "devices":devices.map(\.wire)])
            } catch { send(["type":"didSetMockConfiguration", "ok":false, "error":error.localizedDescription]) }
        case "clearMockConfiguration":
            for id in Array(sessions.keys) { interrupt(id, reason: "Camera configuration cleared") }
            devices.removeAll()
            send(["type":"didSetMockConfiguration", "ok":true])
            send(["type":"devicesChanged", "devices":[]])
        case "startSession": startSession(message)
        case "stopSession":
            guard let number = Self.integer(message["sessionId"], max: Double(UInt32.max)) else { return }
            let id = UInt32(number)
            sessions.removeValue(forKey: id)?.stop()
            send(["type":"didStopSession", "sessionId":id])
        case "capturePhoto":
            guard let number = Self.integer(message["sessionId"], max: Double(UInt32.max)),
                  let request = Self.integer(message["requestId"], max: Double(UInt32.max)) else { return }
            let id = UInt32(number), requestID = UInt32(request)
            if let frame = sessions[id]?.producer.nextFrame() {
                send(["type":"didCapturePhoto", "sessionId":id, "requestId":requestID, "ok":true,
                      "width":frame.width, "height":frame.height, "dataBase64":frame.jpeg.base64EncodedString()])
            } else {
                send(["type":"didCapturePhoto", "requestId":requestID, "ok":false, "error":"No current frame for this camera session"])
            }
        default: send(["type":"protocolError", "error":"Unsupported message type '\(type)'"])
        }
    }

    private func startSession(_ message: [String: Any]) {
        guard let number = Self.integer(message["sessionId"], max: Double(UInt32.max)) else { return }
        let id = UInt32(number)
        guard let deviceID = message["deviceId"] as? String, let device = devices.first(where: { $0.id == deviceID }) else {
            send(["type":"didStartSession", "sessionId":id, "ok":false, "error":"Camera has no configured source"]); return
        }
        if let supplied = message["clientPid"] {
            guard let pid = Self.integer(supplied, max: Double(Int32.max)), pid_t(pid) == controlPID else {
                send(["type":"didStartSession", "sessionId":id, "ok":false, "error":"Session PID does not match socket peer"]); return
            }
        }
        guard sessions[id] != nil || sessions.count < 8 else {
            send(["type":"didStartSession", "sessionId":id, "ok":false, "error":"Too many camera sessions"]); return
        }
        var size: CGSize?
        if let w = Self.integer(message["screenWidth"], max: 8192), let h = Self.integer(message["screenHeight"], max: 8192),
           w.truncatingRemainder(dividingBy: 2) == 0, h.truncatingRemainder(dividingBy: 2) == 0 { size = CGSize(width:w,height:h) }
        do {
            let producer = try makeFrameProducer(for: device.source, screenSize: size, clientPID: controlPID)
            sessions.removeValue(forKey: id)?.stop()
            sessions[id] = Session(id:id,deviceID:deviceID,size:size,clientPID:controlPID,producer:producer)
            send(["type":"didStartSession", "sessionId":id, "ok":true])
            status("Camera session \(id) started")
        } catch { send(["type":"didStartSession", "sessionId":id, "ok":false, "error":error.localizedDescription]) }
    }

    private func acceptFrames(_ fd: Int32, pid: pid_t) {
        guard helloReceived, pid == controlPID else { close(fd); return }
        var line = Data()
        var terminated = false
        let started = Date()
        while line.count < 512, Date().timeIntervalSince(started) < 1 {
            var byte: UInt8 = 0
            let n = read(fd, &byte, 1)
            guard n == 1 else { close(fd); return }
            if byte == 10 { terminated = true; break }
            line.append(byte)
        }
        guard terminated, let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let number = Self.integer(json["sessionId"], max: Double(UInt32.max)), let session = sessions[UInt32(number)] else { close(fd); return }
        session.timer?.cancel()
        if session.fd >= 0 { shutdown(session.fd, SHUT_RDWR); close(session.fd) }
        session.fd = fd; startTimer(session)
    }

    private func startTimer(_ session: Session) {
        session.timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline:.now(),repeating:1.0/Double(max(1,min(session.producer.fps,15))),leeway:.milliseconds(5))
        timer.setEventHandler { [weak self, weak session] in
            guard let self, let session, self.sessions[session.id] === session else { return }
            self.pushFrame(session)
        }
        session.timer = timer; timer.resume()
    }

    private func pushFrame(_ session: Session) {
        guard session.fd >= 0, let frame = session.producer.nextFrame() else { return }
        session.lastPTS = max(session.lastPTS + 1, UInt64(Date().timeIntervalSince1970 * 1_000_000))
        var packet = Data(capacity:32 + frame.jpeg.count)
        packet.append(contentsOf:[0x43,0x4d,0x46,0x31])
        packet.appendLE(UInt32(frame.jpeg.count)); packet.appendLE(session.id)
        packet.appendLE(frame.width); packet.appendLE(frame.height)
        packet.append(contentsOf:[0x6a,0x70,0x65,0x67])
        packet.appendLE(UInt16(0)); packet.append(contentsOf:[0,0]); packet.appendLE(session.lastPTS)
        packet.append(frame.jpeg)
        if !writeAll(packet,to:session.fd) { interrupt(session.id,reason:"Camera frame delivery timed out or disconnected") }
    }

    private func interrupt(_ id: UInt32, reason: String) {
        guard let session = sessions.removeValue(forKey:id) else { return }
        session.stop()
        send(["type":"sessionInterrupted", "sessionId":id, "error":reason])
        status("Camera session \(id) interrupted: \(reason)")
    }

    private func send(_ message: [String: Any]) {
        if controlFD >= 0 && !sendJSON(message,to:controlFD) { disconnect() }
    }
    private func sendJSON(_ value: [String: Any], to fd: Int32) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject:value) else { return false }
        data.append(10); return writeAll(data,to:fd)
    }
    private func writeAll(_ data: Data, to fd: Int32) -> Bool {
        let started = Date()
        return data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count && Date().timeIntervalSince(started) < 1 {
                let n = write(fd,buffer.baseAddress!.advanced(by:offset),buffer.count-offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return offset == buffer.count
        }
    }
    private func disconnect() {
        connectionEpoch &+= 1; helloTimeout?.cancel(); helloTimeout = nil
        for session in sessions.values { session.stop() }; sessions.removeAll()
        devices.removeAll(); controlBuffer.removeAll(); helloReceived = false
        controlSource?.cancel(); controlSource = nil
        if controlFD >= 0 { shutdown(controlFD,SHUT_RDWR); close(controlFD); controlFD = -1 }
        controlPID = 0
        status("No camera client connected")
    }
    private func cleanup() {
        disconnect()
        for listener in listeners { listener.cancel() }; listeners.removeAll()
        for path in ownedPaths { unlinkOwnedSocket(path) }; ownedPaths.removeAll()
        if lockFD >= 0 { _ = flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
        // Keep the lock pathname: unlinking it would allow two different inodes
        // to be locked by providers racing a restart.
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of:&value) { append(contentsOf:$0) }
    }
}
