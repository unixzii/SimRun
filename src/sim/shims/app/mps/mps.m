// mps — app.dylib module: MPSGraph on the simulator's Metal device (SIM platform; see docs/mps.md).
// MetalPerformanceShadersGraph in the iOS 26 and later simulator runtimes can't run a graph on MTLSimDevice, in
// Simulator.app as here: an app that runs MPSGraph graphs on the GPU aborts on its first one. Two bugs:
//   * -[MPSGraphDeviceDescriptor initWithMPSGraphDevice:] serializes the descriptor's architecture, which the sim build
//     never sets ("-[__NSArrayM insertObject:atIndex:]: object cannot be nil"); compilation then needs one too
//     ("applegpu_g" + its name minus the first letter). We describe the GPU as an h13g (M1 class: code for it runs on
//     every Apple silicon Mac, and it keeps MPSGraph off the M5's matrix units) without a Neural Engine.
//   * MPSGraph's memref bufferizer allocates intermediates from a shared-storage placement heap, and MTLSimDevice only
//     makes private heaps ("MTLStorageModePrivate is required for heaps"). The GPU alone touches those buffers: the
//     heaps MPS asks for, and what is placed in them, are made private.
// Nothing changes on runtimes without MPSGraphDeviceDescriptor (iOS 18).
// Env: MPS_VERBOSE=1, MPS_DISABLE=1.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <os/lock.h>
#import "app.h"

static int gVerbose;
#define LOG(fmt, ...) do { if (gVerbose) fprintf(stderr, "[mps] " fmt "\n", ##__VA_ARGS__); } while (0)

static NSString *const kArchitecture = @"h13g";

static void patch_heaps(void);

// ---------------------------------------------------------------- device descriptor
static IMP gDescriptorInit;
static id descriptor_init(id self, SEL _cmd, id graphDevice) {
  patch_heaps();   // the Metal device exists by now, so MTLSimDriver is loaded
  if (((uint32_t (*)(id, SEL))objc_msgSend)(graphDevice, @selector(type)) == 0)   // MPSGraphDeviceTypeMetal
    return ((id (*)(id, SEL, long long, NSString *))objc_msgSend)(self, @selector(initMetalDeviceWithGPUCoreCount:architecture:), -1, kArchitecture);
  return ((id (*)(id, SEL, id))gDescriptorInit)(self, _cmd, graphDevice);
}
static BOOL descriptor_has_ane(id self, SEL _cmd) {
  return NO;
}

static void patch_descriptor(Class c) {
  if (![c instancesRespondToSelector:@selector(initMetalDeviceWithGPUCoreCount:architecture:)]) {
    LOG("MPSGraphDeviceDescriptor has no -initMetalDeviceWithGPUCoreCount:architecture:, left alone");
    return;
  }
  gDescriptorInit = method_setImplementation(class_getInstanceMethod(c, @selector(initWithMPSGraphDevice:)), (IMP)descriptor_init);
  method_setImplementation(class_getInstanceMethod(c, @selector(hasANE)), (IMP)descriptor_has_ane);
  LOG("MPSGraph devices described as %s without a Neural Engine", kArchitecture.UTF8String);
}

// ---------------------------------------------------------------- heaps
static const void *kPrivateHeap = &kPrivateHeap;
static IMP gNewHeap, gHeapBuffer, gHeapBufferAt, gHeapTexture, gHeapTextureAt;

static BOOL called_from_mps(const void *ret) {
  Dl_info di;
  return dladdr(ret, &di) && di.dli_fname && strstr(di.dli_fname, "/MetalPerformanceShaders");
}
static BOOL made_private(id heap) {
  return objc_getAssociatedObject(heap, kPrivateHeap) != nil;
}
static MTLResourceOptions private_options(MTLResourceOptions o) {
  return (o & ~(MTLResourceOptions)(0xF << MTLResourceStorageModeShift)) | MTLResourceStorageModePrivate;
}
static MTLTextureDescriptor *private_texture(MTLTextureDescriptor *d) {
  if (d.storageMode == MTLStorageModePrivate)
    return d;
  d = [d copy];
  d.storageMode = MTLStorageModePrivate;
  return d;
}

static id heap_buffer(id self, SEL _cmd, NSUInteger length, MTLResourceOptions o) {
  if (made_private(self))
    o = private_options(o);
  return ((id (*)(id, SEL, NSUInteger, MTLResourceOptions))gHeapBuffer)(self, _cmd, length, o);
}
static id heap_buffer_at(id self, SEL _cmd, NSUInteger length, MTLResourceOptions o, NSUInteger offset) {
  if (made_private(self))
    o = private_options(o);
  return ((id (*)(id, SEL, NSUInteger, MTLResourceOptions, NSUInteger))gHeapBufferAt)(self, _cmd, length, o, offset);
}
static id heap_texture(id self, SEL _cmd, MTLTextureDescriptor *d) {
  if (made_private(self))
    d = private_texture(d);
  return ((id (*)(id, SEL, id))gHeapTexture)(self, _cmd, d);
}
static id heap_texture_at(id self, SEL _cmd, MTLTextureDescriptor *d, NSUInteger offset) {
  if (made_private(self))
    d = private_texture(d);
  return ((id (*)(id, SEL, id, NSUInteger))gHeapTextureAt)(self, _cmd, d, offset);
}
static IMP replace(Class c, SEL sel, IMP imp) {
  Method m = class_getInstanceMethod(c, sel);
  return m ? method_setImplementation(m, imp) : NULL;
}

__attribute__((noinline)) static id new_heap(id self, SEL _cmd, MTLHeapDescriptor *d) {
  BOOL fix = d.storageMode != MTLStorageModePrivate && called_from_mps(__builtin_return_address(0));
  if (fix) {
    d = [d copy];
    d.storageMode = MTLStorageModePrivate;
  }
  id heap = ((id (*)(id, SEL, id))gNewHeap)(self, _cmd, d);
  if (fix && heap) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      Class hc = object_getClass(heap);
      gHeapBuffer = replace(hc, @selector(newBufferWithLength:options:), (IMP)heap_buffer);
      gHeapBufferAt = replace(hc, @selector(newBufferWithLength:options:offset:), (IMP)heap_buffer_at);
      gHeapTexture = replace(hc, @selector(newTextureWithDescriptor:), (IMP)heap_texture);
      gHeapTextureAt = replace(hc, @selector(newTextureWithDescriptor:offset:), (IMP)heap_texture_at);
    });
    objc_setAssociatedObject(heap, kPrivateHeap, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LOG("private heap %p (%lu bytes) for MPS", heap, (unsigned long)d.size);
  }
  return heap;
}

static void patch_heaps(void) {
  static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
  static int done;
  os_unfair_lock_lock(&lock);
  Class c = done ? Nil : objc_getClass("MTLSimDevice");
  if (c) {
    done = 1;
    gNewHeap = replace(c, @selector(newHeapWithDescriptor:), (IMP)new_heap);
    LOG("MTLSimDevice heaps for MPS made private");
  }
  os_unfair_lock_unlock(&lock);
}

// ---------------------------------------------------------------- setup
// MetalPerformanceShadersGraph and MTLSimDriver are often loaded after us (CoreML loads MPSGraph lazily, Metal
// dlopens MTLSimDriver for the first device): patch when their classes show up. An add-image callback can come before
// the image's classes are registered, and nothing may be loaded after MTLSimDriver: the heaps are also patched when
// the first MPSGraph device is made, before any graph runs.
static void image_loaded(const struct mach_header *mh, intptr_t slide) {
  static int descriptorDone;
  if (!descriptorDone) {
    Class c = objc_getClass("MPSGraphDeviceDescriptor");
    if (c) {
      descriptorDone = 1;
      patch_descriptor(c);
    }
  }
  patch_heaps();
}

void SRMPSStart(void) {
  gVerbose = getenv("MPS_VERBOSE") != NULL;
  _dyld_register_func_for_add_image(image_loaded);
}
