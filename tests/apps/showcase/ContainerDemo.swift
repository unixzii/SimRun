// Sandbox: the app's own data container. A launch counter in UserDefaults, notes saved as files in Documents, and the
// container's directories with their sizes.
import SwiftUI

struct ContainerDemo: View {
  @State private var note = ""
  @State private var files: [NoteFile] = []
  @State private var expanded: URL?
  @State private var toast: String?

  private let home = URL(fileURLWithPath: NSHomeDirectory())
  private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

  var body: some View {
    DemoPage(feature: .container) {
      launchPanel

      Panel(title: "Documents", symbol: "doc.text") {
        HStack(spacing: 8) {
          TextField("Write a note…", text: $note)
            .onSubmit(save)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: .rect(cornerRadius: 12, style: .continuous))
          Button(action: save) { Image(systemName: "square.and.arrow.down.fill").frame(width: 22, height: 22) }
            .buttonStyle(.glassProminent).tint(Feature.container.tint)
            .disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if files.isEmpty {
          Text("No files yet. Saved notes are written to Documents/ and are still here after a relaunch.")
            .font(.footnote).foregroundStyle(.secondary)
        } else {
          VStack(spacing: 0) {
            ForEach(files) { f in
              fileRow(f)
              if f.id != files.last?.id {
                Divider().padding(.leading, 40)
              }
            }
          }
        }
      }

      Panel(title: "Container", symbol: "folder") {
        VStack(alignment: .leading, spacing: 6) {
          Text(home.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            .lineLimit(4)
          Button {
            UIPasteboard.general.string = home.path
            toast = "Path copied — paste it in Finder's Go to Folder"
          } label: { Label("Copy Path", systemImage: "doc.on.doc") }
            .buttonStyle(.glass).controlSize(.small)
        }
        Divider()
        ForEach(["Documents", "Library/Preferences", "Library/Caches", "tmp"], id: \.self) { sub in
          InfoRow(label: sub, value: byteString(directorySize(home.appendingPathComponent(sub))), mono: true)
        }
      }

      Hint(text: "In SimRun's launcher, the app's menu has **App Container ▸ Show in Finder**. Each app gets its own container, like an iOS sandbox.",
           symbol: "shippingbox", tint: Feature.container.tint)
    }
    .onAppear(perform: reload)
    .toast($toast)
  }

  private var launchPanel: some View {
    Panel(title: "Launches", symbol: "arrow.clockwise") {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text("\(LaunchRecord.count)")
          .font(.system(size: 64, weight: .heavy, design: .rounded))
          .foregroundStyle(Feature.container.gradient)
        Text(LaunchRecord.count == 1 ? "launch" : "launches").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
      }
      if let first = LaunchRecord.first {
        InfoRow(label: "First launch", value: first.formatted(date: .abbreviated, time: .shortened))
      }
      if let prev = LaunchRecord.previous {
        InfoRow(label: "Previous launch", value: prev.formatted(.relative(presentation: .named)))
      }
      Text("Press **⌘R** to relaunch: the count is kept in UserDefaults inside this app's container.")
        .font(.footnote).foregroundStyle(.secondary)
    }
  }

  private func fileRow(_ f: NoteFile) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 12) {
        Image(systemName: "doc.text.fill").font(.title3).foregroundStyle(Feature.container.tint).frame(width: 28)
        VStack(alignment: .leading, spacing: 1) {
          Text(f.url.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1)
          Text("\(byteString(f.size)) · \(f.modified.formatted(date: .omitted, time: .standard))")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button(role: .destructive) { delete(f) } label: { Image(systemName: "trash") }
          .buttonStyle(.borderless).tint(.red)
      }
      .contentShape(.rect)
      .onTapGesture { withAnimation(.snappy) { expanded = expanded == f.url ? nil : f.url } }
      if expanded == f.url {
        Text((try? String(contentsOf: f.url, encoding: .utf8)) ?? "")
          .font(.callout).padding(10).frame(maxWidth: .infinity, alignment: .leading)
          .background(Color(uiColor: .tertiarySystemGroupedBackground), in: .rect(cornerRadius: 10))
          .padding(.leading, 40)
      }
    }
    .padding(.vertical, 8)
  }

  private func save() {
    let text = note.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else {
      return
    }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH.mm.ss"
    let url = documents.appendingPathComponent("Note \(f.string(from: Date())).txt")
    do {
      try text.write(to: url, atomically: true, encoding: .utf8)
      note = ""
      toast = "Saved to Documents"
    } catch {
      toast = error.localizedDescription
    }
    withAnimation(.snappy) { reload() }
  }

  private func delete(_ f: NoteFile) {
    try? FileManager.default.removeItem(at: f.url)
    withAnimation(.snappy) { reload() }
  }

  private func reload() {
    let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
    let urls = (try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
    files = urls.compactMap { u in
      let v = try? u.resourceValues(forKeys: Set(keys))
      return NoteFile(url: u, size: v?.fileSize ?? 0, modified: v?.contentModificationDate ?? .distantPast)
    }
    .sorted { $0.modified > $1.modified }
  }

  private func directorySize(_ url: URL) -> Int {
    guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
      return 0
    }
    var total = 0
    for case let u as URL in e {
      total += (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
    return total
  }
}

struct NoteFile: Identifiable {
  var id: URL { url }
  let url: URL
  let size: Int
  let modified: Date
}
