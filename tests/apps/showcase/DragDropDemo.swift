// Drag & drop: drag stickers from a tray onto a board (SwiftUI .draggable / .dropDestination, i.e. UIDragInteraction
// and UIDropInteraction underneath), move them around on it, or drop them on the bin.
import SwiftUI

struct DragDropDemo: View {
  struct Sticker: Identifiable, Equatable {
    let id = UUID()
    var emoji: String
    var position: CGPoint
    var tilt: Double
  }
  private let tray = ["🍓", "🍋", "🫐", "🥝", "🍑", "🌈", "⭐️", "🚀", "🎈", "🪐"]
  @State private var stickers: [Sticker] = []
  @State private var boardTargeted = false
  @State private var binTargeted = false

  var body: some View {
    DemoPage(feature: .dragDrop, scrolls: false) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
          ForEach(tray, id: \.self) { e in
            Text(e).font(.system(size: 36)).frame(width: 58, height: 58)
              .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16, style: .continuous))
              .draggable("new:" + e) { Text(e).font(.system(size: 56)) }
          }
        }
        .padding(.vertical, 2)
      }
      .scrollClipDisabled()

      ZStack {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
          .fill(LinearGradient(colors: [Feature.dragDrop.colors[0].opacity(0.16), Feature.dragDrop.colors[1].opacity(0.10)],
                               startPoint: .top, endPoint: .bottom))
        RoundedRectangle(cornerRadius: 26, style: .continuous)
          .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: boardTargeted ? [] : [8, 6]))
          .foregroundStyle(boardTargeted ? Feature.dragDrop.tint : Color.secondary.opacity(0.4))
        if stickers.isEmpty {
          VStack(spacing: 6) {
            Image(systemName: "hand.draw").font(.system(size: 34, weight: .light))
            Text("Press and hold a sticker,\nthen drag it here").multilineTextAlignment(.center)
          }
          .foregroundStyle(.secondary).allowsHitTesting(false)
        }
        ForEach(stickers) { s in
          Text(s.emoji).font(.system(size: 54)).rotationEffect(.degrees(s.tilt))
            .shadow(color: .black.opacity(0.2), radius: 4, y: 3)
            .position(s.position)
            .draggable("move:" + s.id.uuidString) { Text(s.emoji).font(.system(size: 64)) }
            .transition(.scale(scale: 0.3).combined(with: .opacity))
        }
      }
      .scaleEffect(boardTargeted ? 1.01 : 1)
      .dropDestination(for: String.self) { items, location in
        guard let item = items.first else {
          return false
        }
        withAnimation(.spring(duration: 0.35, bounce: 0.4)) { place(item, at: location) }
        return true
      } isTargeted: { boardTargeted = $0 }
      .animation(.snappy, value: boardTargeted)

      HStack(spacing: 12) {
        Label(binTargeted ? "Release to delete" : "Drop here to delete", systemImage: binTargeted ? "trash.fill" : "trash")
          .font(.callout.weight(.semibold))
          .foregroundStyle(binTargeted ? .white : .red)
          .frame(maxWidth: .infinity, minHeight: 50)
          .background(binTargeted ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.red.opacity(0.12)),
                      in: .rect(cornerRadius: 16, style: .continuous))
          .dropDestination(for: String.self) { items, _ in
            guard let item = items.first, item.hasPrefix("move:") else {
              return false
            }
            let id = item.dropFirst(5)
            withAnimation(.spring) { stickers.removeAll { $0.id.uuidString == id } }
            return true
          } isTargeted: { binTargeted = $0 }
          .animation(.snappy, value: binTargeted)
        Button { withAnimation(.spring) { stickers.removeAll() } } label: { Image(systemName: "arrow.counterclockwise").frame(height: 32) }
          .buttonStyle(.glass).disabled(stickers.isEmpty)
      }
    }
  }

  private func place(_ item: String, at p: CGPoint) {
    if item.hasPrefix("new:") {
      stickers.append(Sticker(emoji: String(item.dropFirst(4)), position: p, tilt: .random(in: -14...14)))
    } else if item.hasPrefix("move:"), let i = stickers.firstIndex(where: { $0.id.uuidString == item.dropFirst(5) }) {
      stickers[i].position = p
    } else {   // text dragged in from somewhere else in the app
      stickers.append(Sticker(emoji: String(item.prefix(2)), position: p, tilt: 0))
    }
  }
}
