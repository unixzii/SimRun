// containermanagerd.dylib — loaded into containermanagerd, the container manager, on SimRun's iPhone and Apple Watch
// (simns inserts it: SIMNS_DAEMON_INSERT).
//
// SimRun keeps each app's data container in containermanagerd's folder for them (<data>/Containers/Data/Application/
// <bundle ID>, environment.m), none of them made by containermanagerd, which deletes such a directory (moves it to
// Library/Caches/com.apple.containermanagerd/Dead/, then removes it) in two places:
//   * when it starts (-[MCMClientConnection rebootContainerManagerSetup]), -_cleanupOrphanedDataForDirectories:
//     containerClass:forUserIdentity: deletes every directory in a container class's folder that it has no record of;
//   * when it scans a class's folder (-[MCMContainerClassCache _queue_syncWithDisk]), a container directory without its
//     metadata (.com.apple.mobile_container_manager.metadata.plist) is corrupt: -_handleUnrecoverableCorruptContainerPath:
//     deletes it.
// Every app's data was deleted whenever containermanagerd started, which an app group, an NSFileCoordinator
// (filecoordinationd) or WatchConnectivity's wcd brings about. Both are skipped.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#define LOG(fmt, ...) fprintf(stderr, "[containermanagerd.dylib] " fmt "\n", ##__VA_ARGS__)

// Replaces `sel` of `cls` with `block` (which takes self first); NO if there is no such method.
static BOOL Swizzle(const char *cls, const char *sel, id block) {
  Method m = class_getInstanceMethod(objc_getClass(cls), sel_registerName(sel));
  if (!m) {
    LOG("no -[%s %s]: SimRun's app containers may be deleted", cls, sel);
    return NO;
  }
  method_setImplementation(m, imp_implementationWithBlock(block));
  return YES;
}

__attribute__((constructor)) static void Init(void) {
  Swizzle("MCMClientConnection", "_cleanupOrphanedDataForDirectories:containerClass:forUserIdentity:",
    ^id(id connection, id directories, unsigned long long containerClass, id user) {
      LOG("not cleaning up orphaned data (container class %llu): SimRun's app containers are there", containerClass);
      return nil;
    });
  Swizzle("MCMContainerClassCache", "_handleUnrecoverableCorruptContainerPath:", ^id(id cache, id path) {
    LOG("not deleting %s, which has no container metadata: a SimRun app container", [[path description] UTF8String]);
    return nil;
  });
}
