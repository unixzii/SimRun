// library.m — see library.h.
#import "library.h"
#import "session/environment.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <mach-o/loader.h>
#include <mach-o/fat.h>
#include <pwd.h>
#include <dlfcn.h>

// IconServices (private): the icon pipeline SpringBoard itself renders home-screen icons with (macOS ships the same
// framework). It reads the bundle's icon (asset catalog incl. Icon Composer layer stacks, or CFBundleIconFiles PNGs) and
// applies the iOS recipe: continuous-corner mask, Liquid Glass edge lighting, dark appearance.
@interface ISImageDescriptor : NSObject
- (instancetype)initWithSize:(CGSize)size scale:(double)scale;
@property unsigned long long platformStyle;   // 1 = iOS (full-bleed squircle); 0 = this platform (macOS, inset art)
@property long long appearance;               // 0 light, 1 dark
@end
@interface ISBundleIcon : NSObject
- (instancetype)initWithBundleURL:(NSURL *)url;
- (id)makeResourceProvider;                   // an ISResourceProvider; -placeholder: the bundle has no icon of its own
- (id)prepareImageForDescriptor:(ISImageDescriptor *)descriptor;   // renders synchronously (and caches)
- (CGImageRef)CGImageForDescriptor:(ISImageDescriptor *)descriptor; // cached image, or a "loading" placeholder
@end
@interface NSObject (ISResourceProvider)
- (BOOL)placeholder;
@end

NSNotificationName const SRLibraryDidChangeNotification = @"SRLibraryDidChange";
static NSString *const kLibraryKey = @"SRLibraryPaths";

// Platform (LC_BUILD_VERSION) of the arm64 slice of a Mach-O, or 0; its minimum OS version (xxxx.yy.zz nibbles) in
// *minos if given.
static uint32_t Arm64Platform(NSString *path, uint32_t *minos) {
  if (minos) *minos = 0;
  NSData *d = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
  if (d.length < sizeof(struct mach_header_64)) return 0;
  const uint8_t *p = d.bytes; size_t off = 0;
  uint32_t magic = *(const uint32_t *)p;
  if (magic == FAT_CIGAM || magic == FAT_MAGIC) {   // fat: find the arm64 slice
    const struct fat_header *fh = (const void *)p;
    uint32_t n = OSSwapBigToHostInt32(fh->nfat_arch);
    const struct fat_arch *fa = (const void *)(fh + 1);
    off = SIZE_MAX;
    for (uint32_t i = 0; i < n && (const uint8_t *)(fa + i + 1) <= p + d.length; i++)
      if ((cpu_type_t)OSSwapBigToHostInt32(fa[i].cputype) == CPU_TYPE_ARM64) off = OSSwapBigToHostInt32(fa[i].offset);
    if (off == SIZE_MAX || off + sizeof(struct mach_header_64) > d.length) return 0;
  }
  const struct mach_header_64 *mh = (const void *)(p + off);
  if (mh->magic != MH_MAGIC_64 || mh->cputype != CPU_TYPE_ARM64) return 0;
  const uint8_t *lc = (const uint8_t *)(mh + 1), *end = p + d.length;
  for (uint32_t i = 0; i < mh->ncmds && lc + sizeof(struct load_command) <= end; i++) {
    const struct load_command *c = (const void *)lc;
    if (c->cmd == LC_BUILD_VERSION) {
      if (minos) *minos = ((const struct build_version_command *)c)->minos;
      return ((const struct build_version_command *)c)->platform;
    }
    if (c->cmd == LC_VERSION_MIN_IPHONEOS) {   // old binaries; sim vs device unknown
      if (minos) *minos = ((const struct version_min_command *)c)->version;
      return PLATFORM_IOSSIMULATOR;
    }
    lc += c->cmdsize;
  }
  return 0;
}

@implementation SRAppInfo

+ (NSString *)problemWithAppAtPath:(NSString *)path {
  if (![path.pathExtension isEqualToString:@"app"]) return @"Not an app bundle.";
  NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
  if (!info) return @"This doesn't look like an iOS app: it has no top-level Info.plist (macOS apps keep it in Contents/).";
  NSString *exe = info[@"CFBundleExecutable"];
  if (!exe.length) return @"Info.plist has no CFBundleExecutable.";
  switch (Arm64Platform([path stringByAppendingPathComponent:exe], NULL)) {
    case PLATFORM_IOSSIMULATOR: return nil;
    case PLATFORM_IOS: return @"This is a build for iPhone/iPad devices. Build it for an iOS Simulator destination instead.";
    case 0: return @"The executable has no arm64 slice (SimRun needs an arm64 iOS Simulator build).";
    default: return @"The executable isn't built for the iOS Simulator.";
  }
}

+ (BOOL)isDeviceBuildAtPath:(NSString *)path {
  NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
  NSString *exe = info[@"CFBundleExecutable"];
  if (!exe.length) return NO;
  return Arm64Platform([path stringByAppendingPathComponent:exe], NULL) == PLATFORM_IOS;
}

+ (NSString *)minimumOSVersionOfExecutable:(NSString *)path {
  uint32_t v;
  if (!Arm64Platform(path, &v) || !v) return nil;
  return (v & 0xff) ? [NSString stringWithFormat:@"%u.%u.%u", v >> 16, (v >> 8) & 0xff, v & 0xff]
                    : [NSString stringWithFormat:@"%u.%u", v >> 16, (v >> 8) & 0xff];
}

+ (instancetype)infoWithPath:(NSString *)path {
  SRAppInfo *a = [SRAppInfo new];
  NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
  a->_path = path;
  a->_name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: path.lastPathComponent.stringByDeletingPathExtension;
  a->_bundleIdentifier = info[@"CFBundleIdentifier"] ?: @"";
  a->_executablePath = [path stringByAppendingPathComponent:info[@"CFBundleExecutable"] ?: @""];
  a->_icon = [self iconForBundle:path];
  return a;
}

// The app icon as SpringBoard draws it, rendered by IconServices with the iOS recipe. An app without an icon gets iOS's
// placeholder (GenericAppIcon_iOS), not macOS's generic app icon. The image renders lazily, per appearance and pixel size.
+ (NSImage *)iconForBundle:(NSString *)path {
  static dispatch_once_t once; dispatch_once(&once, ^{ dlopen("/System/Library/PrivateFrameworks/IconServices.framework/IconServices", RTLD_LAZY); });
  Class C = NSClassFromString(@"ISBundleIcon");
  if (!C || !NSClassFromString(@"ISImageDescriptor")) return [NSWorkspace.sharedWorkspace iconForContentType:UTTypeApplicationBundle];
  ISBundleIcon *icon = [[C alloc] initWithBundleURL:[NSURL fileURLWithPath:path]];
  NSURL *generic;
  if ([icon.makeResourceProvider placeholder] && (generic = [self genericIconBundle])) icon = [[C alloc] initWithBundleURL:generic];
  NSMutableDictionary<NSString *, id> *cache = [NSMutableDictionary dictionary];   // "appearance/pixels" -> CGImage
  return [NSImage imageWithSize:NSMakeSize(64, 64) flipped:NO drawingHandler:^BOOL(NSRect r) {
    BOOL dark = [[NSAppearance.currentDrawingAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]]
                 isEqualToString:NSAppearanceNameDarkAqua];
    CGFloat scale = MAX(1, CGContextConvertSizeToDeviceSpace(NSGraphicsContext.currentContext.CGContext, CGSizeMake(1, 1)).width);
    NSString *key = [NSString stringWithFormat:@"%d/%.0f", dark, r.size.width * scale];
    id img = cache[key];
    if (!img) {
      ISImageDescriptor *d = [[NSClassFromString(@"ISImageDescriptor") alloc] initWithSize:r.size scale:scale];
      d.platformStyle = 1; d.appearance = dark;
      [icon prepareImageForDescriptor:d];
      img = (__bridge id)[icon CGImageForDescriptor:d];
      if (!img) return NO;
      cache[key] = img;
    }
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, NSRectToCGRect(r), (__bridge CGImageRef)img);
    return YES;
  }];
}

// A stand-in app bundle whose icon is iOS's placeholder: the runtime's IconsetResources catalog has GenericAppIcon_iOS
// (light/dark/tinted), and IconServices renders it like any app icon. Only .app bundles get the app treatment (dark
// variant), and UIDeviceFamily makes it an iOS app. Nil without an iOS runtime.
+ (NSURL *)genericIconBundle {
  static NSURL *url; static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSString *car = [SREnvironment.runtimeRoot stringByAppendingPathComponent:@"System/Library/CoreServices/IconsetResources.bundle/Assets.car"];
    if (!car || ![NSFileManager.defaultManager fileExistsAtPath:car]) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [caches stringByAppendingFormat:@"/%@/GenericAppIcon.app", NSBundle.mainBundle.bundleIdentifier ?: @"dev.simrun.SimRun"];
    NSString *link = [dir stringByAppendingPathComponent:@"Assets.car"];
    if (![[fm destinationOfSymbolicLinkAtPath:link error:nil] isEqualToString:car]) {
      [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
      [fm removeItemAtPath:link error:nil];
      if (![fm createSymbolicLinkAtPath:link withDestinationPath:car error:nil]) return;
    }
    NSDictionary *info = @{ @"CFBundleIcons": @{ @"CFBundlePrimaryIcon": @{ @"CFBundleIconName": @"GenericAppIcon_iOS" } }, @"UIDeviceFamily": @[ @1 ] };
    if (![info writeToFile:[dir stringByAppendingPathComponent:@"Info.plist"] atomically:YES]) return;
    url = [NSURL fileURLWithPath:dir isDirectory:YES];
  });
  return url;
}
@end

@implementation SRLibrary { NSMutableArray<SRAppInfo *> *_apps; }

+ (instancetype)shared { static SRLibrary *s; static dispatch_once_t once; dispatch_once(&once, ^{ s = [SRLibrary new]; }); return s; }

- (instancetype)init {
  if ((self = [super init])) {
    _apps = [NSMutableArray array];
    for (NSString *p in [NSUserDefaults.standardUserDefaults stringArrayForKey:kLibraryKey])
      if ([NSFileManager.defaultManager fileExistsAtPath:p]) [_apps addObject:[SRAppInfo infoWithPath:p]];
  }
  return self;
}
- (NSArray<SRAppInfo *> *)apps { return _apps; }
- (void)save {
  [NSUserDefaults.standardUserDefaults setObject:[_apps valueForKey:@"path"] forKey:kLibraryKey];
  [NSNotificationCenter.defaultCenter postNotificationName:SRLibraryDidChangeNotification object:self];
}
- (SRAppInfo *)addPath:(NSString *)path {
  path = path.stringByStandardizingPath;
  for (SRAppInfo *a in _apps) if ([a.path isEqualToString:path]) return a;
  SRAppInfo *a = [SRAppInfo infoWithPath:path];
  [_apps addObject:a];
  [_apps sortUsingComparator:^NSComparisonResult(SRAppInfo *x, SRAppInfo *y) { return [x.name localizedCaseInsensitiveCompare:y.name]; }];
  [self save];
  return a;
}
- (void)removePath:(NSString *)path {
  NSIndexSet *ix = [_apps indexesOfObjectsPassingTest:^BOOL(SRAppInfo *a, NSUInteger i, BOOL *stop) { return [a.path isEqualToString:path]; }];
  [_apps removeObjectsAtIndexes:ix];
  [self save];
}

+ (NSArray<NSString *> *)xcodeSimulatorBuilds {
  struct passwd *pw = getpwuid(getuid());
  NSString *dd = [@(pw ? pw->pw_dir : "~") stringByAppendingPathComponent:@"Library/Developer/Xcode/DerivedData"];
  NSFileManager *fm = NSFileManager.defaultManager;
  NSMutableArray *out = [NSMutableArray array];
  for (NSString *proj in [fm contentsOfDirectoryAtPath:dd error:nil]) {
    NSString *products = [dd stringByAppendingFormat:@"/%@/Build/Products", proj];
    for (NSString *cfg in [fm contentsOfDirectoryAtPath:products error:nil]) {
      if (![cfg hasSuffix:@"-iphonesimulator"]) continue;
      NSString *dir = [products stringByAppendingPathComponent:cfg];
      for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:nil]) {
        NSString *p = [dir stringByAppendingPathComponent:f];
        if ([f.pathExtension isEqualToString:@"app"] && ![SRAppInfo problemWithAppAtPath:p]) [out addObject:p];
      }
    }
  }
  return out;
}
@end
