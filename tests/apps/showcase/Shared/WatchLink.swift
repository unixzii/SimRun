// WatchLink: WatchConnectivity between Showcase and its Watch app, compiled into both. The iPhone themes the watch with
// its application context, either side sends a message that the other answers, and the watch sends the Crown's value
// as user info. What comes in is kept in an inbox for the pages to show; each side also prints it to stderr.
import SwiftUI
import WatchConnectivity
#if os(watchOS)
import WatchKit
#endif

// The watch app's tint, chosen on the iPhone
enum Accent: String, CaseIterable, Identifiable {
  case coral, violet, mint, sky, amber
  var id: Self { self }
  var colors: [Color] {
    switch self {
    case .coral: [Color(red: 1.00, green: 0.42, blue: 0.36), Color(red: 0.96, green: 0.20, blue: 0.44)]
    case .violet: [Color(red: 0.70, green: 0.45, blue: 1.00), Color(red: 0.48, green: 0.24, blue: 0.90)]
    case .mint: [Color(red: 0.30, green: 0.80, blue: 0.62), Color(red: 0.10, green: 0.60, blue: 0.50)]
    case .sky: [Color(red: 0.25, green: 0.70, blue: 1.00), Color(red: 0.10, green: 0.45, blue: 0.95)]
    case .amber: [Color(red: 0.98, green: 0.70, blue: 0.20), Color(red: 0.95, green: 0.48, blue: 0.10)]
    }
  }
  var color: Color { colors[1] }
  var gradient: LinearGradient { LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing) }
}

struct Delivery: Identifiable {
  enum Kind: String { case message = "Message", reply = "Reply", context = "Context", userInfo = "User Info", failed = "Failed" }
  let id = UUID()
  let kind: Kind
  let text: String
  let date = Date()
  var symbol: String {
    switch kind {
    case .message: "bubble.left.fill"
    case .reply: "arrowshape.turn.up.left.fill"
    case .context: "paintpalette.fill"
    case .userInfo: "tray.and.arrow.down.fill"
    case .failed: "exclamationmark.triangle.fill"
    }
  }
}

final class WatchLink: NSObject, ObservableObject, WCSessionDelegate {
  static let shared = WatchLink()

  @Published private(set) var activated = false
  @Published private(set) var paired = false          // iPhone: a watch is paired; watch: always
  @Published private(set) var installed = false       // the other half of Showcase is installed
  @Published private(set) var reachable = false
  @Published private(set) var inbox: [Delivery] = []  // newest first
  @Published private(set) var sent = 0
  @Published private(set) var accent: Accent = Accent(rawValue: UserDefaults.standard.string(forKey: "accent") ?? "") ?? .coral

  // Who this is, for messages and replies
  static var device: String {
    #if os(iOS)
    "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
    #else
    "watchOS \(WKInterfaceDevice.current().systemVersion)"
    #endif
  }

  func activate() {
    guard WCSession.isSupported(), WCSession.default.delegate == nil else { return }
    WCSession.default.delegate = self
    WCSession.default.activate()
  }

  // sending
  func sendMessage() {
    sent += 1
    let n = sent
    WCSession.default.sendMessage(["text": "Hello #\(n) from \(Self.device)"], replyHandler: { reply in
      self.got(.reply, reply)
    }, errorHandler: { error in
      self.log("sendMessage failed: \(error)")
      DispatchQueue.main.async { self.add(.failed, error.localizedDescription) }
    })
  }
  #if os(iOS)
  func setAccent(_ a: Accent) {
    accent = a
    UserDefaults.standard.set(a.rawValue, forKey: "accent")
    pushAccent()
  }
  private func pushAccent() {   // once there is a watch with Showcase on it: before, it is an error
    let s = WCSession.default
    guard s.activationState == .activated, s.isPaired, s.isWatchAppInstalled else { return }
    do { try WCSession.default.updateApplicationContext(["accent": accent.rawValue]) } catch { log("updateApplicationContext failed: \(error)") }
  }
  #else
  func sendCrown(_ value: Double) {
    sent += 1
    WCSession.default.transferUserInfo(["text": "The Crown is at \(Int(value.rounded()))"])
  }
  #endif

  private func log(_ s: String) { FileHandle.standardError.write("[showcase wc] \(s)\n".data(using: .utf8)!) }

  private func add(_ kind: Delivery.Kind, _ text: String) {
    inbox.insert(Delivery(kind: kind, text: text), at: 0)
    if inbox.count > 20 { inbox.removeLast() }
  }

  private func got(_ kind: Delivery.Kind, _ payload: [String: Any]) {
    log("received \(kind.rawValue): \(payload)")
    DispatchQueue.main.async {
      if let a = (payload["accent"] as? String).flatMap(Accent.init(rawValue:)) {
        self.accent = a
        UserDefaults.standard.set(a.rawValue, forKey: "accent")
        self.add(kind, "Theme: \(a.rawValue)")
      } else {
        self.add(kind, payload["text"] as? String ?? "\(payload)")
      }
    }
  }

  private func refresh(_ s: WCSession) {
    DispatchQueue.main.async {
      self.activated = s.activationState == .activated
      #if os(iOS)
      self.paired = s.isPaired
      self.installed = s.isWatchAppInstalled
      #else
      self.paired = true
      self.installed = s.isCompanionAppInstalled
      #endif
      self.reachable = s.isReachable
    }
  }

  // WCSessionDelegate
  func session(_ s: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
    log("activation \(state.rawValue) error \(String(describing: error))")
    refresh(s)
    #if os(iOS)
    DispatchQueue.main.async { self.pushAccent() }
    #else
    if !s.receivedApplicationContext.isEmpty { got(.context, s.receivedApplicationContext) }   // the theme set while the watch app wasn't running
    #endif
  }
  func sessionReachabilityDidChange(_ s: WCSession) { log("reachable \(s.isReachable)"); refresh(s) }
  func session(_ s: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
    got(.message, message)
    replyHandler(["text": "Hi back from \(Self.device)"])
  }
  func session(_ s: WCSession, didReceiveApplicationContext context: [String: Any]) { got(.context, context) }
  func session(_ s: WCSession, didReceiveUserInfo info: [String: Any] = [:]) { got(.userInfo, info) }
  #if os(iOS)
  func sessionDidBecomeInactive(_ s: WCSession) { refresh(s) }
  func sessionDidDeactivate(_ s: WCSession) { s.activate() }
  func sessionWatchStateDidChange(_ s: WCSession) {
    log("watch paired \(s.isPaired) installed \(s.isWatchAppInstalled)")
    refresh(s)
    DispatchQueue.main.async { self.pushAccent() }
  }
  #else
  func sessionCompanionAppInstalledDidChange(_ s: WCSession) { refresh(s) }
  #endif
}
