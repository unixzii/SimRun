// camera.m — camera.dylib's entry point (SRCameraInstall, called by app.dylib's camera module), the runtime helpers
// its files patch AVFoundation with, and the app's camera permission. See capture.h.
#import "capture.h"
#include <os/lock.h>

const SRCameraAPI *gCamera;

// ---------------------------------------------------------------- the runtime

static void copy_methods(Class from, Class to) {
  unsigned count = 0;
  Method *methods = class_copyMethodList(from, &count);
  for (unsigned i = 0; i < count; i++) {
    class_replaceMethod(to, method_getName(methods[i]), method_getImplementation(methods[i]),
                        method_getTypeEncoding(methods[i]));
  }
  free(methods);
}

void SRCapturePatchOnto(Class patch, Class target) {
  copy_methods(patch, target);
  copy_methods(object_getClass(patch), object_getClass(target));
}

void SRCapturePatch(Class patch) {
  if (!patch) {
    fprintf(stderr, "[camera] missing patch class\n");
    return;
  }
  SRCapturePatchOnto(patch, class_getSuperclass(patch));
}

id SRCaptureAlloc(Class cls, Class base, Class replacement) {
  return class_createInstance(cls == base ? replacement : cls, 0);
}

void SRCaptureSwizzle(Class cls, SEL sel, SEL replacement) {
  Method orig = class_getInstanceMethod(cls, sel);
  Method repl = class_getInstanceMethod(cls, replacement);
  if (!orig || !repl) {
    CAM_LOG("can't swizzle -[%s %s]\n", class_getName(cls), sel_getName(sel));
    return;
  }
  // a method cls only inherits becomes its own first, so that the exchange leaves its superclass alone
  class_addMethod(cls, sel, method_getImplementation(orig), method_getTypeEncoding(orig));
  method_exchangeImplementations(class_getInstanceMethod(cls, sel), repl);
}

void SRCaptureAdoptRootDealloc(Class cls) {
  SEL dealloc = sel_registerName("dealloc");
  class_addMethod(cls, dealloc, class_getMethodImplementation(NSObject.class, dealloc), "v@:");
}

static long stub_no(id self, SEL _cmd) {
  return 0;
}

static double stub_zero_fp(id self, SEL _cmd) {
  return 0;
}

static long stub_yes(id self, SEL _cmd) {
  return 1;
}

static id stub_empty(id self, SEL _cmd) {
  return @[];
}

static void stub_ignore(id self, SEL _cmd) {
}

void SRCaptureStub(Class cls, SRStubKind kind, const char *const *selectors) {
  static const char *const kFallbackTypes[] = {[SRStubNo] = "B@:", [SRStubYes] = "B@:", [SRStubEmpty] = "@@:", [SRStubIgnore] = "v@:@"};
  for (; *selectors; selectors++) {
    SEL sel = sel_registerName(*selectors);
    Method m = class_getInstanceMethod(cls, sel);
    const char *types = m ? method_getTypeEncoding(m) : kFallbackTypes[kind];
    IMP imp = (IMP)stub_ignore;
    if (kind == SRStubNo) {
      imp = (types[0] == 'f' || types[0] == 'd') ? (IMP)stub_zero_fp : (IMP)stub_no;
    } else if (kind == SRStubYes) {
      imp = (IMP)stub_yes;
    } else if (kind == SRStubEmpty) {
      imp = (IMP)stub_empty;
    }
    class_replaceMethod(cls, sel, imp, types);
  }
}

id SRCaptureState(id obj, Class type) {
  static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
  const void *key = (__bridge const void *)type;
  id st = objc_getAssociatedObject(obj, key);
  if (!st && obj) {
    os_unfair_lock_lock(&lock);
    st = objc_getAssociatedObject(obj, key);
    if (!st) {
      st = [type new];
      objc_setAssociatedObject(obj, key, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    os_unfair_lock_unlock(&lock);
  }
  return st;
}

// ---------------------------------------------------------------- the app's permission

SRTCCRight SRCameraRight(void) {
  return gCamera->right("kTCCServiceCamera");
}

void SRCameraRequestAccess(void (^done)(BOOL granted)) {
  SRTCCRight cur = SRCameraRight();
  if (cur != SRTCCUndetermined) {
    done(cur == SRTCCAllowed);
    return;
  }
  gCamera->request("kTCCServiceCamera", NO, ^(SRTCCRight right) {
    done(right == SRTCCAllowed);
  });
}

void SRCameraEnsurePrompted(void) {
  if (SRCameraRight() == SRTCCUndetermined) {
    CAM_LOG("app opened camera while authorization is undetermined; requesting permission\n");
    SRCameraRequestAccess(^(BOOL granted){
    });
  }
}

// ---------------------------------------------------------------- the entry point

__attribute__((visibility("default"))) void SRCameraInstall(const SRCameraAPI *api) {
  gCamera = api;
  SRDevicesInstall();
  SRSessionInstall();
  SROutputsInstall();
  if (api->isApp) {
    SRImagePickerInstall();
  }
  CAM_LOG("AVFoundation capture patched\n");
}
