// Showcase: a tour of what an unmodified Simulator app can do under SimRun — touch and trackpad gestures, the hardware
// keyboard, its own data container, the Mac pasteboard, the keychain, drag & drop, WKWebView, networking, the Mac's
// language & region, Liquid Glass, and the paired Apple Watch (Showcase's Watch app, Watch/). Each demo is a page
// reached from the home screen's grid.
// SHOWCASE_PAGE=<feature> (touch, keyboard, container, pasteboard, keychain, dragDrop, web, network, locale, glass,
// watch) opens that page at launch.
import SwiftUI
import Metal

@main struct ShowcaseApp: App {
  init() {
    LaunchRecord.recordLaunch()
    WatchLink.shared.activate()
  }
  var body: some Scene { WindowGroup { HomeView() } }
}

enum Feature: String, CaseIterable, Identifiable, Hashable {
  case touch, keyboard, container, pasteboard, keychain, dragDrop, web, network, locale, glass, watch
  var id: Self { self }

  var title: String {
    switch self {
    case .touch:
      "Multi-Touch"
    case .keyboard:
      "Keyboard"
    case .container:
      "Sandbox"
    case .pasteboard:
      "Pasteboard"
    case .keychain:
      "Keychain"
    case .dragDrop:
      "Drag & Drop"
    case .web:
      "WebKit"
    case .network:
      "Network"
    case .locale:
      "Language & Region"
    case .glass:
      "Liquid Glass"
    case .watch:
      "Apple Watch"
    }
  }
  var subtitle: String {
    switch self {
    case .touch:
      "Clicks become fingers; trackpad pinch and rotate become two."
    case .keyboard:
      "Type, use shortcuts, and see every key press."
    case .container:
      "A data container of its own that survives relaunches."
    case .pasteboard:
      "UIPasteboard is the Mac's clipboard."
    case .keychain:
      "Passwords and keys stored with the SecItem API."
    case .dragDrop:
      "Lift, drag and drop within the app."
    case .web:
      "WKWebView with its helper processes."
    case .network:
      "URLSession over HTTPS, with real TLS."
    case .locale:
      "The Mac's language, region and clock."
    case .glass:
      "Glass that refracts and morphs."
    case .watch:
      "A paired watch, and WatchConnectivity both ways."
    }
  }
  var symbol: String {
    switch self {
    case .touch:
      "hand.tap.fill"
    case .keyboard:
      "keyboard.fill"
    case .container:
      "shippingbox.fill"
    case .pasteboard:
      "doc.on.clipboard.fill"
    case .keychain:
      "key.fill"
    case .dragDrop:
      "hand.draw.fill"
    case .web:
      "safari.fill"
    case .network:
      "network"
    case .locale:
      "globe"
    case .glass:
      "drop.fill"
    case .watch:
      "applewatch"
    }
  }
  var colors: [Color] {
    switch self {
    case .touch:
      [Color(red: 1.00, green: 0.42, blue: 0.36), Color(red: 0.96, green: 0.20, blue: 0.44)]
    case .keyboard:
      [Color(red: 0.42, green: 0.48, blue: 0.62), Color(red: 0.24, green: 0.28, blue: 0.40)]
    case .container:
      [Color(red: 0.98, green: 0.70, blue: 0.20), Color(red: 0.95, green: 0.48, blue: 0.10)]
    case .pasteboard:
      [Color(red: 0.30, green: 0.80, blue: 0.62), Color(red: 0.10, green: 0.60, blue: 0.50)]
    case .keychain:
      [Color(red: 0.55, green: 0.55, blue: 0.60), Color(red: 0.30, green: 0.30, blue: 0.36)]
    case .dragDrop:
      [Color(red: 0.70, green: 0.45, blue: 1.00), Color(red: 0.48, green: 0.24, blue: 0.90)]
    case .web:
      [Color(red: 0.25, green: 0.70, blue: 1.00), Color(red: 0.10, green: 0.45, blue: 0.95)]
    case .network:
      [Color(red: 0.20, green: 0.80, blue: 0.85), Color(red: 0.05, green: 0.55, blue: 0.70)]
    case .locale:
      [Color(red: 0.35, green: 0.60, blue: 1.00), Color(red: 0.45, green: 0.35, blue: 0.95)]
    case .glass:
      [Color(red: 0.55, green: 0.85, blue: 1.00), Color(red: 0.95, green: 0.55, blue: 0.85)]
    case .watch:
      [Color(red: 0.45, green: 0.45, blue: 0.50), Color(red: 0.12, green: 0.12, blue: 0.16)]
    }
  }
  var tint: Color { colors[1] }
  var gradient: LinearGradient { LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing) }

  @ViewBuilder var page: some View {
    switch self {
    case .touch:
      TouchDemo()
    case .keyboard:
      KeyboardDemo()
    case .container:
      ContainerDemo()
    case .pasteboard:
      PasteboardDemo()
    case .keychain:
      KeychainDemo()
    case .dragDrop:
      DragDropDemo()
    case .web:
      WebDemo()
    case .network:
      NetworkDemo()
    case .locale:
      LocaleDemo()
    case .glass:
      GlassDemo()
    case .watch:
      WatchDemo()
    }
  }
}

// MARK: - Home

struct HomeView: View {
  @State private var path: [Feature] = []
  private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

  var body: some View {
    NavigationStack(path: $path) {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Intro()
          LazyVGrid(columns: columns, spacing: 12) {
            ForEach(Feature.allCases) { f in
              NavigationLink(value: f) { FeatureCard(feature: f) }.buttonStyle(PressableStyle())
            }
          }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
      }
      .background(Color(uiColor: .systemGroupedBackground))
      .navigationTitle("Showcase")
      .navigationBarTitleDisplayMode(.large)
      .navigationDestination(for: Feature.self) { $0.page }
    }
    .onAppear {   // SHOWCASE_PAGE=<feature> opens that page at launch (e.g. SHOWCASE_PAGE=keychain)
      if path.isEmpty, let f = ProcessInfo.processInfo.environment["SHOWCASE_PAGE"].flatMap(Feature.init(rawValue:)) {
        path = [f]
      }
    }
  }
}

private struct Intro: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("What an iOS Simulator app can do when SimRun runs it as a plain Mac app. Pick a demo.")
        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(SystemFacts.chips, id: \.1) { symbol, text in
            Label(text, systemImage: symbol).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
              .padding(.horizontal, 10).padding(.vertical, 6)
              .background(Color(uiColor: .secondarySystemGroupedBackground), in: .capsule)
          }
        }
      }
      .scrollClipDisabled()
    }
  }
}

private struct FeatureCard: View {
  let feature: Feature
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      FeatureIcon(feature: feature, size: 40)
      Spacer(minLength: 0)
      Text(feature.title).font(.headline).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.8)
      Text(feature.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(3, reservesSpace: true)
        .multilineTextAlignment(.leading)
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
    .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
  }
}

enum SystemFacts {
  static var chips: [(String, String)] {
    var c: [(String, String)] = [("iphone", "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")]
    if let gpu = MTLCreateSystemDefaultDevice()?.name {
      c.append(("cpu", gpu))
    }
    if let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen {
      c.append(("rectangle.portrait", "\(Int(screen.bounds.width))×\(Int(screen.bounds.height)) @\(Int(screen.scale))x"))
    }
    c.append(("number", "pid \(ProcessInfo.processInfo.processIdentifier)"))
    return c
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
    d.set(d.object(forKey: "thisLaunch"), forKey: "previousLaunch")
    d.set(Date(), forKey: "thisLaunch")
  }
  static var count: Int { UserDefaults.standard.integer(forKey: "launchCount") }
  static var first: Date? { UserDefaults.standard.object(forKey: "firstLaunch") as? Date }
  static var previous: Date? { UserDefaults.standard.object(forKey: "previousLaunch") as? Date }
}
