// locale — app.dylib module: the Mac's language & region in the app (SIM platform).
// The device's language & region settings (AppleLocale, AppleLanguages, AppleFirstWeekday, 24-hour time, ...) live
// in the global preferences domain, .GlobalPreferences.plist in the app's container; Simulator.app's devices get theirs
// copied from the Mac. SimRun passes the Mac's in SIMRUN_HOST_INTL (JSON, null = not set on the Mac) and each app
// writes the ones that differ through cfprefsd here, before anything reads them. (Writing the plist from the host
// wouldn't do: the shared cfprefsd caches the domain and never sees later edits.) The time zone needs nothing: sim
// libc/CF/ICU read the Mac's /etc/localtime, as in Simulator.app.
// Env: LOCALE_VERBOSE=1, LOCALE_DISABLE=1 (keep what the device has, e.g. to test another locale).
#import <Foundation/Foundation.h>
#import "app.h"

static int gVerbose;
#define LOG(...) \
  do { \
    if (gVerbose) { \
      fprintf(stderr, "[locale] " __VA_ARGS__); \
    } \
  } while (0)

void SRLocaleStart(void) {
  gVerbose = getenv("LOCALE_VERBOSE") != NULL;
  const char *json = getenv("SIMRUN_HOST_INTL");
  if (!json) {
    return;
  }
  NSDictionary *host = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytesNoCopy:(void *)json length:strlen(json) freeWhenDone:NO]
                                                       options:0 error:NULL];
  if (![host isKindOfClass:NSDictionary.class]) {
    return;
  }
  NSDictionary *cur = CFBridgingRelease(CFPreferencesCopyMultiple((__bridge CFArrayRef)host.allKeys, kCFPreferencesAnyApplication,
                                                                  kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
  NSMutableDictionary *set = [NSMutableDictionary dictionary];
  NSMutableArray *remove = [NSMutableArray array];
  [host enumerateKeysAndObjectsUsingBlock:^(NSString *k, id v, BOOL *stop) {
    if (v == NSNull.null) {
      if (cur[k]) {
        [remove addObject:k];
      }
    }
    else if (![cur[k] isEqual:v]) {
      set[k] = v;
    }
  }];
  if (!set.count && !remove.count) {
    return;
  }
  CFPreferencesSetMultiple((__bridge CFDictionaryRef)set, (__bridge CFArrayRef)remove, kCFPreferencesAnyApplication,
                           kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
  CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
  LOG("global preferences from the Mac: set %s, removed %s\n", [set.allKeys componentsJoinedByString:@","].UTF8String,
      [remove componentsJoinedByString:@","].UTF8String);
}
