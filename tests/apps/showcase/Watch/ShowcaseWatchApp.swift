// Showcase's Watch app: what a watchOS Simulator app can do under SimRun — the Digital Crown (the Mac's scroll wheel or
// trackpad), touch, WatchConnectivity with Showcase on the paired iPhone, its own data container, the Mac's language &
// region, and the watch it runs as. Its tint is the theme chosen on the iPhone.
// SHOWCASE_PAGE=<page> (crown, touch, iPhone, sandbox, time, device) opens that page at launch.
import SwiftUI

@main struct ShowcaseWatchApp: App {
  init() {
    LaunchRecord.recordLaunch()
    WatchLink.shared.activate()
  }
  var body: some Scene { WindowGroup { HomeView() } }
}

enum Page: String, CaseIterable, Identifiable, Hashable {
  case crown, touch, iPhone, sandbox, time, device
  var id: Self { self }

  var title: String {
    switch self {
    case .crown:
      "Digital Crown"
    case .touch:
      "Touch"
    case .iPhone:
      "iPhone"
    case .sandbox:
      "Sandbox"
    case .time:
      "Time & Region"
    case .device:
      "This Watch"
    }
  }
  var symbol: String {
    switch self {
    case .crown:
      "digitalcrown.arrow.clockwise.fill"
    case .touch:
      "hand.tap.fill"
    case .iPhone:
      "iphone.radiowaves.left.and.right"
    case .sandbox:
      "shippingbox.fill"
    case .time:
      "globe"
    case .device:
      "applewatch"
    }
  }
  var colors: [Color] {
    switch self {
    case .crown:
      [Color(red: 1.00, green: 0.62, blue: 0.20), Color(red: 0.95, green: 0.36, blue: 0.10)]
    case .touch:
      [Color(red: 1.00, green: 0.42, blue: 0.36), Color(red: 0.96, green: 0.20, blue: 0.44)]
    case .iPhone:
      [Color(red: 0.25, green: 0.70, blue: 1.00), Color(red: 0.10, green: 0.45, blue: 0.95)]
    case .sandbox:
      [Color(red: 0.98, green: 0.70, blue: 0.20), Color(red: 0.95, green: 0.48, blue: 0.10)]
    case .time:
      [Color(red: 0.35, green: 0.60, blue: 1.00), Color(red: 0.45, green: 0.35, blue: 0.95)]
    case .device:
      [Color(red: 0.55, green: 0.55, blue: 0.60), Color(red: 0.30, green: 0.30, blue: 0.36)]
    }
  }
  var gradient: LinearGradient { LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing) }

  @ViewBuilder var page: some View {
    switch self {
    case .crown:
      CrownPage()
    case .touch:
      TouchPage()
    case .iPhone:
      PhonePage()
    case .sandbox:
      SandboxPage()
    case .time:
      TimePage()
    case .device:
      DevicePage()
    }
  }
}

struct HomeView: View {
  @ObservedObject private var link = WatchLink.shared
  @State private var path: [Page] = []

  var body: some View {
    NavigationStack(path: $path) {
      List(Page.allCases) { p in
        NavigationLink(value: p) {
          HStack(spacing: 10) {
            PageIcon(page: p)
            Text(p.title).lineLimit(1).minimumScaleFactor(0.8)
          }
        }
      }
      .navigationTitle("Showcase")
      .toolbarForegroundStyle(.white, for: .navigationBar)   // the default gray is lost on the tinted background
      .navigationDestination(for: Page.self) { $0.page }
      .containerBackground(link.accent.gradient.opacity(0.35), for: .navigation)
    }
    .tint(link.accent.color)
    .onAppear {   // SHOWCASE_PAGE=<page> opens that page at launch (e.g. SHOWCASE_PAGE=crown)
      if path.isEmpty, let p = ProcessInfo.processInfo.environment["SHOWCASE_PAGE"].flatMap(Page.init(rawValue:)) {
        path = [p]
      }
    }
  }
}

struct PageIcon: View {
  let page: Page
  var size: CGFloat = 28
  var body: some View {
    Image(systemName: page.symbol).font(.system(size: size * 0.48, weight: .semibold)).foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(page.gradient, in: .circle)
  }
}

// How often the app has been launched, kept in UserDefaults (its container's Library/Preferences).
enum LaunchRecord {
  static func recordLaunch() {
    let d = UserDefaults.standard
    d.set(d.integer(forKey: "launchCount") + 1, forKey: "launchCount")
    if d.object(forKey: "firstLaunch") == nil {
      d.set(Date(), forKey: "firstLaunch")
    }
  }
  static var count: Int { UserDefaults.standard.integer(forKey: "launchCount") }
  static var first: Date? { UserDefaults.standard.object(forKey: "firstLaunch") as? Date }
}
