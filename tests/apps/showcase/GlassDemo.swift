// Liquid Glass: ordinary page content with glass floating over it — a lens you can drag across the text, a toolbar
// whose buttons grow out of the plus button and merge back into it (GlassEffectContainer), and the glass button styles.
import SwiftUI

struct GlassDemo: View {
  @State private var expanded = false
  @State private var lens = CGPoint(x: 290, y: 330)
  @State private var lensStart: CGPoint?
  @State private var selected = "pencil.tip"
  private let tools = ["pencil.tip", "highlighter", "lasso", "eyedropper"]
  private static let button: CGFloat = 52, gap: CGFloat = 12

  var body: some View {
    ZStack {
      ScrollView { content.padding(.horizontal, 16).padding(.bottom, 180) }

      GeometryReader { geo in
        Circle().fill(.clear).frame(width: 120, height: 120)
          .glassEffect(.clear.interactive(), in: .circle)
          .position(lens)
          .gesture(DragGesture()
            .onChanged { v in   // follow the finger's movement from where the lens was, not jump to the finger
              let start = lensStart ?? lens
              lensStart = start
              withAnimation(.interactiveSpring) {
                lens = CGPoint(x: min(max(start.x + v.translation.width, 60), geo.size.width - 60),
                               y: min(max(start.y + v.translation.height, 60), geo.size.height - 60))
              }
            }
            .onEnded { _ in lensStart = nil })
      }

      VStack(spacing: 14) {
        Spacer()
        ToolbarGlass(spacing: expanded ? 8 : 20) {
          let open: CGFloat = expanded ? 1 : 0
          let step = Self.button + Self.gap, width = CGFloat(tools.count) * step + Self.button
          let plusX = Self.button / 2 + (1 - open) * (width - Self.button) / 2 + open * CGFloat(tools.count) * step
          ZStack {
            ForEach(Array(tools.enumerated()), id: \.element) { i, t in
              let scale = 0.4 + 0.6 * open
              Button { withAnimation(.snappy) { selected = t } } label: {
                Image(systemName: t).font(.title3)
                  .foregroundStyle(selected == t ? Color.accentColor : .primary)
                  .opacity(open).animation(.easeInOut(duration: 0.3), value: expanded)
                  .scaleEffect(scale)
                  .frame(width: Self.button * scale, height: Self.button * scale)
              }
              .buttonStyle(.plain)
              .glassEffect(.regular.interactive(), in: .circle)
              // closed, each tool sits shrunk under the plus button; opening moves it out to its place as it grows
              .position(x: plusX + open * (Self.button / 2 + CGFloat(i) * step - plusX), y: Self.button / 2)
              .allowsHitTesting(expanded)
              .accessibilityHidden(!expanded)
            }
            Button { withAnimation(.spring(duration: 0.5, bounce: 0.25)) { expanded.toggle() } } label: {
              Image(systemName: expanded ? "xmark" : "plus").font(.title3.weight(.semibold)).frame(width: Self.button, height: Self.button)
                .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .position(x: plusX, y: Self.button / 2)
          }
          .frame(width: width, height: Self.button)
        }
        GlassEffectContainer(spacing: 8) {
          HStack(spacing: 10) {
            Button("Glass") {}.buttonStyle(.glass)
            Button("Prominent") {}.buttonStyle(.glassProminent)
          }
          .controlSize(.large)
        }
      }
      .padding(.bottom, 40)
    }
    .background(Color(uiColor: .systemBackground))
    .navigationTitle(Feature.glass.title)
    .navigationBarTitleDisplayMode(.inline)
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 14) {
        FeatureIcon(feature: .glass, size: 52)
        VStack(alignment: .leading, spacing: 3) {
          Text(Feature.glass.title).font(.title2.weight(.bold))
          Text(Feature.glass.subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
      }
      .padding(.top, 8)

      Text("Drag the lens across this page. Glass bends and magnifies what's underneath it, so text and edges curve at its rim. The material is rendered by the app's own in-process render server, then shown in the Mac window.")
      Text("Press **+** to open the toolbar: the buttons are separate glass shapes in one GlassEffectContainer, so they flow out of each other and merge back when it closes.")
        .foregroundStyle(.secondary)

      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
        ForEach(Array(symbols.enumerated()), id: \.offset) { _, s in
          VStack(spacing: 6) {
            Image(systemName: s.0).font(.title2).foregroundStyle(s.1)
            Text(s.2).font(.caption).foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, minHeight: 84)
          .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 16, style: .continuous))
        }
      }

      Text("Scroll, and the content moves under the glass while the controls stay put, as in any app with a floating tab bar.")
        .foregroundStyle(.secondary)
      ForEach(0..<6) { i in
        HStack(spacing: 12) {
          RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(uiColor: .tertiarySystemFill)).frame(width: 44, height: 44)
            .overlay(Image(systemName: ["doc.text", "photo", "music.note", "map", "calendar", "envelope"][i]).foregroundStyle(.secondary))
          VStack(alignment: .leading, spacing: 2) {
            Text(["Notes", "Photos", "Music", "Maps", "Calendar", "Mail"][i]).font(.headline)
            Text("Row \(i + 1) of sample content").font(.subheadline).foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private let symbols: [(String, Color, String)] = [
    ("sun.max", .orange, "Sun"), ("cloud", .gray, "Cloud"), ("drop", .blue, "Rain"),
    ("leaf", .green, "Leaf"), ("moon", .indigo, "Moon"), ("snowflake", .cyan, "Snow"),
  ]
}

// A GlassEffectContainer whose spacing animates with the toolbar: 20 while closed, so the tools melt out of the plus
// button as they leave it, easing to 8 when open, below the 12 pt gaps, so the open buttons stand apart.
private struct ToolbarGlass<Content: View>: View, Animatable {
  var spacing: CGFloat
  @ViewBuilder var content: Content
  var animatableData: CGFloat {
    get {
      spacing
    }
    set {
      spacing = newValue
    }
  }
  var body: some View { GlassEffectContainer(spacing: spacing) { content } }
}
