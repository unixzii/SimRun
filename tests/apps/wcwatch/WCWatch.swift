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
            Text(session.received.last ?? "nothing yet").accessibilityIdentifier("received")
                .accessibilityValue(session.received.joined(separator: "\n"))
            Button("Send Message") { session.sendMessage() }
            Button("Send Data") { session.sendData() }
            Button("Update Context") { session.updateContext() }
            Button("Transfer User Info") { session.transferUserInfo() }
            Button("Transfer File") { session.transferFile() }
            Text(session.sent).accessibilityIdentifier("sent")
            Text(session.activation).accessibilityIdentifier("activation")
            Text(session.installed ? "iPhone app installed" : "no iPhone app").accessibilityIdentifier("installed")
            Text(session.reachable ? "reachable" : "not reachable").accessibilityIdentifier("reachable")
        }
    }
}
