// Language & Region: what the app sees after SimRun copies the Mac's settings into the device's preferences — locale,
// languages, calendar, first weekday, 12/24-hour clock — and how dates, numbers and units format with them.
import SwiftUI

struct LocaleDemo: View {
  private let locale = Locale.autoupdatingCurrent
  private var calendar: Calendar {
    var c = Calendar.autoupdatingCurrent
    c.locale = locale
    return c
  }

  var body: some View {
    DemoPage(feature: .locale) {
      TimelineView(.periodic(from: .now, by: 1)) { tl in
        VStack(spacing: 4) {
          Text(tl.date.formatted(date: .omitted, time: .standard))
            .font(.system(size: 54, weight: .semibold, design: .rounded)).monospacedDigit()
            .foregroundStyle(Feature.locale.gradient)
            .contentTransition(.numericText()).animation(.snappy, value: tl.date)
          Text(tl.date.formatted(date: .complete, time: .omitted)).font(.headline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 18)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
      }

      weekStrip

      Panel(title: "Settings", symbol: "gearshape") {
        InfoRow(label: "Language", value: name(language: locale.language.languageCode?.identifier))
        InfoRow(label: "Region", value: flag + " " + (locale.region.flatMap { locale.localizedString(forRegionCode: $0.identifier) } ?? "—"))
        InfoRow(label: "Locale", value: locale.identifier, mono: true)
        InfoRow(label: "Preferred", value: Locale.preferredLanguages.prefix(4).joined(separator: ", "), mono: true)
        InfoRow(label: "Calendar", value: locale.localizedString(for: calendar.identifier) ?? "\(calendar.identifier)")
        InfoRow(label: "First weekday", value: calendar.weekdaySymbols[calendar.firstWeekday - 1])
        InfoRow(label: "Clock", value: uses24Hour ? "24-hour" : "12-hour")
        InfoRow(label: "Measurement", value: measurementName)
        InfoRow(label: "Currency", value: [locale.currencySymbol, locale.currency?.identifier].compactMap { $0 }.joined(separator: " "))
        InfoRow(label: "Time zone", value: TimeZone.current.identifier)
      }

      Panel(title: "Formatting", symbol: "textformat.123") {
        InfoRow(label: "Number", value: 1234567.891.formatted(.number.locale(locale)))
        InfoRow(label: "Currency", value: 4299.5.formatted(.currency(code: locale.currency?.identifier ?? "USD").locale(locale)))
        InfoRow(label: "Percent", value: 0.875.formatted(.percent.locale(locale)))
        InfoRow(label: "Temperature", value: Measurement(value: 21.5, unit: UnitTemperature.celsius).formatted(.measurement(width: .abbreviated, usage: .weather).locale(locale)))
        InfoRow(label: "Distance", value: Measurement(value: 42.195, unit: UnitLength.kilometers).formatted(.measurement(width: .abbreviated, usage: .road).locale(locale)))
        InfoRow(label: "Date", value: Date().formatted(.dateTime.year().month(.wide).day().weekday(.wide).locale(locale)))
        InfoRow(label: "Relative", value: Date().addingTimeInterval(-3 * 3600).formatted(.relative(presentation: .named).locale(locale)))
        InfoRow(label: "List", value: ["SimRun", "UIKit", "SwiftUI"].formatted(.list(type: .and).locale(locale)))
      }

      Hint(text: "Change the Mac's **Language & Region** in System Settings, then relaunch with **⌘R**.",
           symbol: "globe", tint: Feature.locale.tint)
    }
  }

  private var weekStrip: some View {
    let symbols = calendar.veryShortStandaloneWeekdaySymbols
    let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 }
    let today = calendar.component(.weekday, from: .now) - 1
    return HStack(spacing: 6) {
      ForEach(order, id: \.self) { d in
        Text(symbols[d]).font(.callout.weight(.semibold))
          .frame(maxWidth: .infinity, minHeight: 40)
          .foregroundStyle(d == today ? .white : .primary)
          .background(d == today ? AnyShapeStyle(Feature.locale.gradient) : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground)),
                      in: .rect(cornerRadius: 12, style: .continuous))
      }
    }
  }

  private var uses24Hour: Bool { !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "").contains("a") }

  private var measurementName: String {
    switch locale.measurementSystem {
    case .us:
      "US"
    case .uk:
      "UK"
    default:
      "Metric"
    }
  }

  private var flag: String {
    guard let r = locale.region?.identifier, r.count == 2 else {
      return ""
    }
    return String(String.UnicodeScalarView(r.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }))
  }

  private func name(language code: String?) -> String {
    guard let code else {
      return "—"
    }
    let native = Locale(identifier: code).localizedString(forLanguageCode: code) ?? code
    return native.prefix(1).uppercased() + native.dropFirst()
  }
}
