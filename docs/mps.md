# MPSGraph — graphs on the simulator's GPU

**Status: working** on the iOS 26.5, 27.0 and 27.1 runtimes. Apps that run MetalPerformanceShadersGraph graphs on
the GPU work: FFTs, element-wise ops, and the MPSGraph stages of an audio-separation pipeline next to Core ML. Before
this, they aborted on the first graph. **This isn't a SimRun gap:** the same app aborts the same way in Simulator.app,
because MPSGraph in these simulator runtimes can't run on the simulator's Metal device (`MTLSimDevice`). On iOS 18.5,
MPSGraph works without any of this, and the mps module changes nothing there.

```bash
make test-programs && build/bin/simrun run build/tests/mpstest                       # PASS: 8×16 real FFT on Apple iOS simulator GPU
MPS_DISABLE=1 build/bin/simrun run build/tests/mpstest                               # aborts, as in Simulator.app
MPS_VERBOSE=1 build/bin/simrun run build/tests/mpstest                               # what was patched, every heap made private
```

## Core ML on the GPU: a separate problem, not fixed here

Core ML with `MLComputeUnitsCPUAndGPU` doesn't go through these code paths. It runs on the simulator GPU with or
without the mps module, and then it can be wrong. A Mel-Band RoFormer separation model (input 1×801×7916, STFT features up
to ±226) returns an all-zero mask on the GPU in the simulator, while CPU-only gives the real mask (max 1.2, 90%
non-zero). On the Mac, both work. Simulator.app gives the same zeros, with the same numbers, so SimRun reproduces it
faithfully. The same model with small inputs (±0.1) agrees with the CPU, which points at a precision overflow in the
simulator's GPU backend. Apps should use `MLComputeUnitsCPUOnly` when `TARGET_OS_SIMULATOR`. The simulator's CPU
path is slow too: 11 s for that prediction, against 0.8 s natively on the Mac.

Core ML's GPU outputs are padded, 7936 floats per row for a 7916-wide array. Read them by `strides`, not as one
dense buffer.

## Bug 1: the device descriptor has no architecture

`+[MPSGraphDevice deviceWithMTLDevice:]` (and so `-[MPSGraphTensorData initWithMTLBuffer:shape:dataType:]`, which
calls it) builds an `MPSGraphDeviceDescriptor`, which is MPSGraph's cache key for compiled graphs.
`-initWithMPSGraphDevice:` serializes it as `[type, gpuCoreCount, architecture]` for a Metal device. The simulator
build (`MetalPerformanceShadersGraph_Sim`) never sets `_architecture`, so it adds nil to the array:

```
*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil
  -[MPSGraphDeviceDescriptor initWithMPSGraphDevice:] + 184
  -[MPSGraphDevice initWithDeviceType:metalDevice:] + 212
  +[MPSGraphDevice deviceWithMTLDevice:] block + 308
```

(`MTLSimDevice.architecture` is nil too, and the descriptor wouldn't read it anyway.) Graph compilation needs a real
name as well. `-[MPSGraphExecutable applyOptimizationPasses…]` turns it into a GPU target with `@"applegpu_g" +
[architecture substringFromIndex:1]`, so an empty string throws `NSRangeException`. Two more methods read it:
`-hasANE` is `architecture != nil`, and `-supportsMXU` is true for `h17…` and later (not `h17p`): the M5's matrix
units.

The mps module replaces `-initWithMPSGraphDevice:`: for a Metal device it returns
`-initMetalDeviceWithGPUCoreCount:-1 architecture:@"h13g"`, which is MPSGraph's own initializer for the same three
properties. `-hasANE` returns NO. `h13g` (M1 class) is the most conservative choice. Code for it runs on every Apple
silicon Mac, since the simulator's Metal recompiles on the host anyway. It also keeps MPSGraph off the MXU code paths,
which the simulator's shader compiler isn't known to handle. A test FFT gives the same result as an `h17s` target.

## Bug 2: shared heaps

With a descriptor, the graph compiles and the first run fails in MPSGraph's memref bufferizer.
`GPU::MemrefBufferizer::createMemrefHeap` makes a placement heap for intermediates with `storageMode = Shared`
(`MTLHeapDescriptor`: shared, hazard tracking untracked, type placement), and `MTLSimDevice` only makes private
heaps:

```
-[MTLSimDevice newHeapWithDescriptor:]:1226: failed assertion `MTLStorageModePrivate is required for heaps'
```

`MPSGRAPH_ENABLE_MEMREF_BUFFERIZATION=0` and `MPSGRAPH_ENABLE_GPU_REGIONS=0` don't avoid it. Making only the heap
private isn't enough. MPSGraph places buffers in it with `options:0` (shared), and the host's Metal asserts on the
mismatch:

```
-[IOGPUMetalHeap newSubResourceAtOffset:withLength:alignment:options:]: failed assertion `The requested storage mode
(MTLStorageModeShared) is not compatible with the heap's mode (MTLStorageModePrivate)'
```

That assertion fires in SimRun's own process (MTLSimImplementation, see [render.md](render.md#42-metal-commetalsimulator)),
so it takes SimRun and every running app down with it.

The mps module replaces `-[MTLSimDevice newHeapWithDescriptor:]`. When the caller is in a MetalPerformanceShaders
framework (by the return address) and asks for a non-private heap, the heap is made private and marked. On marked
heaps, `MTLSimHeap`'s `newBufferWithLength:options:[offset:]` and `newTextureWithDescriptor:[offset:]` make what they
place private too. Only the GPU touches these intermediates, and the graph's inputs and outputs are the app's own
buffers, so nothing reads their contents on the CPU. Heaps other code asks for are left alone: an app that makes a
shared heap still gets the simulator's assertion, as in Simulator.app.

## Loading

MPSGraph is often loaded after the injected libraries; Core ML, for one, loads it lazily. The mps module patches from a
dyld add-image callback as soon as `MPSGraphDeviceDescriptor` and `MTLSimDevice` are registered. Metal dlopens
MTLSimDriver when the first device is made, and the callback for it can come before its classes are registered. In
Simulator.app nothing else was loaded after it, so the heaps went unpatched. The heaps are therefore also patched
when the first MPSGraph device is made, which comes after the Metal device and before any graph runs. On a runtime
whose `MPSGraphDeviceDescriptor` lacks `-initMetalDeviceWithGPUCoreCount:architecture:`, or has no such class (iOS 18),
the descriptor is left alone.

Env: `MPS_VERBOSE=1` (what was patched, and each heap made private), `MPS_DISABLE=1`.
