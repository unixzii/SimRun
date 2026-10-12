// keychain.dylib — a fake keychain (SIM platform; see docs/keychain.md).
// Security.framework's SecItem* calls go to securityd, which wants the client's entitlements (application-identifier,
// keychain-access-groups) and answers -34018 (errSecMissingEntitlement) to every app SimRun runs. Instead, this dylib
// interposes the SecItem API and keeps the items itself, in plaintext, in SimRun's keychain file (include/keychain.h),
// where SimRun's Keychain window shows them. No encryption, no code-signing checks, no securityd.
//   * classes: generic and internet passwords; keys and certificates (stored as their external representation and
//     handed back as fresh SecKey/SecCertificate refs); identities (a stored certificate + the private key whose
//     application label is the certificate's public key hash).
//   * access groups: an app sees the groups its entitlements name (keychain-access-groups, application-identifier,
//     app groups; from the __entitlements section Xcode gives simulator builds, else the code signature), or its
//     bundle id if it has none. Adds go to the first one. A query that names a group gets it, entitled or not.
//   * permanent keys: SecKeyCreateRandomKey / SecKeyGeneratePair store the key from inside Security.framework (an
//     intra-image call we can't interpose), so those are interposed too: the key is made non-permanent, then added.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <CommonCrypto/CommonDigest.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <arpa/inet.h>
#include <errno.h>
#include <pthread.h>
#include "keychain.h"
#import "common.h"

int csops(pid_t pid, unsigned int ops, void *addr, size_t size);
#define CS_OPS_ENTITLEMENTS_BLOB 7
SecIdentityRef SecIdentityCreate(CFAllocatorRef allocator, SecCertificateRef certificate, SecKeyRef privateKey);   // SPI

static int gVerbose, gDisabled;
#define LOG(...) do { if (gVerbose) fprintf(stderr, "[keychain] " __VA_ARGS__); } while (0)

static NSString *gPath;                  // the store
static NSArray<NSString *> *gGroups;     // access groups this app sees; [0] is where adds go
static NSString *gCreator;               // recorded with new items (for SimRun's Keychain window)
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;   // in-process; the store's flock covers other processes

// ---------------------------------------------------------------- access groups
static NSDictionary *read_entitlements(void) {
  // simulator builds: Xcode embeds the entitlements as an XML plist in __TEXT,__entitlements (the ad-hoc signature
  // carries none); device-style signing puts them in the code signature's entitlements blob
  unsigned long size = 0;
  const uint8_t *p = getsectiondata((const struct mach_header_64 *)_dyld_get_image_header(0), "__TEXT", "__entitlements", &size);
  NSData *xml = p && size ? [NSData dataWithBytes:p length:size] : nil;
  if (!xml) {
    uint32_t hdr[2] = {0};
    if (csops(getpid(), CS_OPS_ENTITLEMENTS_BLOB, hdr, sizeof hdr) == -1 && errno == ERANGE) {
      uint32_t len = ntohl(hdr[1]);
      NSMutableData *blob = len > 8 && len < (1 << 20) ? [NSMutableData dataWithLength:len] : nil;
      if (blob && csops(getpid(), CS_OPS_ENTITLEMENTS_BLOB, blob.mutableBytes, len) == 0) xml = [blob subdataWithRange:NSMakeRange(8, len - 8)];
    }
  }
  id e = xml ? [NSPropertyListSerialization propertyListWithData:xml options:0 format:NULL error:NULL] : nil;
  return [e isKindOfClass:NSDictionary.class] ? e : nil;
}

static void setup_groups(void) {
  NSDictionary *e = read_entitlements();
  NSMutableOrderedSet *g = [NSMutableOrderedSet orderedSet];
  void (^add)(id) = ^(id v) {
    if ([v isKindOfClass:NSString.class] && [v length]) [g addObject:v];
    else if ([v isKindOfClass:NSArray.class]) for (id s in v) if ([s isKindOfClass:NSString.class] && [s length]) [g addObject:s];
  };
  add(e[@"keychain-access-groups"]);
  add(e[@"application-identifier"]);
  add(e[@"com.apple.security.application-groups"]);
  gCreator = NSBundle.mainBundle.bundleIdentifier ?: @(getprogname());
  if (!g.count) [g addObject:gCreator];
  gGroups = g.array;
}

// ---------------------------------------------------------------- attributes
static NSString *const kGenp = @"genp", *const kInet = @"inet", *const kKeys = @"keys", *const kCert = @"cert", *const kIdnt = @"idnt";
static BOOL is_password_class(NSString *c) { return [c isEqual:kGenp] || [c isEqual:kInet]; }

// Query/attribute dictionary keys that aren't item attributes: kSecClass, kSecValue* (v_), kSecReturn* (r_),
// kSecMatch* (m_), kSecUse* (u_, nleg), and what a plist can't hold or a fake keychain can't honor: access control
// objects (accc), token ids (tkid), permanence (perm: everything here is).
static BOOL is_control_key(NSString *k) {
  return [k isEqual:@"class"] || [k hasPrefix:@"v_"] || [k hasPrefix:@"r_"] || [k hasPrefix:@"m_"] || [k hasPrefix:@"u_"] ||
         [k isEqual:@"nleg"] || [k isEqual:@"accc"] || [k isEqual:@"tkid"] || [k isEqual:@"perm"] ||
         [k isEqual:@"private"] || [k isEqual:@"public"];   // kSecPrivateKeyAttrs / kSecPublicKeyAttrs
}
static BOOL is_plist(id v) {
  if ([v isKindOfClass:NSString.class] || [v isKindOfClass:NSData.class] || [v isKindOfClass:NSDate.class] || [v isKindOfClass:NSNumber.class]) return YES;
  if ([v isKindOfClass:NSArray.class]) { for (id x in v) if (!is_plist(x)) return NO; return YES; }
  return NO;
}
static NSMutableDictionary *attributes_of(NSDictionary *q) {
  NSMutableDictionary *a = [NSMutableDictionary dictionary];
  [q enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
    if (![k isKindOfClass:NSString.class] || is_control_key(k)) return;
    if (is_plist(v)) a[k] = [k isEqual:@"type"] || [k isEqual:@"kcls"] ? [v description] : v;   // key type/class: CFString constants ("73", "1")
    else LOG("ignoring attribute %s (%s)\n", [k UTF8String], object_getClassName(v));
  }];
  return a;
}

// Attribute equality as securityd sees it: a missing string/data attribute is the empty one, numbers and their
// string forms ("1" vs 1 for a key class) are the same value.
static id norm(id v) {
  if (!v || v == NSNull.null) return nil;
  if ([v isKindOfClass:NSString.class] && ![v length]) return nil;
  if ([v isKindOfClass:NSData.class] && ![v length]) return nil;
  return v;
}
static BOOL attr_equal(id a, id b) {
  a = norm(a); b = norm(b);
  if (!a || !b) return a == b;
  if ([a isEqual:b]) return YES;
  if ([a isKindOfClass:NSNumber.class] && [b isKindOfClass:NSString.class]) return [[a stringValue] isEqual:b];
  if ([a isKindOfClass:NSString.class] && [b isKindOfClass:NSNumber.class]) return [a isEqual:[b stringValue]];
  return NO;
}
static BOOL truthy(id v) { return [v respondsToSelector:@selector(boolValue)] && [v boolValue]; }

// Uniqueness: an add (or update) that would give two items of a class the same values for these is a duplicate.
static NSArray<NSString *> *primary_keys(NSString *cls) {
  if ([cls isEqual:kGenp]) return @[ @"acct", @"svce", @"agrp", @"sync" ];
  if ([cls isEqual:kInet]) return @[ @"acct", @"sdmn", @"srvr", @"ptcl", @"atyp", @"port", @"path", @"agrp", @"sync" ];
  if ([cls isEqual:kCert]) return @[ @"ctyp", @"issr", @"slnr", @"agrp", @"sync" ];
  if ([cls isEqual:kKeys]) return @[ @"kcls", @"klbl", @"atag", @"type", @"bsiz", @"esiz", @"sdat", @"edat", @"agrp", @"sync" ];
  return @[];
}
static NSMutableDictionary *find_duplicate(NSArray<NSMutableDictionary *> *items, NSString *cls, NSDictionary *attrs, NSSet *except) {
  NSArray *keys = primary_keys(cls);
  for (NSMutableDictionary *it in items) {
    if (![it[@"class"] isEqual:cls] || [except containsObject:it[@"uuid"]]) continue;
    BOOL same = YES;
    for (NSString *k in keys) if (!attr_equal(it[@"attributes"][k], attrs[k])) { same = NO; break; }
    if (same) return it;
  }
  return nil;
}

// ---------------------------------------------------------------- values and refs
static NSData *value_data(NSDictionary *item) {
  id v = item[@"value"];
  if ([v isKindOfClass:NSString.class]) return [v dataUsingEncoding:NSUTF8StringEncoding];
  return [v isKindOfClass:NSData.class] ? v : [NSData data];
}
// Passwords are stored as text when that round-trips, so the file (and SimRun) show them as they are.
static id stored_value(NSString *cls, NSData *d) {
  if (!d) d = [NSData data];
  if (is_password_class(cls)) {
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (s && [[s dataUsingEncoding:NSUTF8StringEncoding] isEqual:d]) return s;
  }
  return d;
}

static NSString *ref_class(CFTypeRef r) {
  if (!r) return nil;
  CFTypeID t = CFGetTypeID(r);
  if (t == SecKeyGetTypeID()) return kKeys;
  if (t == SecCertificateGetTypeID()) return kCert;
  if (t == SecIdentityGetTypeID()) return kIdnt;
  return nil;
}
// The data a key or certificate ref is stored as.
static NSData *ref_data(CFTypeRef r) {
  NSString *c = ref_class(r);
  if ([c isEqual:kKeys]) return CFBridgingRelease(SecKeyCopyExternalRepresentation((SecKeyRef)r, NULL));
  if ([c isEqual:kCert]) return CFBridgingRelease(SecCertificateCopyData((SecCertificateRef)r));
  return nil;
}
// What securityd records for a key: its own attributes (class, type, size, application label, usage flags).
static NSDictionary *key_attributes(SecKeyRef k) { return attributes_of(CFBridgingRelease(SecKeyCopyAttributes(k)) ?: @{}); }
static NSDictionary *cert_attributes(SecCertificateRef c) {
  NSMutableDictionary *a = [NSMutableDictionary dictionary];
  a[@"ctyp"] = @3; a[@"cenc"] = @3;   // X.509 v3, DER
  a[@"labl"] = CFBridgingRelease(SecCertificateCopySubjectSummary(c));
  a[@"subj"] = CFBridgingRelease(SecCertificateCopyNormalizedSubjectSequence(c));
  a[@"issr"] = CFBridgingRelease(SecCertificateCopyNormalizedIssuerSequence(c));
  a[@"slnr"] = CFBridgingRelease(SecCertificateCopySerialNumberData(c, NULL));
  SecKeyRef k = SecCertificateCopyKey(c);
  if (k) { a[@"pkhh"] = key_attributes(k)[@"klbl"]; CFRelease(k); }
  return a;
}
static CFTypeRef make_ref(NSDictionary *item) {
  NSString *cls = item[@"class"];
  NSDictionary *a = item[@"attributes"];
  NSData *d = value_data(item);
  if ([cls isEqual:kCert]) return SecCertificateCreateWithData(NULL, (__bridge CFDataRef)d);
  if ([cls isEqual:kKeys]) {
    NSMutableDictionary *p = [NSMutableDictionary dictionary];
    for (NSString *k in @[ @"type", @"kcls", @"bsiz" ]) if (a[k]) p[k] = [k isEqual:@"bsiz"] ? a[k] : [a[k] description];
    CFErrorRef e = NULL;
    SecKeyRef key = SecKeyCreateWithData((__bridge CFDataRef)d, (__bridge CFDictionaryRef)p, &e);
    if (!key) { LOG("stored key %s can't be recreated: %s\n", [item[@"uuid"] UTF8String], [[(__bridge id)e description] UTF8String]); if (e) CFRelease(e); }
    return key;
  }
  return NULL;
}

// Persistent refs: the class (4 bytes) + the item's UUID (16 bytes).
static NSData *persistent_ref(NSString *cls, NSString *uuid) {
  uuid_t u = {0}; [[[NSUUID alloc] initWithUUIDString:uuid] getUUIDBytes:u];
  NSMutableData *d = [[cls dataUsingEncoding:NSASCIIStringEncoding] mutableCopy];
  [d appendBytes:u length:sizeof u];
  return d;
}
static BOOL parse_persistent_ref(id v, NSString **cls, NSString **uuid) {
  if (![v isKindOfClass:NSData.class] || [v length] != 20) return NO;
  *cls = [[NSString alloc] initWithData:[v subdataWithRange:NSMakeRange(0, 4)] encoding:NSASCIIStringEncoding];
  *uuid = [[NSUUID alloc] initWithUUIDBytes:(const uint8_t *)[v bytes] + 4].UUIDString;
  return *cls != nil;
}

// ---------------------------------------------------------------- matching
// A match: one stored item, or for identities a certificate and its private key.
@interface SRMatch : NSObject
@property NSMutableDictionary *item, *key;
@end
@implementation SRMatch
@end

// The class a query is about: kSecClass, else what its persistent ref or value ref says.
static NSString *query_class(NSDictionary *q) {
  id c = q[(id)kSecClass];
  if ([c isKindOfClass:NSString.class]) return c;
  NSString *pc, *pu;
  if (parse_persistent_ref(q[(id)kSecValuePersistentRef], &pc, &pu)) return pc;
  return ref_class((__bridge CFTypeRef)q[(id)kSecValueRef]);
}

static BOOL item_matches(NSDictionary *item, NSDictionary *q, NSDictionary *attrs) {
  NSDictionary *a = item[@"attributes"];
  for (NSString *k in attrs) {
    if ([k isEqual:@"agrp"] || [k isEqual:@"sync"]) continue;
    if (!attr_equal(a[k], attrs[k])) return NO;
  }
  id g = q[(id)kSecAttrAccessGroup];
  if ([g isKindOfClass:NSString.class] ? ![a[@"agrp"] isEqual:g] : ![gGroups containsObject:a[@"agrp"] ?: @""]) return NO;
  id s = q[(id)kSecAttrSynchronizable];   // unset: only items that don't sync (as on iOS)
  if (![s isEqual:(id)kSecAttrSynchronizableAny] && truthy(s) != truthy(a[@"sync"])) return NO;
  return YES;
}

// Constraints that name items rather than attributes: a persistent ref, a value ref, an item list.
static BOOL item_is_named(NSDictionary *item, NSString *cls, id what) {
  NSString *pc, *pu;
  if (parse_persistent_ref(what, &pc, &pu)) return [item[@"uuid"] isEqual:pu];
  if (CFGetTypeID((__bridge CFTypeRef)what) == SecIdentityGetTypeID()) {
    SecCertificateRef c = NULL; SecIdentityCopyCertificate((__bridge SecIdentityRef)what, &c);
    BOOL same = c && [ref_data(c) isEqual:value_data(item)];
    if (c) CFRelease(c);
    return same;
  }
  NSData *d = ref_data((__bridge CFTypeRef)what);
  return d && [d isEqual:value_data(item)];
}
static BOOL named_matches(NSDictionary *item, NSString *cls, NSDictionary *q) {
  id pr = q[(id)kSecValuePersistentRef], vr = q[(id)kSecValueRef], list = q[(id)kSecMatchItemList];
  if (pr && !item_is_named(item, cls, pr)) return NO;
  if (vr && !is_password_class(cls) && !item_is_named(item, cls, vr)) return NO;
  if ([list isKindOfClass:NSArray.class]) {
    for (id x in list) if (item_is_named(item, cls, x)) return YES;
    return NO;
  }
  return YES;
}

static NSUInteger match_limit(NSDictionary *q) {
  id l = q[(id)kSecMatchLimit];
  if ([l isEqual:(id)kSecMatchLimitAll]) return NSUIntegerMax;
  if ([l isKindOfClass:NSNumber.class]) return MAX([l integerValue], 1);
  return 1;
}

static NSArray<SRMatch *> *find(NSArray<NSMutableDictionary *> *items, NSString *cls, NSDictionary *q, NSUInteger limit) {
  NSDictionary *attrs = attributes_of(q);
  NSMutableArray *out = [NSMutableArray array];
  if ([cls isEqual:kIdnt]) {   // certificates that have their private key here
    for (NSMutableDictionary *cert in items) {
      if (out.count >= limit) break;
      if (![cert[@"class"] isEqual:kCert] || !named_matches(cert, kIdnt, q)) continue;
      id pkhh = cert[@"attributes"][@"pkhh"];
      if (!pkhh) continue;
      for (NSMutableDictionary *key in items) {
        NSDictionary *ka = key[@"attributes"];
        if (![key[@"class"] isEqual:kKeys] || !attr_equal(ka[@"kcls"], @"1") || !attr_equal(ka[@"klbl"], pkhh)) continue;
        // an attribute may belong to either half (label, access group: the cert; application tag: the key)
        NSMutableDictionary *merged = [ka mutableCopy];
        [merged addEntriesFromDictionary:cert[@"attributes"]];
        if (!item_matches(@{ @"attributes": merged }, q, attrs)) continue;
        SRMatch *m = [SRMatch new]; m.item = cert; m.key = key;
        [out addObject:m];
        break;
      }
    }
    return out;
  }
  for (NSMutableDictionary *it in items) {
    if (out.count >= limit) break;
    if (![it[@"class"] isEqual:cls] || !named_matches(it, cls, q) || !item_matches(it, q, attrs)) continue;
    SRMatch *m = [SRMatch new]; m.item = it;
    [out addObject:m];
  }
  return out;
}

// ---------------------------------------------------------------- results
typedef struct { BOOL data, attrs, ref, pref; } want_t;
static want_t wanted(NSDictionary *q) {
  return (want_t){ truthy(q[(id)kSecReturnData]), truthy(q[(id)kSecReturnAttributes]), truthy(q[(id)kSecReturnRef]), truthy(q[(id)kSecReturnPersistentRef]) };
}
static BOOL wants_any(want_t w) { return w.data || w.attrs || w.ref || w.pref; }

// One match as SecItemCopyMatching returns it: the single thing asked for, or a dictionary when several were.
static id result_for(SRMatch *m, NSString *cls, want_t w) {
  NSDictionary *item = m.item;
  id data = w.data ? value_data(item) : nil;
  id pref = w.pref ? persistent_ref(cls, item[@"uuid"]) : nil;
  id ref = nil;
  if (w.ref && [cls isEqual:kIdnt]) {
    SecCertificateRef c = (SecCertificateRef)make_ref(item);
    SecKeyRef k = (SecKeyRef)make_ref(m.key);
    if (c && k) ref = CFBridgingRelease(SecIdentityCreate(NULL, c, k));
    if (c) CFRelease(c);
    if (k) CFRelease(k);
  } else if (w.ref) ref = CFBridgingRelease(make_ref(item));   // none for passwords
  NSMutableDictionary *attrs = nil;
  if (w.attrs) {
    attrs = [item[@"attributes"] mutableCopy];
    if (m.key) for (NSString *k in @[ @"atag", @"klbl", @"kcls", @"type", @"bsiz" ]) if (m.key[@"attributes"][k] && !attrs[k]) attrs[k] = m.key[@"attributes"][k];
    attrs[@"class"] = cls;
  }
  int n = w.data + w.attrs + w.ref + w.pref;
  if (n == 1) return attrs ?: data ?: ref ?: pref;
  NSMutableDictionary *d = attrs ?: [NSMutableDictionary dictionary];
  if (data) d[(id)kSecValueData] = data;
  if (ref) d[(id)kSecValueRef] = ref;
  if (pref) d[(id)kSecValuePersistentRef] = pref;
  return d;
}

// ---------------------------------------------------------------- operations
static OSStatus with_store(BOOL write, OSStatus (^body)(NSMutableArray<NSMutableDictionary *> *items, BOOL *save)) {
  __block OSStatus st = errSecSuccess;
  pthread_mutex_lock(&gLock);
  BOOL ok = srkc_transact(gPath, write, ^BOOL(NSMutableArray<NSMutableDictionary *> *items) {
    BOOL save = NO;
    st = body(items, &save);
    return save;
  });
  pthread_mutex_unlock(&gLock);
  if (!ok) { fprintf(stderr, "[keychain] %s can't be %s\n", gPath.UTF8String, write ? "updated" : "read"); return errSecIO; }
  return st;
}

static NSMutableDictionary *new_item(NSString *cls, NSDictionary *attrs, NSData *value) {
  NSMutableDictionary *a = [attrs mutableCopy];
  if (!a[@"agrp"]) a[@"agrp"] = gGroups[0];
  if (!a[@"pdmn"]) a[@"pdmn"] = (id)kSecAttrAccessibleWhenUnlocked;
  a[@"sync"] = @(truthy(a[@"sync"]));
  a[@"cdat"] = a[@"mdat"] = [NSDate date];
  return [@{ @"class": cls, @"uuid": NSUUID.UUID.UUIDString, @"creator": gCreator, @"attributes": a, @"value": stored_value(cls, value) } mutableCopy];
}

// The items an add makes: one, or for an identity its certificate and private key.
static OSStatus items_to_add(NSDictionary *q, NSString *cls, NSMutableArray *out) {
  NSMutableDictionary *attrs = attributes_of(q);
  if ([attrs[@"sync"] isEqual:(id)kSecAttrSynchronizableAny]) return errSecParam;
  CFTypeRef ref = (__bridge CFTypeRef)q[(id)kSecValueRef];
  if (ref && ![ref_class(ref) isEqual:cls]) return errSecParam;
  if ([cls isEqual:kIdnt]) {
    if (!ref) return errSecParam;
    SecCertificateRef c = NULL; SecKeyRef k = NULL;
    SecIdentityCopyCertificate((SecIdentityRef)ref, &c); SecIdentityCopyPrivateKey((SecIdentityRef)ref, &k);
    OSStatus st = c && k ? errSecSuccess : errSecParam;
    if (!st) {
      NSMutableDictionary *ca = [cert_attributes(c) mutableCopy], *ka = [key_attributes(k) mutableCopy];
      [ca addEntriesFromDictionary:attrs]; [ka addEntriesFromDictionary:attrs];
      [out addObject:new_item(kCert, ca, ref_data(c))];
      [out addObject:new_item(kKeys, ka, ref_data(k))];
    }
    if (c) CFRelease(c);
    if (k) CFRelease(k);
    return st;
  }
  NSData *value = q[(id)kSecValueData];
  if (value && ![value isKindOfClass:NSData.class]) return errSecParam;
  if (ref) {
    NSMutableDictionary *own = [([cls isEqual:kKeys] ? key_attributes((SecKeyRef)ref) : cert_attributes((SecCertificateRef)ref)) mutableCopy];
    [own addEntriesFromDictionary:attrs];
    attrs = own;
    value = ref_data(ref);
    if (!value) return errSecParam;   // e.g. a non-extractable key
  } else if (!is_password_class(cls) && !value) return errSecParam;
  [out addObject:new_item(cls, attrs, value)];
  return errSecSuccess;
}

static OSStatus kc_add(NSDictionary *q, CFTypeRef *result) {
  NSString *cls = query_class(q);
  if (![@[ kGenp, kInet, kKeys, kCert, kIdnt ] containsObject:cls ?: @""]) return errSecParam;
  NSMutableArray<NSMutableDictionary *> *add = [NSMutableArray array];
  OSStatus st = items_to_add(q, cls, add);
  if (st) return st;
  st = with_store(YES, ^OSStatus(NSMutableArray<NSMutableDictionary *> *items, BOOL *save) {
    for (NSMutableDictionary *it in add)
      if (find_duplicate(items, it[@"class"], it[@"attributes"], nil)) {
        if ([cls isEqual:kIdnt] && [it[@"class"] isEqual:kKeys]) continue;   // the identity's key is there already: fine
        return errSecDuplicateItem;
      }
    for (NSMutableDictionary *it in add) if (!find_duplicate(items, it[@"class"], it[@"attributes"], nil)) [items addObject:it];
    *save = YES;
    return errSecSuccess;
  });
  LOG("add %s %s -> %d\n", cls.UTF8String, [[add.firstObject[@"attributes"] description] UTF8String], (int)st);
  want_t w = wanted(q);
  if (!st && result && wants_any(w)) {
    SRMatch *m = [SRMatch new]; m.item = add[0]; m.key = add.count > 1 ? add[1] : nil;
    id r = result_for(m, cls, w);
    *result = r ? CFBridgingRetain(r) : NULL;
  }
  return st;
}

static OSStatus kc_copy_matching(NSDictionary *q, CFTypeRef *result) {
  NSString *cls = query_class(q);
  if (!cls) return errSecParam;
  NSUInteger limit = match_limit(q);
  want_t w = wanted(q);
  __block NSArray<SRMatch *> *found;
  OSStatus st = with_store(NO, ^OSStatus(NSMutableArray<NSMutableDictionary *> *items, BOOL *save) {
    found = find(items, cls, q, limit);
    return found.count ? errSecSuccess : errSecItemNotFound;
  });
  LOG("copy %s %s -> %d (%lu found)\n", cls.UTF8String, [[attributes_of(q) description] UTF8String], (int)st, (unsigned long)found.count);
  if (st || !result) return st;
  *result = NULL;
  if (!wants_any(w)) return st;
  if (limit == 1) {
    id r = result_for(found[0], cls, w);
    *result = r ? CFBridgingRetain(r) : NULL;
  } else {
    NSMutableArray *all = [NSMutableArray array];
    for (SRMatch *m in found) { id r = result_for(m, cls, w); if (r) [all addObject:r]; }
    *result = CFBridgingRetain(all);
  }
  return st;
}

static OSStatus kc_update(NSDictionary *q, NSDictionary *changes) {
  NSString *cls = query_class(q);
  if (!cls || changes[(id)kSecClass]) return errSecParam;
  NSDictionary *set = attributes_of(changes);
  if ([set[@"sync"] isEqual:(id)kSecAttrSynchronizableAny]) return errSecParam;
  NSData *value = changes[(id)kSecValueData];
  if (value && ![value isKindOfClass:NSData.class]) return errSecParam;
  OSStatus st = with_store(YES, ^OSStatus(NSMutableArray<NSMutableDictionary *> *items, BOOL *save) {
    NSArray<SRMatch *> *found = find(items, cls, q, NSUIntegerMax);
    if (!found.count) return errSecItemNotFound;
    NSMutableSet *ids = [NSMutableSet set];
    for (SRMatch *m in found) [ids addObject:m.item[@"uuid"]];
    NSMutableArray *updated = [NSMutableArray array];
    for (SRMatch *m in found) {   // all or nothing: no update may collide with another item, or with each other
      NSMutableDictionary *a = [m.item[@"attributes"] mutableCopy];
      [a addEntriesFromDictionary:set];
      if (set[@"sync"]) a[@"sync"] = @(truthy(set[@"sync"]));
      a[@"mdat"] = [NSDate date];
      if (find_duplicate(items, m.item[@"class"], a, ids) || find_duplicate(updated, m.item[@"class"], a, nil)) return errSecDuplicateItem;
      [updated addObject:@{ @"class": m.item[@"class"], @"uuid": m.item[@"uuid"], @"attributes": a }];
    }
    [found enumerateObjectsUsingBlock:^(SRMatch *m, NSUInteger i, BOOL *stop) {
      m.item[@"attributes"] = updated[i][@"attributes"];
      if (value) m.item[@"value"] = stored_value(m.item[@"class"], value);
    }];
    *save = YES;
    return errSecSuccess;
  });
  LOG("update %s %s with %s -> %d\n", cls.UTF8String, [[attributes_of(q) description] UTF8String], [[set description] UTF8String], (int)st);
  return st;
}

static OSStatus kc_delete(NSDictionary *q) {
  NSString *cls = query_class(q);
  if (!cls) return errSecParam;
  OSStatus st = with_store(YES, ^OSStatus(NSMutableArray<NSMutableDictionary *> *items, BOOL *save) {
    NSArray<SRMatch *> *found = find(items, cls, q, NSUIntegerMax);
    if (!found.count) return errSecItemNotFound;
    for (SRMatch *m in found) { [items removeObjectIdenticalTo:m.item]; if (m.key) [items removeObjectIdenticalTo:m.key]; }
    *save = YES;
    return errSecSuccess;
  });
  LOG("delete %s %s -> %d\n", cls.UTF8String, [[attributes_of(q) description] UTF8String], (int)st);
  return st;
}

// ---------------------------------------------------------------- interposers
static OSStatus my_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
  if (gDisabled) return SecItemAdd(attributes, result);
  if (result) *result = NULL;
  if (!attributes) return errSecParam;
  @autoreleasepool { return kc_add((__bridge NSDictionary *)attributes, result); }
}
static OSStatus my_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
  if (gDisabled) return SecItemCopyMatching(query, result);
  if (result) *result = NULL;
  if (!query) return errSecParam;
  @autoreleasepool { return kc_copy_matching((__bridge NSDictionary *)query, result); }
}
static OSStatus my_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
  if (gDisabled) return SecItemUpdate(query, attributesToUpdate);
  if (!query || !attributesToUpdate) return errSecParam;
  @autoreleasepool { return kc_update((__bridge NSDictionary *)query, (__bridge NSDictionary *)attributesToUpdate); }
}
static OSStatus my_SecItemDelete(CFDictionaryRef query) {
  if (gDisabled) return SecItemDelete(query);
  if (!query) return errSecParam;
  @autoreleasepool { return kc_delete((__bridge NSDictionary *)query); }
}

// Key generation that asks for kSecAttrIsPermanent (at the top, or in kSecPrivateKeyAttrs / kSecPublicKeyAttrs):
// generate an ephemeral key, then add the requested halves ourselves with the attributes meant for them.
static NSDictionary *without_permanence(NSDictionary *d) {
  NSMutableDictionary *m = [d mutableCopy];
  [m removeObjectForKey:(id)kSecAttrIsPermanent];
  for (id sub in @[ (id)kSecPrivateKeyAttrs, (id)kSecPublicKeyAttrs ])
    if ([m[sub] isKindOfClass:NSDictionary.class]) { NSMutableDictionary *s = [m[sub] mutableCopy]; [s removeObjectForKey:(id)kSecAttrIsPermanent]; m[sub] = s; }
  return m;
}
static OSStatus add_generated_key(SecKeyRef key, NSDictionary *params, id half) {
  NSMutableDictionary *q = [params mutableCopy];
  if ([params[half] isKindOfClass:NSDictionary.class]) [q addEntriesFromDictionary:params[half]];
  [q removeObjectsForKeys:@[ (id)kSecAttrKeySizeInBits, (id)kSecAttrEffectiveKeySize ]];   // the key's own attributes say
  q[(id)kSecClass] = (id)kSecClassKey;
  q[(id)kSecValueRef] = (__bridge id)key;
  return kc_add(q, NULL);
}
static SecKeyRef my_SecKeyCreateRandomKey(CFDictionaryRef parameters, CFErrorRef *error) {
  if (gDisabled || !parameters) return SecKeyCreateRandomKey(parameters, error);
  @autoreleasepool {
    NSDictionary *p = (__bridge NSDictionary *)parameters;
    id top = p[(id)kSecAttrIsPermanent];
    id privPerm = [p[(id)kSecPrivateKeyAttrs] isKindOfClass:NSDictionary.class] ? p[(id)kSecPrivateKeyAttrs][(id)kSecAttrIsPermanent] : nil;
    id pubPerm = [p[(id)kSecPublicKeyAttrs] isKindOfClass:NSDictionary.class] ? p[(id)kSecPublicKeyAttrs][(id)kSecAttrIsPermanent] : nil;
    BOOL storePriv = truthy(privPerm ?: top), storePub = truthy(pubPerm ?: top);
    if (!storePriv && !storePub) return SecKeyCreateRandomKey(parameters, error);
    SecKeyRef key = SecKeyCreateRandomKey((__bridge CFDictionaryRef)without_permanence(p), error);
    if (!key) return NULL;
    OSStatus st = storePriv ? add_generated_key(key, p, (id)kSecPrivateKeyAttrs) : errSecSuccess;
    if (!st && storePub) {
      SecKeyRef pub = SecKeyCopyPublicKey(key);
      st = pub ? add_generated_key(pub, p, (id)kSecPublicKeyAttrs) : errSecParam;
      if (pub) CFRelease(pub);
    }
    LOG("generated permanent key (private %d, public %d) -> %d\n", storePriv, storePub, (int)st);
    if (st) {
      CFRelease(key);
      if (error) *error = CFErrorCreate(NULL, kCFErrorDomainOSStatus, st, NULL);
      return NULL;
    }
    return key;
  }
}
static OSStatus my_SecKeyGeneratePair(CFDictionaryRef parameters, SecKeyRef *publicKey, SecKeyRef *privateKey) {
  if (gDisabled) return SecKeyGeneratePair(parameters, publicKey, privateKey);
  CFErrorRef e = NULL;
  SecKeyRef priv = my_SecKeyCreateRandomKey(parameters, &e);
  if (!priv) {
    OSStatus st = e ? (OSStatus)CFErrorGetCode(e) : errSecParam;
    if (e) CFRelease(e);
    return st;
  }
  if (publicKey) *publicKey = SecKeyCopyPublicKey(priv);
  if (privateKey) *privateKey = priv; else CFRelease(priv);
  return errSecSuccess;
}

__attribute__((used, section("__DATA,__interpose"))) static struct { const void *n, *o; } interposers[] = {
  { (const void *)my_SecItemAdd, (const void *)SecItemAdd },
  { (const void *)my_SecItemCopyMatching, (const void *)SecItemCopyMatching },
  { (const void *)my_SecItemUpdate, (const void *)SecItemUpdate },
  { (const void *)my_SecItemDelete, (const void *)SecItemDelete },
  { (const void *)my_SecKeyCreateRandomKey, (const void *)SecKeyCreateRandomKey },
  { (const void *)my_SecKeyGeneratePair, (const void *)SecKeyGeneratePair },
};

__attribute__((constructor)) static void keychain_init(void) {
  gVerbose = getenv("KEYCHAIN_VERBOSE") != NULL;
  gDisabled = getenv("KEYCHAIN_DISABLE") != NULL || SRProcessRole() != SRRoleApp;
  if (gDisabled) return;
  // the device's shared data directory, not the app's container (HOME): one keychain for all apps
  const char *data = getenv("SIMULATOR_SHARED_RESOURCES_DIRECTORY") ?: getenv("HOME");
  if (!data) { gDisabled = 1; fprintf(stderr, "[keychain] no data directory: SecItem calls go to securityd\n"); return; }
  gPath = [@(data) stringByAppendingPathComponent:@SRKC_FILE];
  setup_groups();
  LOG("store %s, access groups %s\n", gPath.UTF8String, [[gGroups componentsJoinedByString:@", "] UTF8String]);
}
