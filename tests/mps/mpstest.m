// mpstest — an MPSGraph FFT on the simulator's GPU (exercises the mps module; see docs/mps.md).
// Run with `simrun run build/tests/mpstest`: prints PASS, or the first wrong bin. Without the mps module (MPS_DISABLE=1)
// it aborts on iOS 26 and later runtimes, as in Simulator.app.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <MetalPerformanceShadersGraph/MetalPerformanceShadersGraph.h>

int main(void) {
  @autoreleasepool {
    enum { T = 8, N = 16, B = N / 2 + 1 };
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    MPSGraph *g = [MPSGraph new];
    MPSGraphTensor *in = [g placeholderWithShape:@[ @(T), @(N) ] dataType:MPSDataTypeFloat32 name:@"in"];
    MPSGraphFFTDescriptor *fd = [MPSGraphFFTDescriptor descriptor];
    fd.scalingMode = MPSGraphFFTScalingModeNone;
    MPSGraphTensor *spectrum = [g realToHermiteanFFTWithTensor:in axes:@[ @1 ] descriptor:fd name:nil];
    MPSGraphTensor *re = [g realPartOfTensor:spectrum name:nil], *im = [g imaginaryPartOfTensor:spectrum name:nil];

    // row t: cos(2π·2n/N) + t, so bin 0 = N·t, bin 2 = N/2, every other bin 0
    id<MTLBuffer> x = [device newBufferWithLength:T * N * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> xre = [device newBufferWithLength:T * B * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> xim = [device newBufferWithLength:T * B * 4 options:MTLResourceStorageModeShared];
    float *p = x.contents;
    for (int t = 0; t < T; t++)
      for (int n = 0; n < N; n++)
        p[t * N + n] = cosf(2 * M_PI * 2 * n / N) + t;

    MPSCommandBuffer *cb = [MPSCommandBuffer commandBufferFromCommandQueue:[device newCommandQueue]];
    [g encodeToCommandBuffer:cb
                       feeds:@{ in: [[MPSGraphTensorData alloc] initWithMTLBuffer:x shape:@[ @(T), @(N) ] dataType:MPSDataTypeFloat32] }
            targetOperations:nil
           resultsDictionary:@{ re: [[MPSGraphTensorData alloc] initWithMTLBuffer:xre shape:@[ @(T), @(B) ] dataType:MPSDataTypeFloat32],
                                im: [[MPSGraphTensorData alloc] initWithMTLBuffer:xim shape:@[ @(T), @(B) ] dataType:MPSDataTypeFloat32] }
         executionDescriptor:nil];
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) {
      printf("FAIL: command buffer status %ld %s\n", (long)cb.status, cb.error.description.UTF8String ?: "");
      return 1;
    }
    const float *r = xre.contents, *i = xim.contents;
    for (int t = 0; t < T; t++)
      for (int k = 0; k < B; k++) {
        float want = k == 0 ? N * t : k == 2 ? N / 2 : 0;
        if (fabsf(r[t * B + k] - want) > 1e-3f || fabsf(i[t * B + k]) > 1e-3f) {
          printf("FAIL: row %d bin %d = %g%+gi, want %g\n", t, k, r[t * B + k], i[t * B + k], want);
          return 1;
        }
      }
    printf("PASS: %d×%d real FFT on %s\n", T, N, device.name.UTF8String);
  }
  return 0;
}
