// Building blocks shared by the demo pages.
import SwiftUI

struct FeatureIcon: View {
  let feature: Feature
  var size: CGFloat = 44
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(feature.gradient)
      Image(systemName: feature.symbol).font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(.white)
    }
    .frame(width: size, height: size)
  }
}

struct PressableStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.96 : 1)
      .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
  }
}

// A demo page: a header tinted with the feature's colours, then the content in a scroll view.
struct DemoPage<Content: View>: View {
  let feature: Feature
  var scrolls = true
  @ViewBuilder var content: Content

  var body: some View {
    Group {
      if scrolls {
        ScrollView {
          VStack(spacing: 16) {
            header
            content
          }.padding(.horizontal, 16).padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
      } else {
        VStack(spacing: 16) {
          header
          content
        }.padding(.horizontal, 16).padding(.bottom, 12)
      }
    }
    .background(alignment: .top) {
      ZStack(alignment: .top) {
        Color(uiColor: .systemGroupedBackground)
        LinearGradient(colors: [feature.colors[0].opacity(0.35), feature.colors[1].opacity(0.08), .clear],
                       startPoint: .top, endPoint: .bottom)
          .frame(height: 420)
      }
      .ignoresSafeArea()
    }
    .navigationTitle(feature.title)
    .navigationBarTitleDisplayMode(.inline)
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 14) {
      FeatureIcon(feature: feature, size: 52)
      VStack(alignment: .leading, spacing: 3) {
        Text(feature.title).font(.system(.title2, design: .rounded, weight: .bold))
        Text(feature.subtitle).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(.top, 8)
  }
}

// A rounded card with an optional title row.
struct Panel<Content: View>: View {
  var title: String? = nil
  var symbol: String? = nil
  var trailing: AnyView? = nil
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let title {
        HStack(spacing: 6) {
          if let symbol {
            Image(systemName: symbol).foregroundStyle(.secondary)
          }
          Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
          Spacer()
          trailing
        }
      }
      content
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
  }
}

// "Try this" guidance, with the Mac-side half of the demo.
struct Hint: View {
  let text: LocalizedStringKey
  var symbol = "lightbulb.fill"
  var tint: Color = .orange
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: symbol).foregroundStyle(tint)
      Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(12)
    .background(tint.opacity(0.10), in: .rect(cornerRadius: 14, style: .continuous))
  }
}

struct InfoRow: View {
  let label: String
  let value: String
  var mono = false
  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label).foregroundStyle(.secondary)
      Spacer(minLength: 12)
      Text(value).font(mono ? .callout.monospaced() : .callout).multilineTextAlignment(.trailing).textSelection(.enabled)
    }
    .font(.callout)
  }
}

struct StatusBadge: View {
  let text: String
  var symbol: String = "checkmark.circle.fill"
  var color: Color = .green
  var body: some View {
    Label(text, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(color)
      .padding(.horizontal, 9).padding(.vertical, 5)
      .background(color.opacity(0.13), in: .capsule)
  }
}

// A transient message that slides in at the bottom of the page.
struct Toast: ViewModifier {
  @Binding var message: String?
  func body(content: Content) -> some View {
    content.overlay(alignment: .bottom) {
      if let message {
        Text(message).font(.subheadline.weight(.semibold)).padding(.horizontal, 18).padding(.vertical, 12)
          .glassEffect(.regular, in: .capsule)
          .padding(.bottom, 24)
          .transition(.move(edge: .bottom).combined(with: .opacity))
          .task(id: message) {
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(.spring) { self.message = nil }
          }
      }
    }
    .animation(.spring(duration: 0.4), value: message)
  }
}
extension View {
  func toast(_ message: Binding<String?>) -> some View {
    modifier(Toast(message: message))
  }
}

extension Data {
  var hex: String { map { String(format: "%02x", $0) }.joined() }
}

func byteString(_ n: Int) -> String {
  ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
}
