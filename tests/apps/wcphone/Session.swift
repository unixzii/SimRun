// Session.swift — WCSession as both WCPhone and WCWatch use it: its state and what came in, for the UI (and
// accessibility, which simrun eval reads), and the three ways to send: a message (with a reply), the application
// context, and user info. Each side prints what happens to stderr.
import Foundation
import WatchConnectivity

final class Session: NSObject, ObservableObject, WCSessionDelegate {
    @Published var activation = "not activated"
    @Published var paired = false        // iPhone only
    @Published var installed = false     // the counterpart app: the watch app (iPhone), the iPhone app (watch)
    @Published var reachable = false
    @Published var received = "nothing yet"
    @Published var sent = 0

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

    private func got(_ what: String, _ payload: [String: Any]) {
        log("received \(what): \(payload)")
        DispatchQueue.main.async { self.received = "\(what): \(payload["text"] ?? payload)" }
    }

    // sending
    func sendMessage() {
        sent += 1
        let n = sent
        WCSession.default.sendMessage(["text": "message \(n)"], replyHandler: { reply in self.got("reply", reply) },
                                      errorHandler: { e in self.log("sendMessage failed: \(e)"); DispatchQueue.main.async { self.received = "error: \(e.localizedDescription)" } })
    }
    func updateContext() {
        sent += 1
        do { try WCSession.default.updateApplicationContext(["text": "context \(sent)"]) } catch { log("updateApplicationContext failed: \(error)") }
    }
    func transferUserInfo() {
        sent += 1
        WCSession.default.transferUserInfo(["text": "user info \(sent)"])
    }

    // WCSessionDelegate
    func session(_ s: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        log("activation \(state.rawValue) error \(String(describing: error))")
        refresh(s)
    }
    func sessionReachabilityDidChange(_ s: WCSession) { log("reachable \(s.isReachable)"); refresh(s) }
    func session(_ s: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        got("message", message)
        replyHandler(["text": "reply to \(message["text"] ?? "?")"])
    }
    func session(_ s: WCSession, didReceiveApplicationContext context: [String: Any]) { got("context", context) }
    func session(_ s: WCSession, didReceiveUserInfo info: [String: Any] = [:]) { got("user info", info) }
    #if os(iOS)
    func sessionDidBecomeInactive(_ s: WCSession) { log("inactive"); refresh(s) }
    func sessionDidDeactivate(_ s: WCSession) { log("deactivated"); s.activate() }
    func sessionWatchStateDidChange(_ s: WCSession) { log("watch state paired \(s.isPaired) installed \(s.isWatchAppInstalled)"); refresh(s) }
    #else
    func sessionCompanionAppInstalledDidChange(_ s: WCSession) { log("companion installed \(s.isCompanionAppInstalled)"); refresh(s) }
    #endif
}
