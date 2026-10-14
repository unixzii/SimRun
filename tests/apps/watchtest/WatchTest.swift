// WatchTest: a SwiftUI watch app for SimRun's watchOS support: a list scrolled by touch or the Digital Crown, a counter,
// a toggle, navigation, and a value the Crown turns.
import SwiftUI

@main struct WatchTestApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    @State private var count = 0
    @State private var on = true
    var body: some View {
        NavigationStack {
            List {
                Button("Tapped \(count)") { count += 1 }
                Toggle("A toggle", isOn: $on)
                NavigationLink("Crown") { CrownView() }
                ForEach(0..<12) { i in NavigationLink("Row \(i)") { Text("Detail \(i)").font(.title2) } }
            }
            .navigationTitle("WatchTest")
        }
    }
}

// The Crown turns a value when nothing scrolls
struct CrownView: View {
    @State private var value = 0.0
    var body: some View {
        Text("Crown \(value, specifier: "%.1f")")
            .font(.title3)
            .focusable()
            .digitalCrownRotation($value, from: -100, through: 100, by: 1, sensitivity: .medium, isContinuous: false)
    }
}
