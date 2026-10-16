// iPhone: WatchConnectivity with Showcase on the paired iPhone — whether it is installed and reachable, a message with a
// reply, the theme it sets, and what came in.
import SwiftUI

struct PhonePage: View {
  @ObservedObject private var link = WatchLink.shared

  var body: some View {
    List {
      Section {
        LabeledContent("Showcase") { Text(link.installed ? "Installed" : "Not installed") }
          .accessibilityIdentifier("installed")
        LabeledContent("Reachable") { Text(link.reachable ? "Yes" : "No") }
          .accessibilityIdentifier("reachable")
        LabeledContent("Theme") {
          HStack(spacing: 4) { Circle().fill(link.accent.gradient).frame(width: 12, height: 12); Text(link.accent.rawValue.capitalized) }
        }
      }
      Section {
        Button { link.sendMessage() } label: { Label("Say Hello", systemImage: "hand.wave.fill") }
          .disabled(!link.reachable)
      } footer: {
        Text(link.reachable ? "The iPhone answers with a reply." : "Open Showcase's Apple Watch page on the iPhone.")
      }
      Section("Received") {
        if link.inbox.isEmpty {
          Text("Nothing yet").foregroundStyle(.secondary)
        } else {
          ForEach(link.inbox.prefix(6)) { d in
            VStack(alignment: .leading, spacing: 2) {
              Label(d.text, systemImage: d.symbol).font(.footnote)
              Text("\(d.kind.rawValue) · \(d.date.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    .navigationTitle("iPhone")
  }
}
