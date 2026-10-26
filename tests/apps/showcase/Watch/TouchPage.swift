// Touch: clicks are taps, drags are a finger. Tap anywhere for a ripple; drag the ball.
import SwiftUI

struct TouchPage: View {
  @State private var taps = 0
  @State private var ripples: [Ripple] = []
  @State private var ball: CGPoint?
  @State private var dragging = false

  var body: some View {
    GeometryReader { g in
      ZStack {
        Color.clear.contentShape(.rect)
          .onTapGesture(coordinateSpace: .local) { p in
            taps += 1
            let r = Ripple(point: p)
            ripples.append(r)
            Task {
              try? await Task.sleep(for: .seconds(0.8))
              ripples.removeAll { $0.id == r.id }
            }
          }
        ForEach(ripples) { RippleView(point: $0.point) }
        Circle().fill(Page.touch.gradient)   // grown by scaling: animating its frame left it a rounded square
          .frame(width: 40, height: 40)
          .scaleEffect(dragging ? 1.25 : 1)
          .shadow(color: Page.touch.colors[1].opacity(0.6), radius: dragging ? 10 : 4)
          .position(ball ?? CGPoint(x: g.size.width / 2, y: g.size.height / 2))
          .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("pad"))
            .onChanged { v in
              ball = v.location
              if !dragging {
                withAnimation(.snappy) { dragging = true }
              }
            }
            .onEnded { _ in withAnimation(.snappy) { dragging = false } })
      }
      .coordinateSpace(name: "pad")
    }
    .overlay(alignment: .bottom) {
      Text(taps == 1 ? "1 tap" : "\(taps) taps").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
        .allowsHitTesting(false)
    }
    .navigationTitle("Touch")
  }
}

private struct Ripple: Identifiable {
  let id = UUID()
  let point: CGPoint
}

private struct RippleView: View {
  let point: CGPoint
  @State private var grown = false
  var body: some View {
    Circle().stroke(Page.touch.colors[0], lineWidth: 3)
      .frame(width: 56, height: 56)
      .scaleEffect(grown ? 1.4 : 0.2).opacity(grown ? 0 : 1)
      .position(point)
      .allowsHitTesting(false)
      .onAppear { withAnimation(.easeOut(duration: 0.7)) { grown = true } }
  }
}
