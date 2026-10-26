# Optional Metal library mappings

An explicit, process-local diagnostic for an application that embeds a device-only
Metal library in a simulator build. It maps exact library content to a separately
supplied simulator library. No application, SDK, shader bytes, or private resource
is included here. This module is not part of the default SimRun build.

Build with `bash extras/metal-library-overrides/build.sh`. The output is an ad-hoc
signed arm64 iOS-simulator dylib at
`build/metal-library-overrides/SimRunMetalLibraryOverrides.dylib`.

## Prepare an explicit mapping

```sh
python3 extras/metal-library-overrides/create-manifest.py \
  --input-library /absolute/path/device.metallib \
  --simulator-library /absolute/path/simulator.metallib \
  --manifest /absolute/path/map.json
```

The host script checks the MTLB header/declared size, computes both SHA256 hashes,
and uses `xcrun metal-objdump` on an exact-byte snapshot to require every replacement
AIR module to target iOS simulator. It writes a private, atomic mode-0600 manifest.
Supplying the correct shader interface and implementation remains the caller's
responsibility: a platform-compatible library alone does not establish correctness.

Schema 1 is an object containing `schema: 1` and `mappings`, an array of 1–16 objects:

```json
{
  "input_sha256": "64 lowercase hex characters",
  "input_size": 12345,
  "output_sha256": "64 lowercase hex characters",
  "output_size": 23456,
  "output_path": "/absolute/path/simulator.metallib"
}
```

`validated_target_triples` is host-side informational metadata. Runtime validation
independently checks output size, full SHA256, MTLB magic and declared length.
It initializes the actual default Metal device (including its lazily loaded class)
and requires `MTLSimDevice`. The exact replacement bytes then undergo real library
and pipeline compiler preflight on that device before any mapping becomes active.
Libraries are bounded to 16 MiB; manifests to 1 MiB. Duplicate input mappings fail.
Configuration is transactional: failure returns an error dictionary and retains
the prior configuration. A failure does not implicitly disable a working mapping.

Compiler preflight supports libraries containing at most 32 simple vertex,
fragment and compute entry functions. It enumerates vertex/fragment pairs with
BGRA8Unorm (then RGBA16Float on failure), requires every vertex and fragment to
participate in at least one successful pipeline, and compiles every compute entry.
Complex vertex descriptors, function constants, mesh/object/tile functions, and
other required pipeline state are deliberately unsupported and fail closed. A
device-only library that loads but fails every pipeline cannot be configured.
`status.last_preflight` records these independent validation counts; expected
mismatched varying pairs can fail even in a valid library.

## Enable and disable

Loading the dylib with no `SIMRUN_METAL_LIBRARY_MAP` environment variable installs
no hooks and reads no manifest. An owned test process may load the dylib, then call:

```objc
[SRMetalLibraryOverrides configureWithManifest:@"/absolute/path/map.json"];
[SRMetalLibraryOverrides status];
[SRMetalLibraryOverrides disable];
```

Alternatively, explicitly set `SIMRUN_METAL_LIBRARY_MAP` before loading the dylib.
The class exposes the same APIs to the SimRun Objective-C scripting bridge.
No default mapping, App-specific hash, or resource path exists in the source.

For a separate SimRun test instance:

```sh
SIMRUN_METAL_LIBRARY_MAP=/absolute/path/map.json /absolute/path/simrun run \
  --headless --mute -p metal-library-test \
  --insert /absolute/path/SimRunMetalLibraryOverrides.dylib /absolute/path/App.app
```

Use an unused profile and keep that launch process alive. Loading/configuring this
module does not recompile an existing renderer's cached nil pipeline; re-enter the
video or use the player's normal retry action. Existing processes are unchanged.

Only `MTLSimDevice`'s `newLibraryWithData:error:` method is wrapped. An inherited
implementation is shadowed on that concrete class, never changed on a superclass.
Inputs with another size or SHA256 call the original implementation unchanged.
The wrapper preserves the new-family +1 return ownership and the caller's original
NSError pointer, including NULL. Dispatch data retains replacement bytes through
its destructor; a strong configuration snapshot survives concurrent disable.

`disable` clears the mapping atomically. Later calls pass through. An already
in-flight call can finish using its earlier snapshot. The transparent wrapper
remains installed to avoid unsafe concurrent method restoration. Do not `dlclose`
the module while the process remains alive; terminate the owned process to remove
the wrapper completely.

## Acceptance and evidence

Keep all application-specific resources and playback artifacts private. A minimal
acceptance compares the same video and renderer in a disposable profile:

1. Capture the original Metal pipeline NSError and growing display errors while
   decoder/video PTS advances and the visible video frame remains unchanged.
2. Validate a matching simulator resource and save the manifest's hashes/targets.
3. Load/configure this module; re-create the video renderer. An existing nil
   pipeline does not automatically recompile just because a mapping is enabled.
4. Confirm `status.matches` and `status.replacements` advance for the expected
   input/output hashes. Capture the actual pipeline result, display-error deltas,
   changing video-only pixels and advancing playback time on the same video.
5. Disable and re-create the renderer to reproduce the original failure. Verify
   an unrelated library still passes through and malformed/hash-mismatch configs
   return errors without replacing a known-good configuration.

Status contains counters, the last matched sizes/hashes, and failed library-call
NSError domain/code. It stores no resource bytes, URLs, paths, descriptions, or
NSError userInfo. A library-only hook cannot observe the later render-pipeline API;
`pipeline_errors.observed` therefore stays false for actual playback (compiler
preflight is reported separately). Capture playback pipeline errors separately
with a scoped debugger/probe, never infer pipeline success from library loading.

`tests.m` and `run-tests.py` provide a short-lived headless regression probe.
Supply both private libraries, a reviewed module SHA256, the SimRun executable,
and a new private output directory explicitly. It verifies startup configuration,
exact matches, unknown-input passthrough, disable/re-enable, and rejection of
wrong hashes/sizes, device-target output and invalid schemas. It never downloads
resources or operates another running App.

This is a local compatibility experiment. The preferred product repair is to ship
and select the proper simulator shader resource in the player SDK's build. Runtime
mapping does not establish video-wide compatibility or justify changing SDK/App
resources or globally weakening Metal platform validation.

## License

MIT, retaining SimRun's `Copyright (c) 2026 Cyandev`; see [LICENSE](LICENSE).
External shader libraries keep their original licensing and are never bundled by
this module.
