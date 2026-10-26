// WebKit: a WKWebView (its WebContent, Networking and GPU processes are launched by SimRun) showing either a local
// page that talks to Swift through a script message handler, or any web site.
import SwiftUI
import WebKit

struct WebDemo: View {
  enum Source: String, CaseIterable {
    case local = "Local Page", web = "Web"
  }
  @State private var source = Source.local
  @State private var address = "https://www.apple.com"
  @State private var loaded: URL?
  @State private var model = WebModel()
  @State private var toast: String?

  var body: some View {
    DemoPage(feature: .web, scrolls: false) {
      Picker("Source", selection: $source) {
        ForEach(Source.allCases, id: \.self) { Text($0.rawValue) }
      }
      .pickerStyle(.segmented)

      if source == .web {
        HStack(spacing: 8) {
          Image(systemName: model.secure ? "lock.fill" : "globe").foregroundStyle(.secondary)
          TextField("Address", text: $address)
            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            .onSubmit(go)
          if model.loading {
            ProgressView().controlSize(.small)
          }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: .capsule)
      }

      ZStack(alignment: .top) {
        WebViewHost(model: model, html: source == .local ? LocalPage.html : nil, url: source == .web ? loaded : nil) { msg in
          toast = msg
        }
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.separator))
        if model.loading {
          ProgressView(value: model.progress).tint(Feature.web.tint).padding(.horizontal, 18).padding(.top, 1)
        }
      }

      HStack {
        StatusBadge(text: model.title.isEmpty ? "Loading…" : model.title, symbol: "doc.richtext", color: Feature.web.tint)
          .lineLimit(1)
        Spacer()
        if let t = model.loadTime {
          Text(String(format: "%.2f s", t)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
      }
    }
    .toast($toast)
    .onAppear {
      if loaded == nil {
        loaded = URL(string: address)
      }
    }
  }

  private func go() {
    var s = address.trimmingCharacters(in: .whitespaces)
    if !s.contains("://") {
      s = "https://" + s
    }
    address = s
    loaded = URL(string: s)
  }
}

@Observable final class WebModel {
  var title = ""
  var loading = false
  var progress = 0.0
  var secure = false
  var loadTime: Double?
}

private struct WebViewHost: UIViewRepresentable {
  let model: WebModel
  let html: String?
  let url: URL?
  let onMessage: (String) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(model: model)
  }

  func makeUIView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.userContentController.add(context.coordinator, name: "native")
    let w = WKWebView(frame: .zero, configuration: config)
    w.navigationDelegate = context.coordinator
    w.allowsBackForwardNavigationGestures = true
    w.isInspectable = true
    context.coordinator.observe(w)
    return w
  }

  func updateUIView(_ w: WKWebView, context: Context) {
    let c = context.coordinator
    c.onMessage = onMessage
    if let html, c.shown != "local" {
      c.shown = "local"
      c.start = CACurrentMediaTime()
      w.loadHTMLString(html, baseURL: nil)
    } else if let url, c.shown != url.absoluteString {
      c.shown = url.absoluteString
      c.start = CACurrentMediaTime()
      w.load(URLRequest(url: url))
    }
  }

  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let model: WebModel
    var shown: String?
    var start = 0.0
    var onMessage: ((String) -> Void)?
    private var observations: [NSKeyValueObservation] = []
    init(model: WebModel) {
      self.model = model
    }

    func observe(_ w: WKWebView) {
      observations = [
        w.observe(\.title) { [model] w, _ in DispatchQueue.main.async { model.title = w.title ?? "" } },
        w.observe(\.estimatedProgress) { [model] w, _ in DispatchQueue.main.async { model.progress = w.estimatedProgress } },
        w.observe(\.isLoading) { [model] w, _ in DispatchQueue.main.async { model.loading = w.isLoading } },
        w.observe(\.hasOnlySecureContent) { [model] w, _ in DispatchQueue.main.async { model.secure = w.hasOnlySecureContent && w.url?.scheme == "https" } },
      ]
    }
    func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) {
      model.loadTime = nil
    }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
      model.loadTime = CACurrentMediaTime() - start
    }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
      model.title = e.localizedDescription
    }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
      onMessage?("From JavaScript: \(m.body)")
    }
  }
}

private enum LocalPage {
  static let html = """
  <!doctype html><html><head><meta name=viewport content="width=device-width,initial-scale=1">
  <title>Local Page</title>
  <style>
    :root { color-scheme: light dark; }
    body { margin:0; font:17px -apple-system, system-ui; background:#0b1020; color:#fff; overflow:hidden; }
    canvas { position:fixed; inset:0; }
    .card { position:relative; margin:22px; padding:20px; border-radius:22px; background:rgba(255,255,255,.10);
            -webkit-backdrop-filter: blur(20px); backdrop-filter: blur(20px); border:1px solid rgba(255,255,255,.18); }
    h1 { margin:0 0 6px; font-size:26px; }
    p { margin:6px 0; opacity:.8; font-size:15px; }
    code { font:12px ui-monospace, monospace; opacity:.75; word-break:break-all; }
    button { margin-top:12px; font:600 16px -apple-system; color:#fff; border:0; border-radius:999px; padding:11px 18px;
             background:linear-gradient(135deg,#3fb4ff,#1f6bf2); }
    #clicks { font-variant-numeric: tabular-nums; }
  </style></head><body>
  <canvas id=c></canvas>
  <div class=card>
    <h1>Hello from WebKit</h1>
    <p>HTML, CSS and JavaScript, rendered by WKWebView's own GPU process. Drag across the page to stir the particles.</p>
    <p><code id=ua></code></p>
    <button onclick="ping()">Send to Swift</button> <span id=clicks></span>
  </div>
  <script>
    document.getElementById('ua').textContent = navigator.userAgent;
    let n = 0;
    function ping() {
      n++;
      document.getElementById('clicks').textContent = n + '×';
      window.webkit.messageHandlers.native.postMessage('button pressed ' + n + (n == 1 ? ' time' : ' times'));
    }
    const c = document.getElementById('c'), g = c.getContext('2d');
    let W, H, P = [], pointer = null;
    function size() {
      W = c.width = innerWidth * devicePixelRatio;
      H = c.height = innerHeight * devicePixelRatio;
    }
    size();
    addEventListener('resize', size);
    for (let i = 0; i < 140; i++)
      P.push({ x: Math.random(), y: Math.random(), vx: 0, vy: 0, h: Math.random() * 360 });
    const move = e => {
      const t = e.touches ? e.touches[0] : e;
      pointer = { x: t.clientX / innerWidth, y: t.clientY / innerHeight };
    };
    addEventListener('touchmove', move);
    addEventListener('touchstart', move);
    addEventListener('touchend', () => pointer = null);
    function frame(ts) {
      g.fillStyle = 'rgba(11,16,32,.25)';
      g.fillRect(0, 0, W, H);
      for (const p of P) {
        p.vx += (Math.sin(ts / 2000 + p.y * 6) * .00004);
        p.vy += (Math.cos(ts / 2400 + p.x * 6) * .00004);
        if (pointer) {
          const dx = pointer.x - p.x, dy = pointer.y - p.y, d = Math.hypot(dx, dy) + .02;
          p.vx += dx / d * .0004;
          p.vy += dy / d * .0004;
        }
        p.vx *= .97;
        p.vy *= .97;
        p.x = (p.x + p.vx + 1) % 1;
        p.y = (p.y + p.vy + 1) % 1;
        g.beginPath();
        g.fillStyle = `hsla(${(p.h + ts / 40) % 360},90%,65%,.9)`;
        g.arc(p.x * W, p.y * H, 2.2 * devicePixelRatio, 0, 7);
        g.fill();
      }
      requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
  </script></body></html>
  """
}
