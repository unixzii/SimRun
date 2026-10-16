// Session.swift — WCSession as both WCPhone and WCWatch use it: its state and what came in, for the UI (and
// accessibility, which simrun eval reads), and the ways to send: a message and message data (each with a reply), the
// application context, user info and a file. Each side prints what happens to stderr.
//
// Every payload is "<what> <n> #<tag>", the tag new each launch: WatchConnectivity drops an application context equal to
// the last one sent, which a payload repeated from an earlier launch would be. "sent" is the last payload sent;
// "received" shows the last delivery and has every delivery of this launch, one "<kind>: <payload>" a line, as its value.
import Foundation
import WatchConnectivity

final class Session: NSObject, ObservableObject, WCSessionDelegate {
    @Published var activation = "not activated"
    @Published var paired = false        // iPhone only
    @Published var installed = false     // the counterpart app: the watch app (iPhone), the iPhone app (watch)
    @Published var reachable = false
    @Published var received: [String] = []
    @Published var sent = "nothing yet"
    private var count = 0
    private let tag = String(UUID().uuidString.prefix(4))

    override init() {
        super.init()
        guard WCSession.isSupported() else { activation = "not supported"; return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private func log(_ s: String) { FileHandle.standardError.write("[wc] \(s)\n".data(using: .utf8)!) }

    private func refresh(_ s: WCSession) {
        DispatchQueue.main.async {
            self.activation = ["not activated", "inactive", "activated"][s.activationState.rawValue]
            #if os(iOS)
            self.paired = s.isPaired
            self.installed = s.isWatchAppInstalled
            #else
            self.installed = s.isCompanionAppInstalled
            #endif
            self.reachable = s.isReachable
        }
    }

    private func got(_ kind: String, _ text: String) {
        log("received \(kind): \(text)")
        DispatchQueue.main.async { self.received.append("\(kind): \(text)") }
    }
    private func got(_ kind: String, _ payload: [String: Any]) { got(kind, payload["text"] as? String ?? "\(payload)") }

    // sending: the next payload, shown as sent
    private func next(_ what: String) -> String {
        count += 1
        sent = "\(what) \(count) #\(tag)"
        return sent
    }
    private func failed(_ what: String, _ e: Error) { log("\(what) failed: \(e)"); got("error", "\(what): \(e.localizedDescription)") }

    func sendMessage() {
        WCSession.default.sendMessage(["text": next("message")], replyHandler: { reply in self.got("reply", reply) },
                                      errorHandler: { e in self.failed("sendMessage", e) })
    }
    func sendData() {
        WCSession.default.sendMessageData(Data(next("data").utf8), replyHandler: { reply in self.got("data reply", String(decoding: reply, as: UTF8.self)) },
                                          errorHandler: { e in self.failed("sendMessageData", e) })
    }
    func updateContext() {
        do { try WCSession.default.updateApplicationContext(["text": next("context")]) } catch { failed("updateApplicationContext", error) }
    }
    func transferUserInfo() {
        WCSession.default.transferUserInfo(["text": next("user info")])
    }
    func transferFile() {
        let text = next("file")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        do { try Data(text.utf8).write(to: url) } catch { failed("transferFile", error); return }
        WCSession.default.transferFile(url, metadata: ["text": text])
    }

    // WCSessionDelegate
    func session(_ s: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        log("activation \(state.rawValue) error \(String(describing: error))")
        refresh(s)
        // the context that came while this app wasn't running
        if let text = s.receivedApplicationContext["text"] as? String { got("stored context", text) }
    }
    func sessionReachabilityDidChange(_ s: WCSession) { log("reachable \(s.isReachable)"); refresh(s) }
    func session(_ s: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        got("message", message)
        replyHandler(["text": "reply to \(message["text"] ?? "?")"])
    }
    func session(_ s: WCSession, didReceiveMessageData data: Data, replyHandler: @escaping (Data) -> Void) {
        let text = String(decoding: data, as: UTF8.self)
        got("data", text)
        replyHandler(Data("reply to \(text)".utf8))
    }
    func session(_ s: WCSession, didReceiveApplicationContext context: [String: Any]) { got("context", context) }
    func session(_ s: WCSession, didReceiveUserInfo info: [String: Any] = [:]) { got("user info", info) }
    func session(_ s: WCSession, didReceive file: WCSessionFile) {   // the file goes away when this returns
        let text = (try? String(contentsOf: file.fileURL, encoding: .utf8)) ?? "unreadable"
        got("file", "\(text) (metadata \(file.metadata?["text"] ?? "none"))")
    }
    func session(_ s: WCSession, didFinish transfer: WCSessionUserInfoTransfer, error: Error?) {
        if let error { failed("transferUserInfo", error) }
    }
    func session(_ s: WCSession, didFinish transfer: WCSessionFileTransfer, error: Error?) {
        if let error { failed("transferFile", error) }
        try? FileManager.default.removeItem(at: transfer.file.fileURL)
    }
    #if os(iOS)
    func sessionDidBecomeInactive(_ s: WCSession) { log("inactive"); refresh(s) }
    func sessionDidDeactivate(_ s: WCSession) { log("deactivated"); s.activate() }
    func sessionWatchStateDidChange(_ s: WCSession) { log("watch state paired \(s.isPaired) installed \(s.isWatchAppInstalled)"); refresh(s) }
    #else
    func sessionCompanionAppInstalledDidChange(_ s: WCSession) { log("companion installed \(s.isCompanionAppInstalled)"); refresh(s) }
    #endif
}
