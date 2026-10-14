// WCWatch: the watch side of WatchConnectivity, WCPhone's watch app.
import SwiftUI

@main struct WCWatchApp: App {
    @StateObject private var session = Session()
    var body: some Scene { WindowGroup { ContentView().environmentObject(session) } }
}

struct ContentView: View {
    @EnvironmentObject var session: Session
    var body: some View {
        List {
            Text(session.received).accessibilityIdentifier("received")
            Button("Send Message") { session.sendMessage() }
            Button("Update Context") { session.updateContext() }
            Button("Transfer User Info") { session.transferUserInfo() }
            Text(session.activation).accessibilityIdentifier("activation")
            Text(session.installed ? "iPhone app installed" : "no iPhone app").accessibilityIdentifier("installed")
            Text(session.reachable ? "reachable" : "not reachable").accessibilityIdentifier("reachable")
        }
    }
}
