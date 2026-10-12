# Keychain — a fake, plaintext keychain

**Status: working.** `SecItemAdd` / `SecItemCopyMatching` / `SecItemUpdate` / `SecItemDelete` work in every sim app,
for generic and internet passwords, keys, certificates and identities. Nothing is encrypted and nothing is checked:
items live in a property list in SimRun's data directory, and SimRun's **Keychain window** (Window ▸ Keychain, ⇧⌘K;
or Show Keychain Items on an app in the launcher / App menu) lists them with their passwords in plaintext.

```bash
make tests && build/bin/simrun run build/tests/kctest            # self-test (leaves a "demo" item behind)
build/bin/simrun run build/tests/kctest set alice hunter2        # store / read / list / delete a generic password
build/bin/simrun run build/tests/kctest get alice
build/bin/simrun run build/tests/kctest list
build/bin/simrun run build/tests/kctest rm alice
KEYCHAIN_VERBOSE=1 build/bin/simrun run …                        # trace every SecItem call, the store and access groups
```

## Why not the real one

The runtime's `securityd` does run under simns, but it serves only clients whose entitlements name an
`application-identifier` / `keychain-access-groups`, and it reads them in a way SimRun's processes don't satisfy: every
SecItem call — and every permanent key generation — fails with **-34018** (`errSecMissingEntitlement`). Real keychain
storage is also an encrypted SQLite database (`data/Library/Keychains/keychain-2-debug.db`) nobody can inspect.

## SimRun's version

```
app process
  SecItem*() ──interposed──▶ keychain module ─flock + read/modify/write──▶ data/Library/Keychains/simrun-keychain.plist
  SecKeyCreateRandomKey()                                                        ▲ watched; same lock
  SecKeyGeneratePair()                                         SimRun.app: Keychain window (keychainwindow.m)
```

- **The keychain module** (`src/sim/keychain/keychain.m`, in app.dylib) interposes the four SecItem functions and
  implements their semantics over the store; securityd is never contacted.
  - Store: `~/Library/Developer/SimRun/data/Library/Keychains/simrun-keychain.plist` — the shared data directory
    (`SIMULATOR_SHARED_RESOURCES_DIRECTORY`, follows `SIMRUN_DATA`), not the app's own container — mode
    0600. Format in `include/keychain.h`: per item its class, a UUID, the app that added it, the `kSecAttr*` attributes
    under their own keys (`acct`, `svce`, `agrp`, `cdat`, …) and the value — a password as a `<string>` when it is
    UTF-8, anything else as `<data>`. Every call locks the file (`flock` on `….lock`), reads it, and replaces it
    atomically if it changed it. No cache, so hand edits and edits from the Keychain window apply at once.
  - Matching: every attribute in the query must match (a missing string/data attribute equals the empty one);
    `kSecMatchLimit` (one / all / n), `kSecReturnData` / `Attributes` / `Ref` / `PersistentRef` in any combination
    (one → the object itself, several → a dictionary; with a limit > 1 → an array), `kSecValuePersistentRef`,
    `kSecValueRef` and `kSecMatchItemList` name items. Unset `kSecAttrSynchronizable` matches only non-syncing items,
    as on iOS; `kSecAttrSynchronizableAny` matches both.
  - Uniqueness per class, on add and on update (`errSecDuplicateItem`): passwords by account + service (internet:
    account, security domain, server, protocol, auth type, port, path), certificates by type + issuer + serial,
    keys by class + application label + tag + type + size, all within an access group and sync state.
  - Access groups: from the app's entitlements — the `__TEXT,__entitlements` section Xcode gives simulator builds, or
    the code signature's entitlements blob — `keychain-access-groups`, then `application-identifier`, then app groups;
    the bundle id if there are none (as for a device build, whose converted copy is signed ad hoc, without them). Adds without `kSecAttrAccessGroup` go to the first; queries without one see all of
    the app's groups (so apps don't see each other's items). Any group may be named explicitly: no entitlement check.
  - Ignored: `kSecAttrAccessControl` (no biometry or passcode prompt; the item is just stored), `kSecUse*`
    (authentication context, prompts, data-protection keychain), token ids. `kSecAttrAccessible` is stored and
    matched but means nothing — the "device" is always unlocked.
- **Keys and certificates** are stored as their external representation (`SecKeyCopyExternalRepresentation`,
  `SecCertificateCopyData`) plus the attributes securityd would record (`SecKeyCopyAttributes`; for certificates the
  subject summary as label, normalized subject/issuer, serial, public key hash). `kSecReturnRef` recreates a
  `SecKey` / `SecCertificate` from them, so a key found later signs and decrypts like the original. An **identity** is
  a stored certificate plus the private key whose application label is its public key hash (`SecIdentityCreate`);
  adding one stores both halves, deleting one removes both.
- **Permanent keys**: `SecKeyCreateRandomKey` with `kSecAttrIsPermanent` (top level, or in `kSecPrivateKeyAttrs` /
  `kSecPublicKeyAttrs`) adds the key from inside Security.framework, a call within one image that interposing can't
  catch. So it is interposed as well: the key is generated without permanence and then added here with the attributes
  meant for each half. `SecKeyGeneratePair` goes the same way.
- **Keychain window** (`src/host/simrund/services/keychainwindow.m`): one row per item (kind, service/server/label,
  account/tag, password, access group, app, modified) and every attribute of the selected item below. Filter by app,
  service, account or group; double-click a password item to edit its password; ⌫ or the context menu deletes; Show
  in Finder reveals the file. It watches the directory and reloads when apps change the file.

`KEYCHAIN_DISABLE=1` leaves the SecItem API alone (calls go to securityd, i.e. fail with -34018 as before).

## Not supported

- Access control: no Face ID / passcode prompts, `LAContext` is never consulted; items are always readable.
- Keys whose data can't be exported can't be stored (`errSecParam`); that includes Secure Enclave keys
  (`kSecAttrTokenIDSecureEnclave`, untested).
- Only calls that cross into Security.framework are seen: other Security.framework internals that store items
  themselves bypass the store.
- iCloud Keychain sync: `kSecAttrSynchronizable` is an attribute like any other.
- Shared web credentials (`SecAddSharedWebCredential`), Password AutoFill, `ASAuthorizationPasswordProvider`.
