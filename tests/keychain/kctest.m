// kctest — the SecItem API from a sim process (exercises the keychain module; see docs/keychain.md).
//   kctest                          self-test: passwords, return types, limits, updates, duplicates, persistent refs,
//                                   access groups, sync, permanent keys, certificates and identities; leaves one demo
//                                   item behind (service "dev.simrun.kctest", account "demo") for SimRun's Keychain window
//   kctest list                     every generic/internet password this process can see, with its password
//   kctest set <account> <password> store a generic password (service dev.simrun.kctest)
//   kctest get <account>            print it
//   kctest rm <account>             delete it
#import <Foundation/Foundation.h>
#import <Security/Security.h>

#define SERVICE @"dev.simrun.kctest"

static int gFail;
static void check(BOOL ok, NSString *what) {
  printf("%s %s\n", ok ? "ok  " : "FAIL", what.UTF8String);
  if (!ok)
    gFail++;
}
static void check_status(OSStatus got, OSStatus want, NSString *what) {
  check(got == want, got == want ? what : [NSString stringWithFormat:@"%@ (status %d, want %d)", what, (int)got, (int)want]);
}
static NSData *utf8(NSString *s) {
  return [s dataUsingEncoding:NSUTF8StringEncoding];
}
static NSString *str(id d) {
  return [d isKindOfClass:NSData.class] ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
}

static NSMutableDictionary *genp(NSString *account) {
  return [@{ (id)kSecClass: (id)kSecClassGenericPassword, (id)kSecAttrService: SERVICE, (id)kSecAttrAccount: account } mutableCopy];
}
static id copy_matching(NSDictionary *q, OSStatus *st) {
  CFTypeRef r = NULL;
  *st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &r);
  return CFBridgingRelease(r);
}

// a P-256 key (X9.63: 04 || X || Y || K) and a self-signed certificate for it (CN=kctest)
static NSString *const kKey = @"BErJxIMlYnJUMrLV1wN5Kq02slbXSgg+znNLRQ3egayDwb89Q+3ZeO0kZZ5/iix6K7zrZH9R7R96pyjsqCna+s+2PplgibmnP3NiaGPMcAvRRA/zxfInENiBL+uA7x5vlA==";
static NSString *const kCert = @"MIIBeTCCAR+gAwIBAgIUMrBxhUapFjU63QpPQs0lJ744qBAwCgYIKoZIzj0EAwIwETEPMA0GA1UEAwwGa2N0ZXN0MCAXDTI2MTAxMDA5MTUwNFoYDzIxMjYwOTE2MDkxNTA0WjARMQ8wDQYDVQQDDAZrY3Rlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAARKycSDJWJyVDKy1dcDeSqtNrJW10oIPs5zS0UN3oGsg8G/PUPt2XjtJGWef4oseiu862R/Ue0feqco7Kgp2vrPo1MwUTAdBgNVHQ4EFgQUfVNuOezHbEvbnqpNblVMUdbkOFEwHwYDVR0jBBgwFoAUfVNuOezHbEvbnqpNblVMUdbkOFEwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiEA0ffH13c/yVrxtEzdSsQ9lG0t8hk88JIQyEJvlrI0fvMCIFDLoMN4KjSSoqjwCADVlz8zEaABy+QRpXTbpOP4bsGO";

static void cleanup(void) {
  SecItemDelete((__bridge CFDictionaryRef)@{ (id)kSecClass: (id)kSecClassGenericPassword, (id)kSecAttrService: SERVICE, (id)kSecAttrSynchronizable: (id)kSecAttrSynchronizableAny });
  SecItemDelete((__bridge CFDictionaryRef)@{ (id)kSecClass: (id)kSecClassGenericPassword, (id)kSecAttrService: SERVICE, (id)kSecAttrAccessGroup: @"dev.simrun.kctest.other" });
  SecItemDelete((__bridge CFDictionaryRef)@{ (id)kSecClass: (id)kSecClassInternetPassword, (id)kSecAttrServer: @"kctest.example.com" });
  SecItemDelete((__bridge CFDictionaryRef)@{ (id)kSecClass: (id)kSecClassKey, (id)kSecAttrApplicationTag: utf8(@"dev.simrun.kctest") });
  SecItemDelete((__bridge CFDictionaryRef)@{ (id)kSecClass: (id)kSecClassKey, (id)kSecAttrLabel: @"kctest identity" });
  SecItemDelete((__bridge CFDictionaryRef)@{ (id)kSecClass: (id)kSecClassCertificate, (id)kSecAttrLabel: @"kctest" });
}

static void passwords(void) {
  OSStatus st;
  NSMutableDictionary *add = genp(@"alice");
  add[(id)kSecValueData] = utf8(@"hunter2");
  add[(id)kSecAttrLabel] = @"kctest alice";
  check_status(SecItemAdd((__bridge CFDictionaryRef)add, NULL), errSecSuccess, @"add generic password");
  check_status(SecItemAdd((__bridge CFDictionaryRef)add, NULL), errSecDuplicateItem, @"add again -> duplicate");

  NSMutableDictionary *q = genp(@"alice");
  q[(id)kSecReturnData] = @YES;
  check([str(copy_matching(q, &st)) isEqual:@"hunter2"], @"read password (return data)");

  q = genp(@"alice");
  q[(id)kSecReturnAttributes] = @YES;
  NSDictionary *a = copy_matching(q, &st);
  check([a[(id)kSecAttrAccount] isEqual:@"alice"] && [a[(id)kSecAttrService] isEqual:SERVICE] && [a[(id)kSecAttrLabel] isEqual:@"kctest alice"] &&
        [a[(id)kSecAttrCreationDate] isKindOfClass:NSDate.class] && [a[(id)kSecAttrAccessGroup] length] && !a[(id)kSecValueData],
        [NSString stringWithFormat:@"attributes (group %@)", a[(id)kSecAttrAccessGroup]]);

  q[(id)kSecReturnData] = @YES;
  q[(id)kSecReturnPersistentRef] = @YES;
  a = copy_matching(q, &st);
  check([str(a[(id)kSecValueData]) isEqual:@"hunter2"] && [a[(id)kSecValuePersistentRef] isKindOfClass:NSData.class], @"attributes + data + persistent ref");
  NSData *pref = a[(id)kSecValuePersistentRef];
  check([str(copy_matching(@{ (id)kSecValuePersistentRef: pref, (id)kSecReturnData: @YES }, &st)) isEqual:@"hunter2"], @"read by persistent ref");

  NSMutableDictionary *upd = genp(@"alice");
  check_status(SecItemUpdate((__bridge CFDictionaryRef)upd, (__bridge CFDictionaryRef)@{ (id)kSecValueData: utf8(@"s3cret") }), errSecSuccess, @"update password");
  q = genp(@"alice");
  q[(id)kSecReturnData] = @YES;
  check([str(copy_matching(q, &st)) isEqual:@"s3cret"], @"read updated password");

  add = genp(@"bob");
  add[(id)kSecValueData] = utf8(@"b0b");
  check_status(SecItemAdd((__bridge CFDictionaryRef)add, NULL), errSecSuccess, @"add second account");
  check_status(SecItemUpdate((__bridge CFDictionaryRef)genp(@"bob"), (__bridge CFDictionaryRef)@{ (id)kSecAttrAccount: @"alice" }), errSecDuplicateItem,
               @"rename onto an existing account -> duplicate");
  NSArray *all = copy_matching(@{ (id)kSecClass: (id)kSecClassGenericPassword, (id)kSecAttrService: SERVICE,
                                  (id)kSecMatchLimit: (id)kSecMatchLimitAll, (id)kSecReturnAttributes: @YES }, &st);
  check([all isKindOfClass:NSArray.class] && all.count == 2, [NSString stringWithFormat:@"match limit all (%lu items)", (unsigned long)all.count]);
  check_status(SecItemCopyMatching((__bridge CFDictionaryRef)genp(@"carol"), NULL), errSecItemNotFound, @"missing account -> not found");

  // synchronizable items only show up when asked for
  add = genp(@"synced");
  add[(id)kSecValueData] = utf8(@"x");
  add[(id)kSecAttrSynchronizable] = @YES;
  check_status(SecItemAdd((__bridge CFDictionaryRef)add, NULL), errSecSuccess, @"add synchronizable item");
  check_status(SecItemCopyMatching((__bridge CFDictionaryRef)genp(@"synced"), NULL), errSecItemNotFound, @"hidden from plain queries");
  q = genp(@"synced");
  q[(id)kSecAttrSynchronizable] = (id)kSecAttrSynchronizableAny;
  check_status(SecItemCopyMatching((__bridge CFDictionaryRef)q, NULL), errSecSuccess, @"found with kSecAttrSynchronizableAny");

  // a group the app isn't entitled to: allowed (no checks), but only queries that name it see the item
  add = genp(@"grouped");
  add[(id)kSecValueData] = utf8(@"g");
  add[(id)kSecAttrAccessGroup] = @"dev.simrun.kctest.other";
  check_status(SecItemAdd((__bridge CFDictionaryRef)add, NULL), errSecSuccess, @"add to another access group");
  check_status(SecItemCopyMatching((__bridge CFDictionaryRef)genp(@"grouped"), NULL), errSecItemNotFound, @"not in the default groups");
  q = genp(@"grouped");
  q[(id)kSecAttrAccessGroup] = @"dev.simrun.kctest.other";
  check_status(SecItemCopyMatching((__bridge CFDictionaryRef)q, NULL), errSecSuccess, @"found when the query names the group");

  NSDictionary *inet = @{ (id)kSecClass: (id)kSecClassInternetPassword, (id)kSecAttrServer: @"kctest.example.com", (id)kSecAttrAccount: @"alice",
                          (id)kSecAttrProtocol: (id)kSecAttrProtocolHTTPS, (id)kSecAttrPort: @443, (id)kSecValueData: utf8(@"web") };
  check_status(SecItemAdd((__bridge CFDictionaryRef)inet, NULL), errSecSuccess, @"add internet password");
  check([str(copy_matching(@{ (id)kSecClass: (id)kSecClassInternetPassword, (id)kSecAttrServer: @"kctest.example.com", (id)kSecReturnData: @YES }, &st)) isEqual:@"web"],
        @"read internet password by server");

  check_status(SecItemDelete((__bridge CFDictionaryRef)genp(@"bob")), errSecSuccess, @"delete");
  check_status(SecItemDelete((__bridge CFDictionaryRef)genp(@"bob")), errSecItemNotFound, @"delete again -> not found");

  // the file holds the password as text
  NSString *data = NSProcessInfo.processInfo.environment[@"SIMULATOR_SHARED_RESOURCES_DIRECTORY"] ?: NSHomeDirectory();
  NSString *file = [data stringByAppendingPathComponent:@"Library/Keychains/simrun-keychain.plist"];
  NSString *text = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:NULL];
  check([text containsString:@"<string>s3cret</string>"], [NSString stringWithFormat:@"stored in plaintext (%@)", file]);
}

static void keys(void) {
  OSStatus st;
  NSData *tag = utf8(@"dev.simrun.kctest");
  CFErrorRef e = NULL;
  SecKeyRef priv = SecKeyCreateRandomKey((__bridge CFDictionaryRef)@{
    (id)kSecAttrKeyType: (id)kSecAttrKeyTypeECSECPrimeRandom, (id)kSecAttrKeySizeInBits: @256, (id)kSecAttrLabel: @"kctest key",
    (id)kSecPrivateKeyAttrs: @{ (id)kSecAttrIsPermanent: @YES, (id)kSecAttrApplicationTag: tag } }, &e);
  check(priv != NULL, [NSString stringWithFormat:@"permanent key generated%@", e ? [(__bridge id)e description] : @""]);
  if (!priv)
    return;
  SecKeyRef found = (__bridge_retained SecKeyRef)copy_matching(@{ (id)kSecClass: (id)kSecClassKey, (id)kSecAttrApplicationTag: tag,
    (id)kSecAttrKeyClass: (id)kSecAttrKeyClassPrivate, (id)kSecReturnRef: @YES }, &st);
  check_status(st, errSecSuccess, @"find the key by tag");
  if (!found) {
    CFRelease(priv);
    return;
  }
  NSData *msg = utf8(@"sign me");
  NSData *sig = CFBridgingRelease(SecKeyCreateSignature(found, kSecKeyAlgorithmECDSASignatureMessageX962SHA256, (__bridge CFDataRef)msg, NULL));
  SecKeyRef pub = SecKeyCopyPublicKey(priv);
  check(sig && SecKeyVerifySignature(pub, kSecKeyAlgorithmECDSASignatureMessageX962SHA256, (__bridge CFDataRef)msg, (__bridge CFDataRef)sig, NULL),
        @"the stored key signs like the generated one");
  NSDictionary *a = copy_matching(@{ (id)kSecClass: (id)kSecClassKey, (id)kSecAttrApplicationTag: tag, (id)kSecReturnAttributes: @YES }, &st);
  check([a[(id)kSecAttrLabel] isEqual:@"kctest key"] && [a[(id)kSecAttrKeySizeInBits] intValue] == 256, @"key attributes (label, size)");
  CFRelease(pub);
  CFRelease(found);
  CFRelease(priv);
}

static void identities(void) {
  OSStatus st;
  NSData *der = [[NSData alloc] initWithBase64EncodedString:kCert options:0];
  SecCertificateRef cert = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)der);
  SecKeyRef key = SecKeyCreateWithData((__bridge CFDataRef)[[NSData alloc] initWithBase64EncodedString:kKey options:0],
    (__bridge CFDictionaryRef)@{ (id)kSecAttrKeyType: (id)kSecAttrKeyTypeECSECPrimeRandom, (id)kSecAttrKeyClass: (id)kSecAttrKeyClassPrivate }, NULL);
  check(cert && key, @"test certificate and key");
  if (!cert || !key)
    return;
  check_status(SecItemAdd((__bridge CFDictionaryRef)@{ (id)kSecValueRef: (__bridge id)cert }, NULL), errSecSuccess, @"add certificate (class from the ref)");
  NSDictionary *a = copy_matching(@{ (id)kSecClass: (id)kSecClassCertificate, (id)kSecAttrLabel: @"kctest", (id)kSecReturnAttributes: @YES }, &st);
  check_status(st, errSecSuccess, @"find certificate by its subject summary");
  check([a[(id)kSecAttrSerialNumber] isKindOfClass:NSData.class] && [a[(id)kSecAttrPublicKeyHash] length] == 20, @"certificate attributes (serial, key hash)");
  check_status(SecItemCopyMatching((__bridge CFDictionaryRef)@{ (id)kSecClass: (id)kSecClassIdentity, (id)kSecAttrLabel: @"kctest" }, NULL), errSecItemNotFound,
               @"no identity without its key");
  check_status(SecItemAdd((__bridge CFDictionaryRef)@{ (id)kSecClass: (id)kSecClassKey, (id)kSecValueRef: (__bridge id)key, (id)kSecAttrLabel: @"kctest identity" }, NULL),
               errSecSuccess, @"add its private key");
  SecIdentityRef ident = (__bridge_retained SecIdentityRef)copy_matching(@{ (id)kSecClass: (id)kSecClassIdentity, (id)kSecAttrLabel: @"kctest", (id)kSecReturnRef: @YES }, &st);
  check(st == errSecSuccess && ident && CFGetTypeID(ident) == SecIdentityGetTypeID(), @"identity = certificate + key");
  if (ident) {
    SecCertificateRef c = NULL;
    SecIdentityCopyCertificate(ident, &c);
    check(c && [CFBridgingRelease(SecCertificateCopyData(c)) isEqual:der], @"identity's certificate");
    CFRelease(ident);
  }
  check_status(SecItemDelete((__bridge CFDictionaryRef)@{ (id)kSecClass: (id)kSecClassIdentity, (id)kSecAttrLabel: @"kctest" }), errSecSuccess, @"delete identity");
  check_status(SecItemCopyMatching((__bridge CFDictionaryRef)@{ (id)kSecClass: (id)kSecClassCertificate, (id)kSecAttrLabel: @"kctest" }, NULL), errSecItemNotFound,
               @"its certificate is gone");
  CFRelease(cert);
  CFRelease(key);
}

static void selftest(void) {
  cleanup();
  passwords();
  keys();
  identities();
  cleanup();
  NSMutableDictionary *demo = genp(@"demo");
  demo[(id)kSecValueData] = utf8(@"visible in SimRun ▸ Window ▸ Keychain");
  demo[(id)kSecAttrLabel] = @"kctest demo";
  SecItemAdd((__bridge CFDictionaryRef)demo, NULL);
  printf("%s\n", gFail ? "FAILED" : "PASSED");
}

int main(int argc, char **argv) {
  @autoreleasepool {
    NSString *cmd = argc > 1 ? @(argv[1]) : nil;
    OSStatus st;
    if (!cmd) {
      selftest();
      return gFail ? 1 : 0;
    }
    if ([cmd isEqual:@"list"]) {
      for (id cls in @[ (id)kSecClassGenericPassword, (id)kSecClassInternetPassword ]) {
        NSArray *all = copy_matching(@{ (id)kSecClass: cls, (id)kSecMatchLimit: (id)kSecMatchLimitAll, (id)kSecReturnAttributes: @YES, (id)kSecReturnData: @YES,
                                        (id)kSecAttrSynchronizable: (id)kSecAttrSynchronizableAny }, &st);
        for (NSDictionary *a in all)
          printf("%s  %-30s %-20s %s  [%s]\n", [cls UTF8String], [a[(id)kSecAttrService] ?: a[(id)kSecAttrServer] ?: @"" UTF8String],
                 [a[(id)kSecAttrAccount] ?: @"" UTF8String], str(a[(id)kSecValueData]).UTF8String ?: "<data>", [a[(id)kSecAttrAccessGroup] UTF8String]);
      }
      return 0;
    }
    if ([cmd isEqual:@"set"] && argc > 3) {
      NSMutableDictionary *q = genp(@(argv[2]));
      st = SecItemUpdate((__bridge CFDictionaryRef)q, (__bridge CFDictionaryRef)@{ (id)kSecValueData: utf8(@(argv[3])) });
      if (st == errSecItemNotFound) {
        q[(id)kSecValueData] = utf8(@(argv[3]));
        st = SecItemAdd((__bridge CFDictionaryRef)q, NULL);
      }
      printf("status %d\n", (int)st);
      return st != errSecSuccess;
    }
    if ([cmd isEqual:@"get"] && argc > 2) {
      NSMutableDictionary *q = genp(@(argv[2]));
      q[(id)kSecReturnData] = @YES;
      NSData *d = copy_matching(q, &st);
      if (st)
        printf("status %d\n", (int)st);
      else
        printf("%s\n", str(d).UTF8String);
      return st != errSecSuccess;
    }
    if ([cmd isEqual:@"rm"] && argc > 2) {
      st = SecItemDelete((__bridge CFDictionaryRef)genp(@(argv[2])));
      printf("status %d\n", (int)st);
      return st != errSecSuccess;
    }
    fprintf(stderr, "usage: kctest [list | set <account> <password> | get <account> | rm <account>]\n");
    return 2;
  }
}
