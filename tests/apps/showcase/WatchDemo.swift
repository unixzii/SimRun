// Apple Watch: SimRun's iPhone is paired with its Apple Watch, and Showcase's Watch app (Watch/) talks to this page
// over WatchConnectivity: the theme goes to the watch as the application context, messages go both ways with a reply,
// and the watch sends the Crown's value as user info.
import SwiftUI

struct WatchDemo: View {
  @ObservedObject private var link = WatchLink.shared

  var body: some View {
    DemoPage(feature: .watch) {
      Panel(title: "Session", symbol: "applewatch.radiowaves.left.and.right") {
        statusRow("Activated", link.activated)
        statusRow("Apple Watch paired", link.paired)
        statusRow("Showcase on the watch", link.installed)
        statusRow("Reachable", link.reachable, off: "Run the Watch app")
      }

      Panel(title: "Theme the Watch", symbol: "paintpalette") {
        HStack(spacing: 10) {
          ForEach(Accent.allCases) { a in
            Button { withAnimation(.snappy) { link.setAccent(a) } } label: {
              Circle().fill(a.gradient).frame(width: 44, height: 44)
                .overlay {
                  if a == link.accent {
                    Image(systemName: "checkmark").font(.headline.bold()).foregroundStyle(.white)
                  }
                }
                .overlay(Circle().strokeBorder(.white.opacity(a == link.accent ? 0.9 : 0), lineWidth: 3))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(a.rawValue.capitalized)
          }
        }
        Text("Sent as the application context: the watch gets the latest one even if its app starts later.")
          .font(.footnote).foregroundStyle(.secondary)
      }

      Panel(title: "Message", symbol: "bubble.left.and.bubble.right") {
        Button { link.sendMessage() } label: {
          Label("Say Hello to the Watch", systemImage: "hand.wave.fill").frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent).tint(Feature.watch.tint).controlSize(.large)
        .disabled(!link.reachable)
        Text("The watch answers with a reply. Its Crown page sends the Crown's value back as user info.")
          .font(.footnote).foregroundStyle(.secondary)
      }

      Panel(title: "Received", symbol: "tray", trailing: link.inbox.isEmpty ? nil : AnyView(Text("\(link.inbox.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary))) {
        if link.inbox.isEmpty {
          Text("Nothing from the watch yet.").font(.footnote).foregroundStyle(.secondary)
        } else {
          VStack(spacing: 10) {
            ForEach(link.inbox) { d in
              HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: d.symbol).foregroundStyle(d.kind == .failed ? .orange : Feature.watch.tint).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                  Text(d.text).font(.callout)
                  Text("\(d.kind.rawValue) · \(d.date.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
              }
              .transition(.move(edge: .top).combined(with: .opacity))
            }
          }
          .animation(.snappy, value: link.inbox.count)
        }
      }

      Hint(text: "In the launcher, expand Showcase and run its **Watch app**, or run `simrun run --with-watch-app build/apps/Showcase.app`. Scroll on the watch to turn its Digital Crown.",
           symbol: "applewatch", tint: Feature.watch.tint)
    }
  }

  private func statusRow(_ label: String, _ on: Bool, off: String = "No") -> some View {
    HStack {
      Text(label).font(.callout)
      Spacer()
      if on {
        StatusBadge(text: "Yes")
      } else {
        StatusBadge(text: off, symbol: "circle.dashed", color: .secondary)
      }
    }
  }
}
