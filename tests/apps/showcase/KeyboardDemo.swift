// Keyboard: text input from the Mac keyboard, raw key presses (UIKit pressesBegan) shown as keycaps, and
// UIKeyCommand-backed keyboard shortcuts.
import SwiftUI
import UIKit

struct KeyboardDemo: View {
  @State private var text = ""
  @State private var presses: [KeyPress] = []
  @State private var shortcutHits = 0
  @State private var toast: String?
  @FocusState private var fieldFocused: Bool

  var body: some View {
    DemoPage(feature: .keyboard) {
      Panel(title: "Type", symbol: "character.cursor.ibeam") {
        TextField("Type something…", text: $text, axis: .vertical)
          .lineLimit(1...4)
          .focused($fieldFocused)
          .padding(12)
          .background(Color(uiColor: .tertiarySystemGroupedBackground), in: .rect(cornerRadius: 12, style: .continuous))
        if !text.isEmpty {
          Text(text).font(.system(size: 30, weight: .heavy, design: .rounded))
            .foregroundStyle(Feature.keyboard.gradient)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
          HStack(spacing: 8) {
            StatusBadge(text: "\(text.count) characters", symbol: "textformat.size", color: .indigo)
            StatusBadge(text: "\(text.split(whereSeparator: \.isWhitespace).count) words", symbol: "text.word.spacing", color: .teal)
          }
        }
      }
      .animation(.snappy, value: text.isEmpty)

      Panel(title: "Key presses", symbol: "command") {
        KeyCaptureArea { press in
          presses.insert(press, at: 0)
          if presses.count > 24 {
            presses.removeLast()
          }
        }
        .frame(height: 140)
        if !presses.isEmpty {
          FlowRow(presses) { KeyCap(press: $0) }
        }
      }

      Panel(title: "Shortcuts", symbol: "keyboard.badge.ellipsis") {
        HStack(spacing: 10) {
          Button {
            shortcutHits += 1
            toast = "⌘J pressed"
          } label: { Label("Jump", systemImage: "arrow.up.forward") }
            .keyboardShortcut("j", modifiers: .command)
          Button {
            presses.removeAll()
            toast = "Cleared"
          } label: { Label("Clear", systemImage: "xmark") }
            .keyboardShortcut("k", modifiers: .command)
          Spacer()
          Text("\(shortcutHits)").font(.title2.weight(.bold)).monospacedDigit().contentTransition(.numericText())
        }
        .buttonStyle(.glass)
        Text("**⌘J** and **⌘K** are UIKeyCommands; they work from anywhere on this page.")
          .font(.footnote).foregroundStyle(.secondary)
      }
      .animation(.snappy, value: shortcutHits)

      Hint(text: "Your Mac keyboard is the hardware keyboard: shift, arrows, ⌘A, Return and accented characters all work.",
           symbol: "keyboard", tint: Feature.keyboard.tint)
    }
    .toast($toast)
  }
}

struct KeyPress: Identifiable {
  let id = UUID()
  let modifiers: UIKeyModifierFlags
  let name: String
  let code: Int

  var label: String {
    var s = ""
    if modifiers.contains(.control) {
      s += "⌃"
    }
    if modifiers.contains(.alternate) {
      s += "⌥"
    }
    if modifiers.contains(.shift) {
      s += "⇧"
    }
    if modifiers.contains(.command) {
      s += "⌘"
    }
    return s + name
  }

  init(_ key: UIKey) {
    modifiers = key.modifierFlags
    code = key.keyCode.rawValue
    switch key.keyCode {
    case .keyboardReturnOrEnter:
      name = "↩"
    case .keyboardDeleteOrBackspace:
      name = "⌫"
    case .keyboardTab:
      name = "⇥"
    case .keyboardSpacebar:
      name = "Space"
    case .keyboardEscape:
      name = "⎋"
    case .keyboardLeftArrow:
      name = "←"
    case .keyboardRightArrow:
      name = "→"
    case .keyboardUpArrow:
      name = "↑"
    case .keyboardDownArrow:
      name = "↓"
    case .keyboardLeftShift, .keyboardRightShift:
      name = "Shift"
    case .keyboardLeftAlt, .keyboardRightAlt:
      name = "Option"
    case .keyboardLeftGUI, .keyboardRightGUI:
      name = "Command"
    case .keyboardLeftControl, .keyboardRightControl:
      name = "Control"
    case .keyboardCapsLock:
      name = "Caps Lock"
    default:
      let c = key.charactersIgnoringModifiers
      name = c.isEmpty ? "#\(key.keyCode.rawValue)" : c.uppercased()
    }
  }
}

private struct KeyCap: View {
  let press: KeyPress
  var body: some View {
    Text(press.label)
      .font(.system(.callout, design: .rounded, weight: .semibold))
      .padding(.horizontal, 10).frame(minWidth: 36, minHeight: 32)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(uiColor: .systemBackground))
          .shadow(color: .black.opacity(0.18), radius: 0, y: 2)
      )
      .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.black.opacity(0.08)))
      .transition(.scale(scale: 0.6).combined(with: .opacity))
  }
}

// A simple wrapping row (newest first).
private struct FlowRow<Item: Identifiable, V: View>: View {
  let items: [Item]
  let make: (Item) -> V
  init(_ items: [Item], @ViewBuilder make: @escaping (Item) -> V) {
    self.items = items
    self.make = make
  }
  var body: some View {
    FlowLayout(spacing: 6) { ForEach(items) { make($0) } }
      .animation(.spring(duration: 0.3), value: items.map(\.id))
  }
}

struct FlowLayout: Layout {
  var spacing: CGFloat = 8
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
    return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for row in arrange(width: bounds.width, subviews: subviews) {
      var x = bounds.minX
      for i in row.indices {
        let s = subviews[i].sizeThatFits(.unspecified)
        subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(s))
        x += s.width + spacing
      }
    }
  }
  private struct Row {
    var indices: [Int] = []
    var y: CGFloat = 0
    var width: CGFloat = 0
    var height: CGFloat = 0
  }
  private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
    var rows = [Row()]
    for (i, v) in subviews.enumerated() {
      let s = v.sizeThatFits(.unspecified)
      if !rows[rows.count - 1].indices.isEmpty && rows[rows.count - 1].width + spacing + s.width > width {
        let last = rows[rows.count - 1]
        rows.append(Row(y: last.y + last.height + spacing))
      }
      rows[rows.count - 1].width += (rows[rows.count - 1].indices.isEmpty ? 0 : spacing) + s.width
      rows[rows.count - 1].height = max(rows[rows.count - 1].height, s.height)
      rows[rows.count - 1].indices.append(i)
    }
    return rows
  }
}

// A first responder that reports raw key presses: click it, then press keys.
private struct KeyCaptureArea: UIViewRepresentable {
  var onPress: (KeyPress) -> Void
  func makeUIView(context: Context) -> KeyCaptureView {
    let v = KeyCaptureView()
    v.onPress = onPress
    return v
  }
  func updateUIView(_ v: KeyCaptureView, context: Context) {
    v.onPress = onPress
  }
}

final class KeyCaptureView: UIView {
  var onPress: ((KeyPress) -> Void)?
  private let label = UILabel()
  private let icon = UIImageView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.cornerRadius = 14
    layer.cornerCurve = .continuous
    layer.borderWidth = 2
    icon.contentMode = .scaleAspectFit
    icon.preferredSymbolConfiguration = .init(pointSize: 30, weight: .regular)
    label.font = .preferredFont(forTextStyle: .callout)
    label.textAlignment = .center
    label.numberOfLines = 2
    let stack = UIStackView(arrangedSubviews: [icon, label])
    stack.axis = .vertical
    stack.spacing = 8
    stack.alignment = .center
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor),
                                 stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12)])
    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    refresh()
  }
  required init?(coder: NSCoder) {
    fatalError()
  }

  @objc private func tapped() {
    _ = isFirstResponder ? resignFirstResponder() : becomeFirstResponder()
  }
  override var canBecomeFirstResponder: Bool { true }
  override func becomeFirstResponder() -> Bool {
    let r = super.becomeFirstResponder()
    refresh()
    return r
  }
  override func resignFirstResponder() -> Bool {
    let r = super.resignFirstResponder()
    refresh()
    return r
  }

  private func refresh() {
    let on = isFirstResponder
    backgroundColor = on ? UIColor.systemIndigo.withAlphaComponent(0.10) : .tertiarySystemGroupedBackground
    layer.borderColor = (on ? UIColor.systemIndigo : UIColor.clear).cgColor
    icon.image = UIImage(systemName: on ? "keyboard.fill" : "cursorarrow.click")
    icon.tintColor = on ? .systemIndigo : .secondaryLabel
    label.text = on ? "Listening — press any key\n(click again to stop)" : "Click here, then press keys"
    label.textColor = on ? .label : .secondaryLabel
  }

  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    var handled = false
    for p in presses {
      if let k = p.key {
        onPress?(KeyPress(k))
        handled = true
      }
    }
    if !handled {
      super.pressesBegan(presses, with: event)
    }
  }
}
