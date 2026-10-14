// WCPhone: the iPhone side of WatchConnectivity between SimRun's iPhone and Apple Watch (with WCWatch, its watch app).
import SwiftUI

@main struct WCPhoneApp: App {
    @StateObject private var session = Session()
    var body: some Scene { WindowGroup { ContentView().environmentObject(session) } }
}

struct ContentView: View {
    @EnvironmentObject var session: Session
    var body: some View {
        NavigationStack {
            List {
                Section("Received") { Text(session.received).accessibilityIdentifier("received") }
                Section("Send") {
                    Button("Send Message") { session.sendMessage() }
                    Button("Update Context") { session.updateContext() }
                    Button("Transfer User Info") { session.transferUserInfo() }
                }
                Section("Session") {
                    LabeledContent("Reachable", value: session.reachable ? "yes" : "no").accessibilityIdentifier("reachable")
                    LabeledContent("Activation", value: session.activation).accessibilityIdentifier("activation")
                    LabeledContent("Paired", value: session.paired ? "yes" : "no").accessibilityIdentifier("paired")
                    LabeledContent("Watch app installed", value: session.installed ? "yes" : "no").accessibilityIdentifier("installed")
                }
            }
            .navigationTitle("WCPhone")
        }
    }
}
