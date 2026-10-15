// flagprobe.m — toggles every BOOL property of CALayer and prints the render layer's bytes +36..+56 (the 128-bit flag
// field and its neighbours), read back with -[CALayer _copyRenderLayer:layerFlags:commitFlags:]. Build it for both
// platforms, run each, and compare with flagdiff.py to rebuild remap_layer_flags() in xlate.c.
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
@interface CAContext : NSObject
+ (instancetype)localContextWithOptions:(NSDictionary *)o;
@end
static void *gCtx;
static void dump(const char *name, CALayer *l) {
  [CATransaction flush];
  void *(*copy)(id, SEL, void *, unsigned, unsigned *) = (void *)objc_msgSend;
  unsigned cf = 0;
  unsigned char *r = copy(l, NSSelectorFromString(@"_copyRenderLayer:layerFlags:commitFlags:"), gCtx, 0xffffffff, &cf);
  printf("%s\t", name);
  for (int i = 36; i < 56; i++) printf("%02x", r[i]);
  printf("\n");
}
int main() {
  @autoreleasepool {
    CAContext *c = [CAContext localContextWithOptions:@{}];
    Ivar iv = class_getInstanceVariable(object_getClass(c), "_impl");
    gCtx = *(void **)((char *)(__bridge void *)c + ivar_getOffset(iv));
    dump("default", [CALayer layer]);
    unsigned n = 0;
    objc_property_t *props = class_copyPropertyList(CALayer.class, &n);
    for (unsigned i = 0; i < n; i++) {
      const char *attr = property_getAttributes(props[i]);
      if (attr[1] != 'B' && attr[1] != 'c') continue;
      if (strstr(attr, ",R")) continue;
      NSString *key = @(property_getName(props[i]));
      CALayer *l = [CALayer layer];
      @try {
        BOOL v = [[l valueForKey:key] boolValue];
        [l setValue:@(!v) forKey:key];
        char nm[256]; snprintf(nm, sizeof nm, "%s=%d", key.UTF8String, !v);
        dump(nm, l);
      } @catch (id e) {}
    }
  }
}
