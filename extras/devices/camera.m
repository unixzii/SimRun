#import <Foundation/Foundation.h>
#import "CAMouflage.h"

// Virtual sources and app-side authorization live only for the injected process.
// This never grants macOS camera or screen-recording permission.
@interface SRSimRunCamera : NSObject
+ (BOOL)configureFile:(NSString *)path;
@end
@implementation SRSimRunCamera
+ (BOOL)configureFile:(NSString *)path {
  NSData *data = [NSData dataWithContentsOfFile:path];
  NSDictionary *config = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
  if (![config isKindOfClass:NSDictionary.class]) return NO;
  id devices = config[@"devices"];
  if (devices && (![devices isKindOfClass:NSArray.class] || ![devices count])) return NO;
  if (!CAMouflageSetAuthorizationConfiguration(data)) return NO;
  // A permission-only update does not open/take over the provider connection.
  return devices ? CAMouflageSetMockConfiguration(data) : YES;
}
@end

__attribute__((constructor)) static void installCameraFixture(void) {
  @autoreleasepool {
    const char *path = getenv("SIMRUN_CAMERA_FILE");
    if (path && *path && !getenv("SIMRUN_ROLE")) {
      BOOL queued = [SRSimRunCamera configureFile:@(path)];
      fprintf(stderr, "[simrun-camera] fixture %s: %s (provider acknowledges asynchronously)\n", path, queued ? "queued" : "failed");
    }
  }
}
