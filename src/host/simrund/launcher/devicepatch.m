// devicepatch.m — see devicepatch.h.
#import "devicepatch.h"
#import "library.h"
#include "simrund_proto.h"
#include <fcntl.h>
#include <sys/file.h>
#include <CommonCrypto/CommonDigest.h>

static void LOG(NSString *fmt, ...) {
  va_list ap; va_start(ap, fmt); NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap]; va_end(ap);
  fprintf(stderr, "[simrund] %s\n", s.UTF8String);
}

// Stable cache key for an app path. A collision only makes two apps share a cache slot.
static NSString *PatchCacheKey(NSString *path) {
  uint64_t h = 14695981039346656037ull;
  for (const unsigned char *p = (const unsigned char *)path.UTF8String; *p; p++) { h ^= *p; h *= 1099511628211ull; }
  return [NSString stringWithFormat:@"%016llx", (unsigned long long)h];
}

// Where the patched copy goes. A DerivedData product stays next to the build (`<dir>/iossim-work/<App>.app`);
// anything else is cached under ~/Library/Developer/SimRun/patched.
static NSString *PatchDirectory(NSString *app) {
  NSString *parent = app.stringByDeletingLastPathComponent;
  if ([app rangeOfString:@"/DerivedData/"].location != NSNotFound) {
    if ([parent.lastPathComponent isEqualToString:@"iossim-work"]) return parent;
    return [parent stringByAppendingPathComponent:@"iossim-work"];
  }
  return [[@(simrund_home()) stringByAppendingPathComponent:@"Library/Developer/SimRun/patched"]
          stringByAppendingPathComponent:PatchCacheKey(app)];
}

// The copy shipped in SimRun.app. $SIMRUN_PATCH_SCRIPT replaces it.
static NSString *PatchScript(NSString **error) {
  const char *e = getenv("SIMRUN_PATCH_SCRIPT");
  if (e && *e) {
    if (access(e, R_OK) == 0) return @(e);
    if (error) *error = [NSString stringWithFormat:@"SIMRUN_PATCH_SCRIPT isn't readable: %s", e];
    return nil;
  }
  NSBundle *bundle = NSBundle.mainBundle;
  NSString *path = [bundle.resourcePath stringByAppendingPathComponent:@"patch_uikit_iossim.sh"];
  if (path.length && access(path.fileSystemRepresentation, R_OK) == 0) return path;
  path = [bundle.executablePath.stringByDeletingLastPathComponent
          stringByAppendingPathComponent:@"../SimRun.app/Contents/Resources/patch_uikit_iossim.sh"].stringByStandardizingPath;
  if (access(path.fileSystemRepresentation, R_OK) == 0) return path;
  if (error) *error = @"This is a build for iPhone/iPad devices, and SimRun's patch script is missing.";
  return nil;
}

static NSString *MD5File(NSString *path) {
  int fd = open(path.fileSystemRepresentation, O_RDONLY);
  if (fd < 0) return nil;
  CC_MD5_CTX ctx; CC_MD5_Init(&ctx);
  unsigned char buf[1 << 16];
  ssize_t n;
  while ((n = read(fd, buf, sizeof buf)) > 0) CC_MD5_Update(&ctx, buf, (CC_LONG)n);
  close(fd);
  if (n < 0) return nil;
  unsigned char dig[CC_MD5_DIGEST_LENGTH];
  CC_MD5_Final(dig, &ctx);
  char hex[CC_MD5_DIGEST_LENGTH * 2 + 1];
  for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) sprintf(hex + i * 2, "%02x", dig[i]);
  return @(hex);
}

// vtool and codesign are host tools. Drop the sim environment this process may have inherited.
static NSDictionary *HostToolEnvironment(void) {
  NSMutableDictionary *env = [NSMutableDictionary dictionary];
  [NSProcessInfo.processInfo.environment enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
    if ([k hasPrefix:@"DYLD_"] || [k hasPrefix:@"SIMULATOR_"] || [k hasPrefix:@"IPHONE_"]) return;
    if ([k isEqualToString:@"CFFIXED_USER_HOME"] || [k isEqualToString:@"TMPDIR"]) return;
    env[k] = v;
  }];
  env[@"HOME"] = @(simrund_home());
  return env;
}

static NSString *TailString(NSString *s) {
  if (s.length > 2000) s = [s substringFromIndex:s.length - 2000];
  s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  return s.length ? s : @"patch script failed";
}

static void CloseLock(int lk) { if (lk >= 0) { flock(lk, LOCK_UN); close(lk); } }

// Pulls complete lines out of `pending` (a chunk just appended, or the remainder at EOF) and passes each to `logLine`.
// `logLine` returning NO stops the caller.
static BOOL EmitLines(NSMutableData *pending, BOOL eof, BOOL (^logLine)(NSString *line)) {
  NSData *nl = [NSData dataWithBytes:"\n" length:1];
  NSRange hit;
  while (pending.length && (hit = [pending rangeOfData:nl options:0 range:NSMakeRange(0, pending.length)]).location != NSNotFound) {
    NSUInteger n = hit.location;
    NSData *row = [pending subdataWithRange:NSMakeRange(0, n)];
    [pending replaceBytesInRange:NSMakeRange(0, n + 1) withBytes:NULL length:0];
    if (n && ((const char *)row.bytes)[n - 1] == '\r') row = [row subdataWithRange:NSMakeRange(0, n - 1)];
    NSString *s = [[NSString alloc] initWithData:row encoding:NSUTF8StringEncoding];
    if (!s.length) continue;
    if (logLine && !logLine(s)) return NO;
  }
  if (eof && pending.length) {
    NSString *s = [[NSString alloc] initWithData:pending encoding:NSUTF8StringEncoding];
    [pending setLength:0];
    if (s.length && logLine && !logLine(s)) return NO;
  }
  return YES;
}

NSString *SRPatchedDeviceApp(NSString *app, NSString *sdk, BOOL (^logLine)(NSString *line), NSString **error) {
  NSString *why = nil;
  NSString *script = PatchScript(&why);
  if (!script) { if (error) *error = why; return nil; }
  NSString *exe = [SRAppInfo infoWithPath:app].executablePath;
  NSString *minOS = [SRAppInfo minimumOSVersionOfExecutable:exe] ?: sdk;
  NSString *exeMD5 = MD5File(exe), *scriptMD5 = MD5File(script);
  if (!exeMD5) { if (error) *error = [NSString stringWithFormat:@"cannot read %@", exe]; return nil; }
  NSString *stamp = [NSString stringWithFormat:@"%@\n%@\n%@\n%@\n", app, exeMD5, scriptMD5 ?: @"", sdk ?: @""];
  NSFileManager *fm = NSFileManager.defaultManager;
  NSString *dir = PatchDirectory(app);
  NSString *out = [dir stringByAppendingPathComponent:app.lastPathComponent];
  NSString *stampPath = [dir stringByAppendingPathComponent:[app.lastPathComponent stringByAppendingString:@".stamp"]];
  if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil]) {
    if (error) *error = [NSString stringWithFormat:@"cannot create %@", dir];
    return nil;
  }
  int lk = open([dir stringByAppendingPathComponent:[app.lastPathComponent stringByAppendingString:@".lock"]].fileSystemRepresentation, O_CREAT | O_RDWR | O_CLOEXEC, 0600);
  if (lk >= 0) flock(lk, LOCK_EX);
  if ([[NSString stringWithContentsOfFile:stampPath encoding:NSUTF8StringEncoding error:nil] isEqualToString:stamp] &&
      ![SRAppInfo problemWithAppAtPath:out]) {
    LOG(@"using patched %@", out);
    if (logLine && !logLine([NSString stringWithFormat:@"using patched %@", out.lastPathComponent])) { CloseLock(lk); return nil; }
    CloseLock(lk);
    return out;
  }
  NSMutableString *transcript = [NSMutableString string];
  BOOL (^emit)(NSString *) = ^BOOL(NSString *line) {
    @synchronized (transcript) { [transcript appendString:line]; [transcript appendString:@"\n"]; }
    LOG(@"%@", line);
    return !logLine || logLine(line);
  };
  if (!emit([NSString stringWithFormat:@"patching %@ for the iOS Simulator (iOS %@)", app.lastPathComponent, sdk])) {
    CloseLock(lk); return nil;
  }
  NSPipe *pipe = [NSPipe pipe];
  NSMutableData *pending = [NSMutableData data];
  dispatch_semaphore_t eof = dispatch_semaphore_create(0);
  __block BOOL cancelled = NO;
  __block NSTask *task = [NSTask new];
  pipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *h) {
    NSData *chunk = h.availableData;
    BOOL end = !chunk.length;
    if (chunk.length) [pending appendData:chunk];
    if (!EmitLines(pending, end, emit)) {
      cancelled = YES; [task terminate]; h.readabilityHandler = nil; dispatch_semaphore_signal(eof); return;
    }
    if (end) { h.readabilityHandler = nil; dispatch_semaphore_signal(eof); }
  };
  task.executableURL = [NSURL fileURLWithPath:@"/bin/bash"];
  task.arguments = @[ script, @"--no-install", @"--no-launch", @"--skip-verify", @"--min-os", minOS, @"--sdk", sdk, @"--output", out, app ];
  NSMutableDictionary *env = [HostToolEnvironment() mutableCopy];
  env[@"NSUnbufferedIO"] = @"YES";   // bash printf is fully buffered on a pipe otherwise
  task.environment = env;
  task.standardOutput = pipe.fileHandleForWriting; task.standardError = pipe.fileHandleForWriting;
  NSError *launchErr = nil;
  if (![task launchAndReturnError:&launchErr]) {
    pipe.fileHandleForReading.readabilityHandler = nil;
    CloseLock(lk);
    if (error) *error = [NSString stringWithFormat:@"Couldn't patch %@ for the simulator: %@", app.lastPathComponent, launchErr.localizedDescription ?: @"cannot run the patch script"];
    return nil;
  }
  [pipe.fileHandleForWriting closeFile];   // the child holds the write end; closing ours is what delivers EOF
  [task waitUntilExit];
  dispatch_semaphore_wait(eof, DISPATCH_TIME_FOREVER);
  if (cancelled) { CloseLock(lk); [fm removeItemAtPath:out error:nil]; return nil; }
  if (task.terminationStatus != 0) {
    CloseLock(lk);
    [fm removeItemAtPath:out error:nil];
    if (error) *error = [NSString stringWithFormat:@"Couldn't patch %@ for the simulator: %@", app.lastPathComponent, TailString(transcript)];
    return nil;
  }
  why = [SRAppInfo problemWithAppAtPath:out];
  if (why) {
    CloseLock(lk);
    [fm removeItemAtPath:out error:nil];
    if (error) *error = [NSString stringWithFormat:@"Couldn't patch %@ for the simulator: %@", app.lastPathComponent, why];
    return nil;
  }
  [stamp writeToFile:stampPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
  LOG(@"patched %@", out);
  CloseLock(lk);
  return out;
}
