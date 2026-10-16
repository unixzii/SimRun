// WCPhone: the iPhone side of WatchConnectivity between SimRun's iPhone and Apple Watch (with WCWatch, its watch app).
import SwiftUI

@main struct WCPhoneApp: App {
    @StateObject private var session = Session()
    var body: some Scene { WindowGroup { ContentView().environmentObject(session) } }
}

// A scroll view, not a List: a List only has the rows on screen, and simrun eval finds (and scrolls to) every element
struct ContentView: View {
    @EnvironmentObject var session: Session
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Session").font(.headline)
                    LabeledContent("Reachable", value: session.reachable ? "yes" : "no").accessibilityIdentifier("reachable")
                    LabeledContent("Activation", value: session.activation).accessibilityIdentifier("activation")
                    LabeledContent("Paired", value: session.paired ? "yes" : "no").accessibilityIdentifier("paired")
                    LabeledContent("Watch app installed", value: session.installed ? "yes" : "no").accessibilityIdentifier("installed")
                    Divider()
                    Text("Sent").font(.headline)
                    Text(session.sent).accessibilityIdentifier("sent")
                    Text("Received").font(.headline)
                    Text(session.received.last ?? "nothing yet").accessibilityIdentifier("received")
                        .accessibilityValue(session.received.joined(separator: "\n"))
                    Divider()
                    Button("Send Message") { session.sendMessage() }
                    Button("Send Data") { session.sendData() }
                    Button("Update Context") { session.updateContext() }
                    Button("Transfer User Info") { session.transferUserInfo() }
                    Button("Transfer File") { session.transferFile() }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("WCPhone")
        }
    }
}
