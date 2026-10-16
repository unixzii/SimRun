// objcbridge.m — sending Objective-C messages from JS (the `objc` global, js/app.js).
//
// Objects travel as JavaScriptCore's wrappers: an object returned by one call can be the target or an argument of the
// next. Arguments and return values are converted by the method's type encoding: objects (NSString/NSNumber/
// NSArray/NSDictionary become JS values), classes, selectors (as strings), booleans, numbers, and CGPoint, CGSize and
// CGRect ({x, y}, {width, height}, {x, y, width, height}).
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include "script.h"

static const char *SRSkipQualifiers(const char *t) { while (*t && strchr("rnNoORV", *t)) t++; return t; }

static BOOL SRSetArg(NSInvocation *inv, NSUInteger i, JSValue *v) {
  const char *t = SRSkipQualifiers([inv.methodSignature getArgumentTypeAtIndex:i]);
  switch (*t) {
    case '@': case '#': { __unsafe_unretained id o = v.isNull || v.isUndefined ? nil : [v toObject]; [inv setArgument:&o atIndex:i]; return YES; }
    case ':': { SEL s = NSSelectorFromString([v toString]); [inv setArgument:&s atIndex:i]; return YES; }
    case 'B': { bool b = [v toBool]; [inv setArgument:&b atIndex:i]; return YES; }
    case 'c': case 'C': { char c = (char)[v toInt32]; [inv setArgument:&c atIndex:i]; return YES; }
    case 's': case 'S': { short s = (short)[v toInt32]; [inv setArgument:&s atIndex:i]; return YES; }
    case 'i': case 'I': { int n = [v toInt32]; [inv setArgument:&n atIndex:i]; return YES; }
    case 'l': case 'L': case 'q': case 'Q': { long long n = (long long)[v toDouble]; [inv setArgument:&n atIndex:i]; return YES; }
    case 'f': { float f = (float)[v toDouble]; [inv setArgument:&f atIndex:i]; return YES; }
    case 'd': { double d = [v toDouble]; [inv setArgument:&d atIndex:i]; return YES; }
    case '{':
      if (!strncmp(t, "{CGPoint=", 9)) { CGPoint p = [v toPoint]; [inv setArgument:&p atIndex:i]; return YES; }
      if (!strncmp(t, "{CGSize=", 8)) { CGSize s = [v toSize]; [inv setArgument:&s atIndex:i]; return YES; }
      if (!strncmp(t, "{CGRect=", 8)) { CGRect r = [v toRect]; [inv setArgument:&r atIndex:i]; return YES; }
  }
  return NO;
}

static JSValue *SRReturnValue(NSInvocation *inv, JSContext *c) {
  Class V = SRJSValueClass();
  const char *t = SRSkipQualifiers(inv.methodSignature.methodReturnType);
  #define RET(type) ({ type x; [inv getReturnValue:&x]; x; })
  switch (*t) {
    case 'v': return [V valueWithUndefinedInContext:c];
    case '@': case '#': { __unsafe_unretained id o = nil; [inv getReturnValue:&o]; return o ? [V valueWithObject:o inContext:c] : [V valueWithNullInContext:c]; }
    case ':': return [V valueWithObject:NSStringFromSelector(RET(SEL)) inContext:c];
    case 'B': return [V valueWithBool:RET(bool) inContext:c];
    case 'c': return [V valueWithBool:RET(char) != 0 inContext:c];
    case 'C': return [V valueWithUInt32:RET(unsigned char) inContext:c];
    case 's': return [V valueWithInt32:RET(short) inContext:c];
    case 'S': return [V valueWithUInt32:RET(unsigned short) inContext:c];
    case 'i': return [V valueWithInt32:RET(int) inContext:c];
    case 'I': return [V valueWithUInt32:RET(unsigned) inContext:c];
    case 'l': case 'q': return [V valueWithDouble:(double)RET(long long) inContext:c];
    case 'L': case 'Q': return [V valueWithDouble:(double)RET(unsigned long long) inContext:c];
    case 'f': return [V valueWithDouble:RET(float) inContext:c];
    case 'd': return [V valueWithDouble:RET(double) inContext:c];
    case '{':
      if (!strncmp(t, "{CGPoint=", 9)) return [V valueWithPoint:RET(CGPoint) inContext:c];
      if (!strncmp(t, "{CGSize=", 8)) return [V valueWithSize:RET(CGSize) inContext:c];
      if (!strncmp(t, "{CGRect=", 8)) return [V valueWithRect:RET(CGRect) inContext:c];
  }
  #undef RET
  return SRThrow([NSString stringWithFormat:@"objc.send: unsupported return type %s", t]);
}

// send(target, "selector:with:", ...args): target is an object from an earlier call, or a class name.
static JSValue *SRSend(void) {
  NSArray<JSValue *> *a = SRCurrentArguments();
  if (a.count < 2) return SRThrow(@"objc.send(target, selector, ...args)");
  id target = a[0].isString ? NSClassFromString([a[0] toString]) : [a[0] toObject];
  if (!target) return SRThrow([NSString stringWithFormat:@"objc.send: no class or object %@", [a[0] toString]]);
  SEL sel = NSSelectorFromString([a[1] toString]);
  NSMethodSignature *sig = [target methodSignatureForSelector:sel];
  if (!sig) return SRThrow([NSString stringWithFormat:@"objc.send: %@ doesn't respond to %@", [target class], [a[1] toString]]);
  if (a.count - 2 != sig.numberOfArguments - 2)
    return SRThrow([NSString stringWithFormat:@"objc.send: %@ takes %lu arguments", [a[1] toString], (unsigned long)sig.numberOfArguments - 2]);
  NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
  inv.target = target; inv.selector = sel;
  for (NSUInteger i = 2; i < sig.numberOfArguments; i++)
    if (!SRSetArg(inv, i, a[i])) return SRThrow([NSString stringWithFormat:@"objc.send: unsupported argument type %s", [sig getArgumentTypeAtIndex:i]]);
  // A native exception must cross this explicit bridge as a JS error, so the
  // caller can catch it without terminating the app (e.g. an undefined KVC key).
  @try { [inv invoke]; }
  @catch (NSException *exception) {
    return SRThrow([NSString stringWithFormat:@"objc.send: %@ raised %@: %@",
                    NSStringFromSelector(sel), exception.name, exception.reason ?: @""]);
  }
  return SRReturnValue(inv, SRCurrentContext());
}

void SRInstallObjCBindings(JSValue *native) {
  Class V = SRJSValueClass();
  JSValue *o = [V valueWithNewObjectInContext:native.context];
  o[@"send"] = ^JSValue *(void) { return SRSend(); };
  o[@"cls"] = ^JSValue *(NSString *name) {
    Class k = NSClassFromString(name);
    return k ? [V valueWithObject:k inContext:SRCurrentContext()] : [V valueWithNullInContext:SRCurrentContext()];
  };
  // describe(object): its -description; null for JS values (objects and arrays convert to NSDictionary and NSArray)
  o[@"describe"] = ^NSString *(JSValue *v) {
    id obj = [v toObject];
    return !obj || [obj isKindOfClass:NSDictionary.class] || [obj isKindOfClass:NSArray.class] ? nil : [obj description];
  };
  // methods(className, filter): "+sel" / "-sel" of the class itself (not its superclasses) containing filter.
  o[@"methods"] = ^NSArray *(NSString *name, JSValue *filter) {
    Class k = NSClassFromString(name);
    NSString *f = filter.isString ? [filter toString] : nil;
    NSMutableArray *r = [NSMutableArray array];
    for (int meta = 1; k && meta >= 0; meta--) {
      unsigned n = 0;
      Method *ms = class_copyMethodList(meta ? object_getClass(k) : k, &n);
      for (unsigned i = 0; i < n; i++) {
        NSString *s = NSStringFromSelector(method_getName(ms[i]));
        if (!f || [s rangeOfString:f options:NSCaseInsensitiveSearch].location != NSNotFound) [r addObject:[(meta ? @"+" : @"-") stringByAppendingString:s]];
      }
      free(ms);
    }
    return r;
  };
  // classes(filter): names of loaded classes containing filter.
  o[@"classes"] = ^NSArray *(NSString *f) {
    unsigned n = 0;
    Class *cs = objc_copyClassList(&n);
    NSMutableArray *r = [NSMutableArray array];
    for (unsigned i = 0; i < n; i++) {
      NSString *s = NSStringFromClass(cs[i]);
      if (!f.length || [s rangeOfString:f options:NSCaseInsensitiveSearch].location != NSNotFound) [r addObject:s];
    }
    free(cs);
    return [r sortedArrayUsingSelector:@selector(compare:)];
  };
  native[@"objc"] = o;
}
