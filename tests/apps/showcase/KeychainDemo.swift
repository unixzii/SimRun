// Keychain: generic passwords through SecItemAdd / CopyMatching / Update / Delete, and a permanent P-256 signing key
// that is found again after a relaunch. SimRun's Keychain window (⇧⌘K) shows all of it.
import SwiftUI
import Security
import CryptoKit

private let service = "dev.simrun.showcase"
private let keyTag = Data("dev.simrun.showcase.signing".utf8)

struct KeychainDemo: View {
  @State private var account = ""
  @State private var password = ""
  @State private var items: [KeychainItem] = []
  @State private var revealed: Set<String> = []
  @State private var toast: String?
  @State private var key: SecKey?
  @State private var message = "Signed on iOS, inside SimRun"
  @State private var signature: (Data, Bool)?

  var body: some View {
    DemoPage(feature: .keychain) {
      Panel(title: "Save a password", symbol: "person.badge.key") {
        VStack(spacing: 8) {
          field("Account", text: $account, symbol: "person")
          field("Password", text: $password, symbol: "lock", secure: true)
        }
        Button(action: save) { Label("Save to Keychain", systemImage: "key.fill").frame(maxWidth: .infinity) }
          .buttonStyle(.glassProminent).tint(Feature.keychain.tint)
          .disabled(account.isEmpty || password.isEmpty)
      }

      Panel(title: "Stored items", symbol: "list.bullet.rectangle", trailing: AnyView(
        Text("\(items.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary))) {
        if items.isEmpty {
          Text("Nothing stored yet.").font(.callout).foregroundStyle(.secondary)
        }
        ForEach(items) { item in
          HStack(spacing: 12) {
            Image(systemName: "key.horizontal.fill").foregroundStyle(.white).frame(width: 32, height: 32)
              .background(Feature.keychain.gradient, in: .rect(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
              Text(item.account).font(.callout.weight(.medium))
              Text(revealed.contains(item.account) ? item.password : String(repeating: "•", count: min(item.password.count, 12)))
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            Button { withAnimation(.snappy) { toggle(item.account) } } label: {
              Image(systemName: revealed.contains(item.account) ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            Button(role: .destructive) { delete(item) } label: { Image(systemName: "trash") }
              .buttonStyle(.borderless).tint(.red)
          }
          .transition(.opacity.combined(with: .move(edge: .top)))
        }
      }

      signingPanel

      Hint(text: "Press **⇧⌘K** in SimRun to open the Keychain window: these items, in plaintext. Nothing here is encrypted.",
           symbol: "exclamationmark.lock.fill", tint: .orange)
    }
    .toast($toast)
    .onAppear {
      reload()
      key = Self.findKey()
    }
  }

  private var signingPanel: some View {
    Panel(title: "Signing key", symbol: "signature") {
      if let key, let pub = SecKeyCopyPublicKey(key), let ext = SecKeyCopyExternalRepresentation(pub, nil) as Data? {
        InfoRow(label: "Type", value: "P-256 (permanent)")
        InfoRow(label: "Fingerprint", value: SHA256.hash(data: ext).prefix(8).map { String(format: "%02x", $0) }.joined(separator: ":"), mono: true)
        TextField("Message", text: $message)
          .padding(.horizontal, 12).padding(.vertical, 10)
          .background(Color(uiColor: .tertiarySystemGroupedBackground), in: .rect(cornerRadius: 12, style: .continuous))
          .onChange(of: message) { signature = nil }
        HStack {
          Button { sign(with: key) } label: { Label("Sign & Verify", systemImage: "checkmark.seal") }
            .buttonStyle(.glass)
          Spacer()
          Button(role: .destructive) { deleteKey() } label: { Label("Delete Key", systemImage: "trash") }
            .buttonStyle(.borderless).tint(.red)
        }
        if let (sig, ok) = signature {
          HStack {
            StatusBadge(text: ok ? "Verified" : "Invalid", symbol: ok ? "checkmark.seal.fill" : "xmark.seal.fill", color: ok ? .green : .red)
            Text(sig.hex).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
          }
          .transition(.opacity)
        }
        Text("The key stays in the keychain; relaunch and it's still here.").font(.footnote).foregroundStyle(.secondary)
      } else {
        Text("Generate a permanent key with SecKeyCreateRandomKey, then sign with it.").font(.callout).foregroundStyle(.secondary)
        Button(action: generateKey) { Label("Generate Key", systemImage: "wand.and.stars") }
          .buttonStyle(.glass)
      }
    }
    .animation(.snappy, value: key == nil)
    .animation(.snappy, value: signature?.0)
  }

  private func field(_ title: String, text: Binding<String>, symbol: String, secure: Bool = false) -> some View {
    HStack(spacing: 10) {
      Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
      if secure {
        SecureField(title, text: text)
      } else {
        TextField(title, text: text).textInputAutocapitalization(.never).autocorrectionDisabled()
      }
    }
    .padding(.horizontal, 12).padding(.vertical, 10)
    .background(Color(uiColor: .tertiarySystemGroupedBackground), in: .rect(cornerRadius: 12, style: .continuous))
  }

  private func toggle(_ a: String) {
    if revealed.contains(a) {
      revealed.remove(a)
    } else {
      revealed.insert(a)
    }
  }

  // MARK: SecItem

  private func save() {
    let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    let data = Data(password.utf8)
    var st = SecItemAdd(query.merging([kSecValueData: data, kSecAttrLabel: "Showcase: \(account)"]) { $1 } as CFDictionary, nil)
    var verb = "Saved"
    if st == errSecDuplicateItem {
      st = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
      verb = "Updated"
    }
    toast = st == errSecSuccess ? "\(verb) “\(account)”" : "Error \(st)"
    if st == errSecSuccess {
      account = ""
      password = ""
    }
    withAnimation(.snappy) { reload() }
  }

  private func delete(_ item: KeychainItem) {
    let st = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: item.account] as CFDictionary)
    if st != errSecSuccess {
      toast = "Error \(st)"
    }
    withAnimation(.snappy) { reload() }
  }

  private func reload() {
    let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecMatchLimit: kSecMatchLimitAll,
                              kSecReturnAttributes: true, kSecReturnData: true]
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let rows = out as? [[CFString: Any]] else {
      items = []
      return
    }
    items = rows.compactMap { r in
      guard let a = r[kSecAttrAccount] as? String else {
        return nil
      }
      let pw = (r[kSecValueData] as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? "<binary>"
      return KeychainItem(account: a, password: pw, created: r[kSecAttrCreationDate] as? Date)
    }
    .sorted { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
  }

  // MARK: Keys

  static func findKey() -> SecKey? {
    let q: [CFString: Any] = [kSecClass: kSecClassKey, kSecAttrApplicationTag: keyTag, kSecAttrKeyClass: kSecAttrKeyClassPrivate,
                              kSecReturnRef: true]
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let out else { return nil }
    return (out as! SecKey)
  }

  private func generateKey() {
    let attrs: [CFString: Any] = [
      kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256,
      kSecAttrLabel: "Showcase signing key",
      kSecPrivateKeyAttrs: [kSecAttrIsPermanent: true, kSecAttrApplicationTag: keyTag] as [CFString: Any],
    ]
    var err: Unmanaged<CFError>?
    if let k = SecKeyCreateRandomKey(attrs as CFDictionary, &err) {
      key = k
      toast = "Key generated"
    }
    else {
      toast = (err?.takeRetainedValue() as Error?)?.localizedDescription ?? "Failed"
    }
  }

  private func deleteKey() {
    SecItemDelete([kSecClass: kSecClassKey, kSecAttrApplicationTag: keyTag] as CFDictionary)
    key = nil
    signature = nil
  }

  private func sign(with key: SecKey) {
    let data = Data(message.utf8), alg = SecKeyAlgorithm.ecdsaSignatureMessageX962SHA256
    var err: Unmanaged<CFError>?
    guard let sig = SecKeyCreateSignature(key, alg, data as CFData, &err) as Data?, let pub = SecKeyCopyPublicKey(key) else {
      toast = (err?.takeRetainedValue() as Error?)?.localizedDescription ?? "Signing failed"
      return
    }
    signature = (sig, SecKeyVerifySignature(pub, alg, data as CFData, sig as CFData, nil))
  }
}

struct KeychainItem: Identifiable {
  var id: String { account }
  let account: String
  let password: String
  let created: Date?
}
