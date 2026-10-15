// dsc.c <cache> <out dir>: extracts every dylib of a dyld shared cache with Xcode's dsc_extractor.bundle (the sim
// runtime's System/Library/Caches/com.apple.dyld/dyld_sim_shared_cache_arm64, and macOS's
// /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e), for loading QuartzCore in IDA.
#include <stdio.h>
#include <dlfcn.h>
int main(int c, char **v) {
  void *h = dlopen("/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/usr/lib/dsc_extractor.bundle", RTLD_LAZY);
  int (*f)(const char*, const char*, void (^)(unsigned, unsigned)) = dlsym(h, "dyld_shared_cache_extract_dylibs_progress");
  if (!f) { puts(dlerror()); return 1; }
  return f(v[1], v[2], ^(unsigned a, unsigned b){ if (a % 200 == 0) fprintf(stderr, "%u/%u\n", a, b); });
}
