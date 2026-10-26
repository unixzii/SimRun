// Optional compatibility adapter for VAP's untyped pixel-buffer dictionaries.
// Preserves attribute keys and values, but gives every dictionary CFType ownership.
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include <dlfcn.h>
#include <string.h>

static CFDictionaryRef copyTypedDictionary(CFDictionaryRef source) {
  if (!source) return NULL;
  CFIndex count = CFDictionaryGetCount(source);
  const void **keys = calloc(MAX(count, 1), sizeof(void *));
  const void **values = calloc(MAX(count, 1), sizeof(void *));
  CFDictionaryGetKeysAndValues(source, keys, values);
  CFMutableDictionaryRef result = CFDictionaryCreateMutable(kCFAllocatorDefault, count,
    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  for (CFIndex i=0; i<count; i++) {
    CFTypeRef value = values[i];
    if (CFGetTypeID(value) == CFDictionaryGetTypeID()) {
      CFDictionaryRef nested = copyTypedDictionary(value);
      CFDictionarySetValue(result, keys[i], nested); CFRelease(nested);
    } else {
      CFDictionarySetValue(result, keys[i], value);
    }
  }
  free(keys); free(values);
  return result;
}

static OSStatus typedVTCreate(CFAllocatorRef allocator, CMVideoFormatDescriptionRef format,
  CFDictionaryRef decoderSpecification, CFDictionaryRef destinationAttributes,
  const VTDecompressionOutputCallbackRecord *callback, VTDecompressionSessionRef *session) {
  Dl_info caller = {0}; dladdr(__builtin_return_address(0), &caller);
  const char *all = getenv("SIMRUN_VAP_ATTRIBUTES_ALL");
  BOOL scoped = caller.dli_sname && strstr(caller.dli_sname,"QGMP4FrameHWDecoder");
  if (!destinationAttributes || (!scoped && !(all && strcmp(all,"1")==0))) {
    return VTDecompressionSessionCreate(allocator,format,decoderSpecification,destinationAttributes,callback,session);
  }
  CFDictionaryRef typed = copyTypedDictionary(destinationAttributes);
  OSStatus status = VTDecompressionSessionCreate(allocator,format,decoderSpecification,typed,callback,session);
  CFRelease(typed);
  fprintf(stderr,"[vap-attributes] normalized scoped=%d status=%d\n",scoped,(int)status);
  return status;
}
__attribute__((used, section("__DATA,__interpose"))) static struct { const void *replacement, *original; } interposers[] = {
  { (const void *)typedVTCreate, (const void *)VTDecompressionSessionCreate }
};
