// keychain.h — SimRun's fake keychain store, shared by the keychain module (every app's SecItem* calls) and SimRun.app (the
// Keychain window). Objective-C (Foundation) code only. See docs/keychain.md.
//
// One XML property list in the simulated device's shared data directory (not an app's container), SRKC_FILE: no
// encryption, readable and editable by hand. Every access holds flock(2) on "<file>.lock" (shared to read, exclusive to write); writes replace the file
// atomically. The file is the only state: apps don't cache it, so changes made by SimRun (or an editor) apply at once.
//
//   { version: 1,
//     items: [ { class:      "genp" | "inet" | "keys" | "cert"    (kSecClass value; identities are a cert + its key)
//                uuid:       string                               (our id; persistent refs carry it)
//                creator:    string                               (bundle id of the app that added it; SimRun only)
//                attributes: { acct, svce, agrp, pdmn, sync, cdat, mdat, labl, ... }   (kSecAttr* keys, plist values)
//                value:      string | data }, ... ] }             (kSecValueData; a password is a string when it is
//                                                                   UTF-8, key/cert data is the external representation)
#pragma once
#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#define SRKC_FILE "Library/Keychains/simrun-keychain.plist"   // relative to the shared data directory
                                                              // (SIMULATOR_SHARED_RESOURCES_DIRECTORY of the apps)

// Loads the items, runs `body` on them (mutable) and, if `write` and body returns YES, saves them. The whole call
// holds the store's lock. Returns NO if the file exists but can't be read (it is then left alone) or can't be saved.
static inline BOOL srkc_transact(NSString *path, BOOL write, BOOL (^body)(NSMutableArray<NSMutableDictionary *> *items)) {
  [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
  int lock = open([path stringByAppendingString:@".lock"].fileSystemRepresentation, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
  if (lock < 0) return NO;
  flock(lock, write ? LOCK_EX : LOCK_SH);
  BOOL ok = YES;
  NSMutableArray *items = [NSMutableArray array];
  NSData *d = [NSData dataWithContentsOfFile:path];
  if (d.length) {
    NSDictionary *root = [NSPropertyListSerialization propertyListWithData:d options:NSPropertyListMutableContainers format:NULL error:NULL];
    id a = [root isKindOfClass:NSDictionary.class] ? root[@"items"] : nil;
    if ([a isKindOfClass:NSMutableArray.class]) {
      for (id it in a) if ([it isKindOfClass:NSMutableDictionary.class] && [it[@"class"] isKindOfClass:NSString.class]) [items addObject:it];
    } else ok = NO;   // damaged (hand-edited?): don't overwrite it
  }
  if (ok && body(items) && write) {
    NSData *out = [NSPropertyListSerialization dataWithPropertyList:@{ @"version": @1, @"items": items } format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    ok = out && [out writeToFile:path options:NSDataWritingAtomic error:NULL];
    if (ok) chmod(path.fileSystemRepresentation, 0600);   // plaintext secrets: owner only
  }
  flock(lock, LOCK_UN);
  close(lock);
  return ok;
}
