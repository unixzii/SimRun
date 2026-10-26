// devicebuild.m — see devicebuild.h. A device build and a simulator build run the same arm64 iOS code; they differ in
// what dyld and the kernel check. The copy (a clone, so only the files changed take space):
//   * arm64 iOS Mach-Os: fat files thinned to their arm64 slice; LC_BUILD_VERSION's platform made the simulator's (an
//     old LC_VERSION_MIN_IPHONEOS replaced by an LC_BUILD_VERSION), or dyld_sim refuses to load them; a __RESTRICT
//     segment renamed, or dyld would ignore DYLD_INSERT_LIBRARIES and SimRun's libraries with it
//   * Info.plists: the platform keys say iphonesimulator
//   * signatures: the device ones (and the provisioning profile) removed and everything signed again, ad hoc. An edited
//     Mach-O no longer matches its signature, and the kernel kills a process that maps it. The entitlements go too: an
//     ad-hoc signature can't carry restricted ones (the keychain module then uses the bundle ID as the access group)
//   * Watch/ (the watchOS companion app) is left out
// App Store builds are encrypted (FairPlay) and can't be converted.
#import "devicebuild.h"
#include <CommonCrypto/CommonDigest.h>
#include <copyfile.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <sys/stat.h>
#include <sys/xattr.h>

// Part of the stamp: a change here converts every app again.
static const int kConverterVersion = 1;

// ---------------------------------------------------------------- Mach-O
static BOOL IsMachO(NSString *path) {
  uint32_t magic = 0;
  FILE *f = fopen(path.fileSystemRepresentation, "rb");
  if (!f)
    return NO;
  size_t n = fread(&magic, sizeof magic, 1, f);
  fclose(f);
  return n == 1 && (magic == MH_MAGIC_64 || magic == MH_MAGIC || magic == FAT_CIGAM || magic == FAT_CIGAM_64);
}

// `d`'s arm64 slice if it is a fat file (nil if it has none), else `d`.
static NSData *Arm64Slice(NSData *d) {
  const uint8_t *p = d.bytes;
  uint32_t magic = *(const uint32_t *)p;
  if (magic != FAT_CIGAM && magic != FAT_CIGAM_64)
    return d;
  BOOL is64 = magic == FAT_CIGAM_64;
  uint32_t n = OSSwapBigToHostInt32(((const struct fat_header *)p)->nfat_arch);
  size_t entry = is64 ? sizeof(struct fat_arch_64) : sizeof(struct fat_arch);
  for (uint32_t i = 0; i < n; i++) {
    const uint8_t *a = p + sizeof(struct fat_header) + i * entry;
    if (a + entry > p + d.length)
      return nil;
    cpu_type_t cpu = (cpu_type_t)OSSwapBigToHostInt32(*(const uint32_t *)a);
    uint64_t off = is64 ? OSSwapBigToHostInt64(((const struct fat_arch_64 *)a)->offset) : OSSwapBigToHostInt32(((const struct fat_arch *)a)->offset);
    uint64_t size = is64 ? OSSwapBigToHostInt64(((const struct fat_arch_64 *)a)->size) : OSSwapBigToHostInt32(((const struct fat_arch *)a)->size);
    if (cpu == CPU_TYPE_ARM64 && off + size <= d.length)
      return [d subdataWithRange:NSMakeRange(off, size)];
  }
  return nil;
}

// Makes the Mach-O at `path` a simulator one, in place. Files that aren't arm64 iOS code stay as they are. NO and
// *error if it can't.
static BOOL ConvertMachO(NSString *path, NSString **error) {
  NSData *file = [NSData dataWithContentsOfFile:path];
  if (file.length < sizeof(struct mach_header_64))
    return YES;
  NSData *slice = Arm64Slice(file);
  if (slice.length < sizeof(struct mach_header_64))
    return YES;
  NSMutableData *d = [slice mutableCopy];
  BOOL changed = slice != file;
  struct mach_header_64 *mh = d.mutableBytes;
  if (mh->magic != MH_MAGIC_64 || mh->cputype != CPU_TYPE_ARM64 || sizeof *mh + mh->sizeofcmds > d.length)
    return YES;

  uint8_t *lcs = (uint8_t *)(mh + 1);
  uint64_t firstSection = d.length;   // the load commands may grow up to here (the header padding)
  struct version_min_command *versionMin = NULL;
  BOOL buildVersion = NO;
  for (uint32_t i = 0, at = 0; i < mh->ncmds; i++) {
    struct load_command *c = (void *)(lcs + at);
    if (at + sizeof *c > mh->sizeofcmds || c->cmdsize < sizeof *c || at + c->cmdsize > mh->sizeofcmds) {
      *error = [NSString stringWithFormat:@"%@ has malformed load commands", path.lastPathComponent];
      return NO;
    }
    if (c->cmd == LC_ENCRYPTION_INFO_64 && ((struct encryption_info_command_64 *)c)->cryptid) {
      *error = [NSString stringWithFormat:@"%@ is encrypted: this is an App Store build. SimRun can convert development, ad hoc and "
                                           "enterprise builds (and Xcode's builds for a device), not ones from the App Store.",
                                           path.lastPathComponent];
      return NO;
    }
    if (c->cmd == LC_BUILD_VERSION) {
      struct build_version_command *bv = (void *)c;
      if (bv->platform != PLATFORM_IOS)
        return YES;   // already a simulator's, or another platform's
      bv->platform = PLATFORM_IOSSIMULATOR;
      buildVersion = changed = YES;
    }
    if (c->cmd == LC_VERSION_MIN_IPHONEOS)
      versionMin = (void *)c;
    if (c->cmd == LC_SEGMENT_64) {
      struct segment_command_64 *seg = (void *)c;
      if (!strncmp(seg->segname, "__RESTRICT", sizeof seg->segname)) {
        memcpy(seg->segname, "__RSTRICT_", 10);
        changed = YES;
      }
      struct section_64 *s = (void *)(seg + 1);
      for (uint32_t k = 0; k < seg->nsects && (uint8_t *)(s + k + 1) <= (uint8_t *)c + c->cmdsize; k++) {
        if (s[k].offset)
          firstSection = MIN(firstSection, s[k].offset);
        if (!strncmp(s[k].segname, "__RESTRICT", sizeof s[k].segname))
          memcpy(s[k].segname, "__RSTRICT_", 10);
        if (!strncmp(s[k].sectname, "__restrict", sizeof s[k].sectname))
          memcpy(s[k].sectname, "__rstrict_", 10);
      }
    }
    at += c->cmdsize;
  }
  if (versionMin && !buildVersion) {
    // older linkers' platform command: replaced by a simulator LC_BUILD_VERSION, 8 bytes longer, in the header padding
    size_t at = (uint8_t *)versionMin - lcs;
    if (sizeof *mh + mh->sizeofcmds + 8 > firstSection) {
      *error = [NSString stringWithFormat:@"%@ has no room in its header to mark it as a simulator binary", path.lastPathComponent];
      return NO;
    }
    struct build_version_command bv = { LC_BUILD_VERSION, sizeof bv, PLATFORM_IOSSIMULATOR, versionMin->version, versionMin->sdk, 0 };
    memmove(lcs + at + sizeof bv, lcs + at + sizeof *versionMin, mh->sizeofcmds - at - sizeof *versionMin);
    memcpy(lcs + at, &bv, sizeof bv);
    mh->sizeofcmds += sizeof bv - sizeof *versionMin;
    changed = YES;
  } else if (!buildVersion) {
    return YES;   // no platform: not something dyld checks
  }
  if (!changed)
    return YES;

  struct stat st;
  mode_t mode = stat(path.fileSystemRepresentation, &st) == 0 ? st.st_mode & 07777 : 0755;
  if (![d writeToFile:path atomically:YES]) {
    *error = [NSString stringWithFormat:@"couldn't write %@", path];
    return NO;
  }
  chmod(path.fileSystemRepresentation, mode);
  return YES;
}

// ---------------------------------------------------------------- Info.plist
static void ConvertInfoPlist(NSString *path) {
  NSData *data = [NSData dataWithContentsOfFile:path];
  NSPropertyListFormat format;
  NSMutableDictionary *p = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers
                                                                              format:&format error:NULL] : nil;
  if (![p isKindOfClass:NSMutableDictionary.class])
    return;
  BOOL changed = NO;
  id platforms = p[@"CFBundleSupportedPlatforms"];
  if ([platforms isKindOfClass:NSArray.class] && [platforms containsObject:@"iPhoneOS"]) {
    p[@"CFBundleSupportedPlatforms"] = @[ @"iPhoneSimulator" ];
    changed = YES;
  }
  if ([p[@"DTPlatformName"] isEqual:@"iphoneos"]) {
    p[@"DTPlatformName"] = @"iphonesimulator";
    changed = YES;
  }
  NSString *sdk = p[@"DTSDKName"];
  if ([sdk isKindOfClass:NSString.class] && [sdk hasPrefix:@"iphoneos"]) {
    p[@"DTSDKName"] = [@"iphonesimulator" stringByAppendingString:[sdk substringFromIndex:8]];
    changed = YES;
  }
  if (changed)
    [[NSPropertyListSerialization dataWithPropertyList:p format:format options:0 error:NULL] writeToFile:path atomically:YES];
}

// ---------------------------------------------------------------- signing
// Signs `path` ad hoc; nil, or codesign's complaint.
static NSString *Sign(NSString *path) {
  NSTask *t = [NSTask new];
  t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/codesign"];
  t.arguments = @[ @"--force", @"--sign", @"-", @"--timestamp=none", path ];
  NSPipe *err = [NSPipe pipe];
  t.standardOutput = NSFileHandle.fileHandleWithNullDevice;
  t.standardError = err;
  NSError *e;
  if (![t launchAndReturnError:&e])
    return e.localizedDescription;
  NSData *msg = [err.fileHandleForReading readDataToEndOfFile];
  [t waitUntilExit];
  if (t.terminationStatus == 0)
    return nil;
  NSString *s = [[NSString alloc] initWithData:msg encoding:NSUTF8StringEncoding];
  return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"codesign failed";
}

// ---------------------------------------------------------------- the copy
// What the copy was made from: the bundle's Info.plist, executable and seal (Xcode signs the app again after every
// change), and the converter.
static NSString *Stamp(NSString *app) {
  NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[app stringByAppendingPathComponent:@"Info.plist"]];
  NSString *exe = [info[@"CFBundleExecutable"] isKindOfClass:NSString.class] ? info[@"CFBundleExecutable"] : @"";
  NSMutableString *s = [NSMutableString stringWithFormat:@"%d %@", kConverterVersion, app];
  for (NSString *rel in @[ @"Info.plist", exe, @"_CodeSignature/CodeResources" ]) {
    struct stat st;
    if (stat([app stringByAppendingPathComponent:rel].fileSystemRepresentation, &st) == 0)
      [s appendFormat:@"\n%@ %lld %ld.%09ld %llu", rel, (long long)st.st_size, st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec, st.st_ino];
  }
  return s;
}

// ~/Library/Caches/<SimRun>/DeviceBuilds/<name>-<hash of the path>: one directory per device build, holding the copy
// and the stamp it was made from.
static NSString *CacheDirectory(NSString *app) {
  unsigned char md[CC_SHA256_DIGEST_LENGTH];
  NSData *path = [app dataUsingEncoding:NSUTF8StringEncoding];
  CC_SHA256(path.bytes, (CC_LONG)path.length, md);
  NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
  return [caches stringByAppendingFormat:@"/%@/DeviceBuilds/%@-%02x%02x%02x%02x", NSBundle.mainBundle.bundleIdentifier ?: @"dev.simrun.SimRun",
                                         app.lastPathComponent.stringByDeletingPathExtension, md[0], md[1], md[2], md[3]];
}

@implementation SRDeviceBuild

+ (NSString *)currentCopyOfApp:(NSString *)appPath {
  appPath = appPath.stringByStandardizingPath;
  NSString *dir = CacheDirectory(appPath), *copy = [dir stringByAppendingPathComponent:appPath.lastPathComponent];
  NSString *stamp = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"stamp"] encoding:NSUTF8StringEncoding error:nil];
  return [stamp isEqualToString:Stamp(appPath)] && [NSFileManager.defaultManager fileExistsAtPath:copy] ? copy : nil;
}

+ (NSString *)simulatorCopyOfApp:(NSString *)appPath error:(NSString **)error {
  // one at a time: a second request for the same app finds the first one's copy
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("SimRun.devicebuild", DISPATCH_QUEUE_SERIAL);
  });
  __block NSString *copy, *err;
  appPath = appPath.stringByStandardizingPath;
  dispatch_sync(queue, ^{
    copy = [self convert:appPath error:&err];
    if (!copy)
      [NSFileManager.defaultManager removeItemAtPath:[CacheDirectory(appPath) stringByAppendingPathComponent:@"new"] error:nil];
  });
  if (!copy && error)
    *error = [NSString stringWithFormat:@"Couldn't convert this device build for the Simulator: %@", err];
  return copy;
}

+ (NSString *)convert:(NSString *)app error:(NSString **)error {
  NSString *current = [self currentCopyOfApp:app];
  if (current)
    return current;
  NSFileManager *fm = NSFileManager.defaultManager;
  NSString *dir = CacheDirectory(app), *copy = [dir stringByAppendingPathComponent:app.lastPathComponent];
  NSString *stampPath = [dir stringByAppendingPathComponent:@"stamp"], *stamp = Stamp(app);

  CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
  NSString *work = [dir stringByAppendingPathComponent:@"new"];   // what an interrupted conversion left goes
  [fm removeItemAtPath:work error:nil];
  if (![fm createDirectoryAtPath:work withIntermediateDirectories:YES attributes:nil error:nil]) {
    *error = [NSString stringWithFormat:@"can't create %@", work];
    return nil;
  }
  NSString *out = [work stringByAppendingPathComponent:app.lastPathComponent];
  if (copyfile(app.fileSystemRepresentation, out.fileSystemRepresentation, NULL, COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE) != 0) {
    *error = [NSString stringWithFormat:@"can't copy it to %@: %s", work, strerror(errno)];
    return nil;
  }
  [fm removeItemAtPath:[out stringByAppendingPathComponent:@"Watch"] error:nil];

  // one walk: drop the device signatures, convert Info.plists and Mach-Os, and note what to sign
  NSMutableArray<NSString *> *machOs = [NSMutableArray array], *bundles = [NSMutableArray arrayWithObject:out];
  NSDirectoryEnumerator *e = [fm enumeratorAtPath:out];
  for (NSString *rel in e) {
    NSString *path = [out stringByAppendingPathComponent:rel], *name = rel.lastPathComponent;
    removexattr(path.fileSystemRepresentation, "com.apple.quarantine", XATTR_NOFOLLOW);
    if ([e.fileAttributes.fileType isEqualToString:NSFileTypeDirectory]) {
      if ([name isEqualToString:@"_CodeSignature"]) {
        [e skipDescendants];
        [fm removeItemAtPath:path error:nil];
      }
      else if ([@[ @"app", @"appex", @"framework", @"xpc" ] containsObject:name.pathExtension])
        [bundles addObject:path];
      continue;
    }
    if (![e.fileAttributes.fileType isEqualToString:NSFileTypeRegular])
      continue;
    if ([name isEqualToString:@"embedded.mobileprovision"]) {
      [fm removeItemAtPath:path error:nil];
      continue;
    }
    if ([name isEqualToString:@"Info.plist"]) {
      ConvertInfoPlist(path);
      continue;
    }
    if (!IsMachO(path))
      continue;
    if (!ConvertMachO(path, error))
      return nil;
    [machOs addObject:path];
  }
  removexattr(out.fileSystemRepresentation, "com.apple.quarantine", XATTR_NOFOLLOW);

  // Sign the loose code first (bundles sign their own executable), then the bundles from the deepest up: a bundle's
  // seal covers what it contains. Bundles at one depth don't contain each other, so those sign in parallel.
  NSMutableSet<NSString *> *executables = [NSMutableSet set];
  for (NSString *b in bundles) {
    id exe = [NSDictionary dictionaryWithContentsOfFile:[b stringByAppendingPathComponent:@"Info.plist"]][@"CFBundleExecutable"];
    if ([exe isKindOfClass:NSString.class])
      [executables addObject:[b stringByAppendingPathComponent:exe]];
  }
  NSMutableArray<NSArray<NSString *> *> *levels = [NSMutableArray array];
  [levels addObject:[machOs filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *p, id b) {
    return ![executables containsObject:p];
  }]]];
  NSMutableDictionary<NSNumber *, NSMutableArray *> *byDepth = [NSMutableDictionary dictionary];
  for (NSString *b in bundles) {
    NSNumber *depth = @(b.pathComponents.count);
    if (!byDepth[depth])
      byDepth[depth] = [NSMutableArray array];
    [byDepth[depth] addObject:b];
  }
  for (NSNumber *depth in [byDepth.allKeys sortedArrayUsingSelector:@selector(compare:)].reverseObjectEnumerator)
    [levels addObject:byDepth[depth]];
  for (NSArray<NSString *> *level in levels) {
    NSMutableArray *failures = [NSMutableArray array];
    dispatch_apply(level.count, DISPATCH_APPLY_AUTO, ^(size_t i) {
      NSString *why = Sign(level[i]);
      if (why)
        @synchronized (failures) {
          [failures addObject:[NSString stringWithFormat:@"%@: %@", [level[i] substringFromIndex:work.length + 1], why]];
        }
    });
    if (failures.count) {
      *error = [@"codesign failed for " stringByAppendingString:[failures componentsJoinedByString:@"; "]];
      return nil;
    }
  }

  // swap it in. A running instance of the old copy keeps its files (they are only unlinked).
  NSString *old = [dir stringByAppendingPathComponent:@"old"];
  [fm removeItemAtPath:old error:nil];
  [fm removeItemAtPath:stampPath error:nil];
  if ([fm fileExistsAtPath:copy] && ![fm moveItemAtPath:copy toPath:old error:nil])
    [fm removeItemAtPath:copy error:nil];
  if (![fm moveItemAtPath:out toPath:copy error:nil]) {
    *error = [NSString stringWithFormat:@"can't move it to %@", copy];
    return nil;
  }
  [stamp writeToFile:stampPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
  [fm removeItemAtPath:old error:nil];
  [fm removeItemAtPath:work error:nil];
  fprintf(stderr, "[simrund] converted device build %s for the Simulator in %.2f s: %s\n", app.UTF8String,
          CFAbsoluteTimeGetCurrent() - start, copy.UTF8String);
  return copy;
}
@end
