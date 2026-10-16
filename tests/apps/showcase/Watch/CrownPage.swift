// Digital Crown: a value the Crown turns. Under SimRun the Mac's scroll wheel or two-finger trackpad scrolling turns it
// (and scrolls the home list); the value goes to the iPhone as user info.
import SwiftUI

struct CrownPage: View {
  @ObservedObject private var link = WatchLink.shared
  @State private var value = 50.0
  @FocusState private var focused: Bool

  var body: some View {
    VStack(spacing: 8) {
      ZStack {
        Circle().stroke(.white.opacity(0.15), lineWidth: 10)
        Circle().trim(from: 0, to: value / 100)
          .stroke(Page.crown.gradient, style: StrokeStyle(lineWidth: 10, lineCap: .round))
          .rotationEffect(.degrees(-90))
        VStack(spacing: 2) {
          Text("\(Int(value.rounded()))").font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
            .contentTransition(.numericText()).animation(.snappy, value: Int(value.rounded()))
          Image(systemName: "digitalcrown.arrow.clockwise").font(.footnote).foregroundStyle(.secondary)   // scroll to turn
        }
      }
      .frame(width: 92, height: 92)
      .focusable()
      .focused($focused)   // the Crown turns the value from the start, not only after a tap on the ring
      .digitalCrownRotation($value, from: 0, through: 100, by: 1, sensitivity: .high, isContinuous: false)
      .accessibilityIdentifier("crownValue")

      Button { link.sendCrown(value) } label: { Label("Send to iPhone", systemImage: "iphone") }
        .disabled(!link.installed)
    }
    .navigationTitle("Crown")
    .onAppear { focused = true }
  }
}
