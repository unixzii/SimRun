// Pasteboard: UIPasteboard.general is the Mac's clipboard. Copy text or a rendered image out to the Mac, and watch
// what the Mac (or another app) copies show up here.
import SwiftUI
import UIKit
import Combine

struct PasteboardDemo: View {
  @State private var outgoing = "Hello from an iOS app 👋"
  @State private var toast: String?
  @State private var clip = ClipSnapshot()
  @State private var lastChange = UIPasteboard.general.changeCount
  @Environment(\.scenePhase) private var phase
  private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  var body: some View {
    DemoPage(feature: .pasteboard) {
      Panel(title: "On the clipboard", symbol: "doc.on.clipboard", trailing: AnyView(
        Text("change \(clip.changeCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
          .contentTransition(.numericText()))) {
        ClipPreview(clip: clip)
        if !clip.types.isEmpty {
          FlowLayout(spacing: 6) {
            ForEach(clip.types, id: \.self) { t in
              Text(t).font(.caption2.monospaced()).padding(.horizontal, 7).padding(.vertical, 4)
                .background(Feature.pasteboard.tint.opacity(0.12), in: .capsule)
            }
          }
        }
        Text("Copy anything on the Mac: text, a link, an image from Preview. It appears here within a second.")
          .font(.footnote).foregroundStyle(.secondary)
      }
      .animation(.snappy, value: clip.changeCount)

      Panel(title: "Copy text", symbol: "text.quote") {
        TextField("Text to copy", text: $outgoing)
          .padding(.horizontal, 12).padding(.vertical, 10)
          .background(Color(uiColor: .tertiarySystemGroupedBackground), in: .rect(cornerRadius: 12, style: .continuous))
        HStack {
          Button {
            UIPasteboard.general.string = outgoing
            toast = "Copied — ⌘V in any Mac app"
            refresh()
          } label: { Label("Copy", systemImage: "doc.on.doc.fill") }
            .buttonStyle(.glassProminent).tint(Feature.pasteboard.tint)
          Button {
            UIPasteboard.general.url = URL(string: "https://developer.apple.com/documentation/uikit/uipasteboard")
            toast = "Link copied"
            refresh()
          } label: { Label("Copy a Link", systemImage: "link") }
            .buttonStyle(.glass)
        }
      }

      Panel(title: "Copy an image", symbol: "photo") {
        HStack(spacing: 14) {
          StickerCard().frame(width: 150, height: 100)
          VStack(alignment: .leading, spacing: 8) {
            Text("Rendered with ImageRenderer, copied as PNG.").font(.footnote).foregroundStyle(.secondary)
            Button {
              let r = ImageRenderer(content: StickerCard().frame(width: 300, height: 200))
              r.scale = 3
              if let img = r.uiImage {
                UIPasteboard.general.image = img
                toast = "Image copied — try Preview ▸ New from Clipboard"
              }
              refresh()
            } label: { Label("Copy Image", systemImage: "photo.on.rectangle.angled") }
              .buttonStyle(.glass)
          }
        }
      }

      Hint(text: "Named pasteboards are shared by all SimRun apps but stay off the Mac's clipboard.",
           symbol: "info.circle.fill", tint: Feature.pasteboard.tint)
    }
    .toast($toast)
    .onAppear(perform: refresh)
    .onReceive(poll) { _ in
      if UIPasteboard.general.changeCount != lastChange {
        refresh()
      }
    }
    .onChange(of: phase) {
      if phase == .active {
        refresh()
      }
    }
  }

  private func refresh() {
    let pb = UIPasteboard.general
    lastChange = pb.changeCount
    withAnimation(.snappy) { clip = ClipSnapshot(pb) }
  }
}

struct ClipSnapshot {
  var changeCount = 0
  var types: [String] = []
  var string: String?
  var url: URL?
  var image: UIImage?

  init() {}
  init(_ pb: UIPasteboard) {
    changeCount = pb.changeCount
    types = pb.types
    if pb.hasImages {
      image = pb.image
    }
    if pb.hasURLs {
      url = pb.url
    }
    if pb.hasStrings {
      string = pb.string
    }
  }
}

private struct ClipPreview: View {
  let clip: ClipSnapshot
  var body: some View {
    Group {
      if let image = clip.image {
        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180)
          .clipShape(.rect(cornerRadius: 12)).frame(maxWidth: .infinity)
      } else if let url = clip.url, url.scheme != nil {
        HStack(spacing: 10) {
          Image(systemName: "link.circle.fill").font(.largeTitle).foregroundStyle(Feature.pasteboard.tint)
          VStack(alignment: .leading) {
            Text(url.host() ?? url.absoluteString).font(.headline)
            Text(url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(2)
          }
        }
      } else if let s = clip.string, !s.isEmpty {
        Text(s).font(.body).lineLimit(8).textSelection(.enabled)
          .padding(12).frame(maxWidth: .infinity, alignment: .leading)
          .background(Color(uiColor: .tertiarySystemGroupedBackground), in: .rect(cornerRadius: 12, style: .continuous))
      } else {
        HStack {
          Image(systemName: "clipboard").foregroundStyle(.tertiary)
          Text(clip.types.isEmpty ? "The clipboard is empty." : "Nothing this page can preview.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 60)
      }
    }
    .id(clip.changeCount)
    .transition(.opacity.combined(with: .scale(scale: 0.97)))
  }
}

private struct StickerCard: View {
  var body: some View {
    ZStack {
      LinearGradient(colors: [Color(red: 0.31, green: 0.68, blue: 1), Color(red: 0.55, green: 0.35, blue: 0.95), Color(red: 1, green: 0.45, blue: 0.55)],
                     startPoint: .topLeading, endPoint: .bottomTrailing)
      VStack(spacing: 2) {
        Image(systemName: "play.fill").font(.title2)
        Text("SimRun").font(.system(.title3, design: .rounded, weight: .heavy))
      }
      .foregroundStyle(.white)
    }
    .clipShape(.rect(cornerRadius: 16, style: .continuous))
  }
}
