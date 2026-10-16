// Sandbox, Time & Region and This Watch: the app's own data container, the Mac's language, region and clock, and the
// watch SimRun runs it as.
import SwiftUI
import WatchKit

struct SandboxPage: View {
  var body: some View {
    List {
      Section {
        VStack(spacing: 0) {
          Text("\(LaunchRecord.count)").font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit()
            .foregroundStyle(Page.sandbox.gradient)
          Text(LaunchRecord.count == 1 ? "launch" : "launches").font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("launchCount")
      } footer: {
        Text("Kept in UserDefaults, in the app's own container: relaunch and it counts up.")
      }
      if let first = LaunchRecord.first {
        LabeledContent("First launch") { Text(first.formatted(date: .abbreviated, time: .shortened)) }
      }
      Section("Container") {
        Text(NSHomeDirectory()).font(.caption2.monospaced()).foregroundStyle(.secondary)
      }
    }
    .navigationTitle("Sandbox")
  }
}

struct TimePage: View {
  private let locale = Locale.autoupdatingCurrent
  var body: some View {
    List {
      TimelineView(.periodic(from: .now, by: 1)) { tl in
        VStack(spacing: 2) {
          Text(tl.date.formatted(date: .omitted, time: .standard))
            .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
            .foregroundStyle(Page.time.gradient).lineLimit(1).minimumScaleFactor(0.6)
          Text(tl.date.formatted(.dateTime.weekday(.wide).month().day())).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
      }
      LabeledContent("Language") { Text(locale.language.languageCode.flatMap { locale.localizedString(forLanguageCode: $0.identifier) } ?? "—") }
      LabeledContent("Region") { Text(locale.region.flatMap { locale.localizedString(forRegionCode: $0.identifier) } ?? "—") }
      LabeledContent("Locale") { Text(locale.identifier).font(.footnote.monospaced()) }
      LabeledContent("Time zone") { Text(TimeZone.current.identifier).font(.footnote) }
      LabeledContent("Number") { Text(1234.5.formatted(.number.locale(locale))) }
    }
    .navigationTitle("Time & Region")
  }
}

struct DevicePage: View {
  private let device = WKInterfaceDevice.current()
  private let env = ProcessInfo.processInfo.environment
  var body: some View {
    List {
      Section {
        Image(systemName: "applewatch.side.right").font(.system(size: 34)).foregroundStyle(Page.device.gradient)
          .frame(maxWidth: .infinity)
        Text(env["SIMULATOR_DEVICE_NAME"] ?? device.name).font(.headline).multilineTextAlignment(.center)
          .frame(maxWidth: .infinity)
      }
      LabeledContent("System") { Text("\(device.systemName) \(device.systemVersion)") }
      LabeledContent("Screen") { Text("\(Int(device.screenBounds.width))×\(Int(device.screenBounds.height)) @\(Int(device.screenScale))x") }
      if let model = env["SIMULATOR_MODEL_IDENTIFIER"] { LabeledContent("Model") { Text(model).font(.footnote.monospaced()) } }
      LabeledContent("Wrist") { Text(device.wristLocation == .left ? "Left" : "Right") }
      LabeledContent("Process") { Text("pid \(ProcessInfo.processInfo.processIdentifier)").monospacedDigit() }
    }
    .navigationTitle("This Watch")
  }
}
