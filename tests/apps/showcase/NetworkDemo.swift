// Network: URLSession requests over HTTPS (trustd validates the certificates), timed, with a peek at the response.
import SwiftUI

struct NetworkDemo: View {
  struct Probe: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let url: URL
    var state = State.idle
    enum State {
      case idle, running, done(status: Int, ms: Double, bytes: Int, summary: [(String, String)]), failed(String)
    }
  }

  @State private var probes: [Probe] = [
    Probe(id: "trace", title: "Cloudflare trace", symbol: "point.3.connected.trianglepath.dotted",
          url: URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!),
    Probe(id: "captive", title: "Apple captive portal", symbol: "apple.logo",
          url: URL(string: "https://captive.apple.com/hotspot-detect.html")!),
    Probe(id: "zen", title: "GitHub API", symbol: "chevron.left.forwardslash.chevron.right",
          url: URL(string: "https://api.github.com/zen")!),
    Probe(id: "example", title: "example.com", symbol: "globe", url: URL(string: "https://example.com")!),
  ]

  var body: some View {
    DemoPage(feature: .network) {
      Button { Task { await runAll() } } label: {
        Label("Run All Requests", systemImage: "bolt.horizontal.fill").frame(maxWidth: .infinity).padding(.vertical, 4)
      }
      .buttonStyle(.glassProminent).tint(Feature.network.tint)

      ForEach($probes) { $p in
        Panel {
          HStack(spacing: 12) {
            Image(systemName: p.symbol).font(.title3).foregroundStyle(.white).frame(width: 40, height: 40)
              .background(Feature.network.gradient, in: .rect(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
              Text(p.title).font(.headline)
              Text(p.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            stateView(p.state)
          }
          .contentShape(.rect)
          .onTapGesture { Task { await run(p.id) } }
          if case let .done(_, _, _, summary) = p.state, !summary.isEmpty {
            VStack(spacing: 6) { ForEach(summary, id: \.0) { InfoRow(label: $0.0, value: $0.1, mono: true) } }
              .transition(.opacity)
          }
          if case let .failed(msg) = p.state {
            Text(msg).font(.footnote).foregroundStyle(.red)
          }
        }
      }
      Hint(text: "Tap a row to run it again. Requests go out from the app process itself: no proxy, no Simulator networking.",
           symbol: "network", tint: Feature.network.tint)
    }
    .task { await runAll() }
  }

  @ViewBuilder private func stateView(_ s: Probe.State) -> some View {
    switch s {
    case .idle:
      Image(systemName: "play.circle").font(.title2).foregroundStyle(.secondary)
    case .running:
      ProgressView()
    case let .done(status, ms, bytes, _):
      VStack(alignment: .trailing, spacing: 2) {
        StatusBadge(text: "\(status)", symbol: (200..<400).contains(status) ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    color: (200..<400).contains(status) ? .green : .orange)
        Text("\(Int(ms)) ms · \(byteString(bytes))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
      }
    case .failed:
      Image(systemName: "xmark.octagon.fill").font(.title2).foregroundStyle(.red)
    }
  }

  private func runAll() async {
    await withTaskGroup(of: Void.self) { g in
      for p in probes {
        g.addTask { await run(p.id) }
      }
    }
  }

  @MainActor private func run(_ id: String) async {
    guard let i = probes.firstIndex(where: { $0.id == id }) else {
      return
    }
    if case .running = probes[i].state {
      return
    }
    withAnimation(.snappy) { probes[i].state = .running }
    var req = URLRequest(url: probes[i].url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
    req.setValue("SimRun-Showcase/1.0", forHTTPHeaderField: "User-Agent")
    let t0 = CACurrentMediaTime()
    do {
      let (data, resp) = try await URLSession.shared.data(for: req)
      let ms = (CACurrentMediaTime() - t0) * 1000
      let http = resp as? HTTPURLResponse
      withAnimation(.snappy) {
        probes[i].state = .done(status: http?.statusCode ?? 0, ms: ms, bytes: data.count, summary: summarize(id, data, http))
      }
    } catch {
      withAnimation(.snappy) { probes[i].state = .failed(error.localizedDescription) }
    }
  }

  private func summarize(_ id: String, _ data: Data, _ http: HTTPURLResponse?) -> [(String, String)] {
    let text = String(decoding: data, as: UTF8.self)
    switch id {
    case "trace":
      let kv = Dictionary(text.split(separator: "\n").compactMap { l -> (String, String)? in
        let p = l.split(separator: "=", maxSplits: 1)
        return p.count == 2 ? (String(p[0]), String(p[1])) : nil
      }, uniquingKeysWith: { a, _ in a })
      return [("IP", kv["ip"]), ("Location", kv["loc"]), ("Edge", kv["colo"]), ("TLS", kv["tls"]), ("HTTP", kv["http"])]
        .compactMap { k, v in v.map { (k, $0) } }
    case "captive":
      return [("Body", text.contains("Success") ? "Success" : String(text.prefix(40)))]
    case "zen":
      return [("Zen", text.trimmingCharacters(in: .whitespacesAndNewlines))]
    default:
      let title = text.range(of: "<title>").flatMap { a in text.range(of: "</title>", range: a.upperBound..<text.endIndex).map { text[a.upperBound..<$0.lowerBound] } }
      return [("Title", title.map(String.init)), ("Server", http?.value(forHTTPHeaderField: "Server"))].compactMap { k, v in v.map { (k, $0) } }
    }
  }
}
