// Touch: a finger-painting canvas that shows every active touch (a click is one finger; a trackpad pinch or rotate is
// two), and a card that can be dragged, pinched and rotated at once.
import SwiftUI
import UIKit

struct TouchDemo: View {
  enum Mode: String, CaseIterable {
    case paint = "Paint", transform = "Transform"
  }
  @State private var mode = Mode.paint

  var body: some View {
    DemoPage(feature: .touch, scrolls: false) {
      Picker("Mode", selection: $mode) {
        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
      }
      .pickerStyle(.segmented)
      switch mode {
      case .paint:
        PaintPanel()
      case .transform:
        TransformPanel()
      }
    }
  }
}

// MARK: - Paint

private struct PaintPanel: View {
  @State private var fingers = 0
  @State private var strokes = 0
  @State private var clearToken = 0

  var body: some View {
    VStack(spacing: 12) {
      ZStack(alignment: .topLeading) {
        TouchCanvas(clearToken: clearToken) { f, s in
          fingers = f
          strokes = s
        }
          .clipShape(.rect(cornerRadius: 24, style: .continuous))
        if strokes == 0 && fingers == 0 {
          VStack(spacing: 8) {
            Image(systemName: "hand.draw").font(.system(size: 40, weight: .light))
            Text("Click and drag to paint.\nPinch or rotate on the trackpad\nto see two fingers.")
              .multilineTextAlignment(.center).font(.callout)
          }
          .foregroundStyle(.white.opacity(0.55))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .allowsHitTesting(false)
        }
        HStack(spacing: 8) {
          StatusBadge(text: fingers == 1 ? "1 finger" : "\(fingers) fingers", symbol: "hand.point.up.left.fill",
                      color: fingers > 0 ? .pink : .white.opacity(0.7))
          Spacer()
          Button { clearToken += 1 } label: { Label("Clear", systemImage: "trash") }
            .buttonStyle(.glass).disabled(strokes == 0)
        }
        .padding(12)
      }
    }
  }
}

private struct TouchCanvas: UIViewRepresentable {
  var clearToken: Int
  var onChange: (Int, Int) -> Void

  func makeUIView(context: Context) -> TouchCanvasView {
    let v = TouchCanvasView()
    v.onChange = onChange
    return v
  }
  func updateUIView(_ v: TouchCanvasView, context: Context) {
    v.onChange = onChange
    if v.clearToken != clearToken {
      v.clearToken = clearToken
      v.clear()
    }
  }
}

final class TouchCanvasView: UIView {
  struct Stroke {
    var points: [CGPoint]
    var color: UIColor
  }
  var onChange: ((Int, Int) -> Void)?
  var clearToken = 0
  private var done: [Stroke] = []
  private var live: [ObjectIdentifier: Stroke] = [:]
  private var liveTouches: [ObjectIdentifier: CGPoint] = [:]
  private var colorIndex = 0
  private static let palette: [UIColor] = [
    UIColor(red: 1.00, green: 0.38, blue: 0.45, alpha: 1), UIColor(red: 0.36, green: 0.78, blue: 1.00, alpha: 1),
    UIColor(red: 1.00, green: 0.80, blue: 0.25, alpha: 1), UIColor(red: 0.50, green: 0.92, blue: 0.55, alpha: 1),
    UIColor(red: 0.78, green: 0.55, blue: 1.00, alpha: 1), UIColor(red: 1.00, green: 0.58, blue: 0.25, alpha: 1),
  ]

  override init(frame: CGRect) {
    super.init(frame: frame)
    isMultipleTouchEnabled = true
    backgroundColor = UIColor(red: 0.09, green: 0.09, blue: 0.13, alpha: 1)
    contentMode = .redraw
  }
  required init?(coder: NSCoder) {
    fatalError()
  }

  func clear() {
    done.removeAll()
    setNeedsDisplay()
    report()
  }
  private func report() {
    onChange?(liveTouches.count, done.count + live.count)
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    for t in touches {
      let p = t.location(in: self), id = ObjectIdentifier(t)
      live[id] = Stroke(points: [p], color: Self.palette[colorIndex % Self.palette.count])
      liveTouches[id] = p
      colorIndex += 1
    }
    setNeedsDisplay()
    report()
  }
  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    for t in touches {
      let id = ObjectIdentifier(t)
      for c in event?.coalescedTouches(for: t) ?? [t] {
        live[id]?.points.append(c.location(in: self))
      }
      liveTouches[id] = t.location(in: self)
    }
    setNeedsDisplay()
  }
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    finish(touches)
  }
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    finish(touches)
  }
  private func finish(_ touches: Set<UITouch>) {
    for t in touches {
      let id = ObjectIdentifier(t)
      if let s = live.removeValue(forKey: id) {
        done.append(s)
      }
      liveTouches[id] = nil
    }
    setNeedsDisplay()
    report()
  }

  override func draw(_ rect: CGRect) {
    guard let ctx = UIGraphicsGetCurrentContext() else {
      return
    }
    // a faint dot grid
    UIColor.white.withAlphaComponent(0.07).setFill()
    for x in stride(from: CGFloat(12), to: bounds.width, by: 24) {
      for y in stride(from: CGFloat(12), to: bounds.height, by: 24) {
        ctx.fillEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
      }
    }
    for s in done + Array(live.values) {
      draw(s, in: ctx)
    }
    // a ring under each finger
    for (id, p) in liveTouches {
      let color = live[id]?.color ?? .white
      let ring = UIBezierPath(ovalIn: CGRect(x: p.x - 30, y: p.y - 30, width: 60, height: 60))
      color.withAlphaComponent(0.22).setFill()
      ring.fill()
      color.setStroke()
      ring.lineWidth = 2.5
      ring.stroke()
    }
  }

  private func draw(_ s: Stroke, in ctx: CGContext) {
    guard let first = s.points.first else {
      return
    }
    let path = UIBezierPath()
    path.lineWidth = 7
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.move(to: first)
    if s.points.count == 1 {
      path.addLine(to: first)
    }
    // quadratic curves through the midpoints: smooth even with sparse samples
    for i in 1..<max(s.points.count, 1) {
      let a = s.points[i - 1], b = s.points[i]
      path.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), controlPoint: a)
    }
    if let last = s.points.last, s.points.count > 1 {
      path.addLine(to: last)
    }
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 12, color: s.color.withAlphaComponent(0.8).cgColor)
    s.color.setStroke()
    path.stroke()
    ctx.restoreGState()
  }
}

// MARK: - Transform

private struct TransformPanel: View {
  @State private var offset = CGSize.zero
  @State private var scale = 1.0
  @State private var angle = Angle.zero
  @GestureState private var drag = CGSize.zero
  @GestureState private var pinch = 1.0
  @GestureState private var twist = Angle.zero
  @State private var taps = 0

  var body: some View {
    VStack(spacing: 12) {
      ZStack {
        RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground))
        card
          .scaleEffect(scale * pinch)
          .rotationEffect(angle + twist)
          .offset(x: offset.width + drag.width, y: offset.height + drag.height)
      }
      .contentShape(.rect)
      // on the whole area, so both pinch fingers land in it wherever the pointer is
      .gesture(
        DragGesture()
          .updating($drag) { v, s, _ in s = v.translation }
          .onEnded { v in
            offset.width += v.translation.width
            offset.height += v.translation.height
          }
          .simultaneously(with: MagnifyGesture().updating($pinch) { v, s, _ in s = v.magnification }
            .onEnded { v in scale = min(max(scale * v.magnification, 0.4), 3) })
          .simultaneously(with: RotateGesture().updating($twist) { v, s, _ in s = v.rotation }
            .onEnded { v in angle += v.rotation })
      )
      .onTapGesture(count: 2) { withAnimation(.spring(duration: 0.5, bounce: 0.35)) { reset() } }
      .onTapGesture { taps += 1 }
      .clipShape(.rect(cornerRadius: 24, style: .continuous))

      HStack(spacing: 10) {
        Readout(label: "Scale", value: String(format: "×%.2f", scale * pinch))
        Readout(label: "Rotation", value: String(format: "%.0f°", (angle + twist).degrees))
        Readout(label: "Taps", value: "\(taps)")
      }
      Hint(text: "Drag the card with the mouse. On a trackpad, **pinch** to zoom and **rotate** with two fingers. Double-click to reset.",
           symbol: "hand.pinch.fill", tint: Feature.touch.tint)
    }
  }

  private func reset() {
    offset = .zero
    scale = 1
    angle = .zero
  }

  private var card: some View {
    VStack(spacing: 10) {
      Image(systemName: "hand.pinch.fill").font(.system(size: 44, weight: .medium))
      Text("Pinch · Rotate · Drag").font(.headline)
    }
    .foregroundStyle(.white)
    .frame(width: 210, height: 150)
    .background(Feature.touch.gradient, in: .rect(cornerRadius: 28, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 1))
    .shadow(color: Feature.touch.tint.opacity(0.4), radius: 18, y: 10)
    .contentShape(.rect(cornerRadius: 28))
  }
}

private struct Readout: View {
  let label: String
  let value: String
  var body: some View {
    VStack(spacing: 2) {
      Text(value).font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit().contentTransition(.numericText())
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity).padding(.vertical, 10)
    .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16, style: .continuous))
  }
}
