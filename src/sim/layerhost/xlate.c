// xlate.c — see xlate.h. Each x_* function reads one item in the simulator's encoding and writes it in macOS's;
// the comments name the encoder it mirrors (CA::Render::<Class>::encode in QuartzCore).
#include "xlate.h"

#include <mach/mach.h>

#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  const uint8_t *start, *p, *end;
  uint8_t *o;
  size_t len, cap;
  const XLMaps *maps;
  int depth;
  bool flip_layer;                     // the next layer is the context's root (XLMaps.flip_roots)
  bool failed;
  char *err;
  size_t err_len;
} X;

void *xl_trace;
#define TRACE(x, ...) do { if (xl_trace) { fprintf(xl_trace, "%*s", 2 * (x)->depth, ""); fprintf(xl_trace, __VA_ARGS__); } } while (0)

static void fail(X *x, const char *fmt, ...) {
  if (x->failed) return;
  x->failed = true;
  va_list ap; va_start(ap, fmt);
  int n = vsnprintf(x->err, x->err_len, fmt, ap);
  va_end(ap);
  if (n >= 0 && (size_t)n < x->err_len)
    snprintf(x->err + n, x->err_len - n, " (input byte %ld)", (long)(x->p - x->start));
}

static bool need(X *x, size_t n) {
  if (x->failed) return false;
  if ((size_t)(x->end - x->p) < n) { fail(x, "truncated: need %zu bytes, have %zu", n, (size_t)(x->end - x->p)); return false; }
  return true;
}

static void put(X *x, const void *b, size_t n) {
  if (x->failed) return;
  if (x->len + n > x->cap) {
    size_t cap = x->cap ? x->cap * 2 : 4096;
    while (cap < x->len + n) cap *= 2;
    uint8_t *o = realloc(x->o, cap);
    if (!o) { fail(x, "out of memory"); return; }
    x->o = o; x->cap = cap;
  }
  memcpy(x->o + x->len, b, n);
  x->len += n;
}

static void copy(X *x, size_t n) {
  if (!need(x, n)) return;
  put(x, x->p, n);
  x->p += n;
}

#define READER(name, type) \
  static type name(X *x) { type v = 0; if (need(x, sizeof v)) { memcpy(&v, x->p, sizeof v); x->p += sizeof v; } return v; }
READER(rd8, uint8_t)
READER(rd16, uint16_t)
READER(rd32, uint32_t)
READER(rd64, uint64_t)
static void wr8(X *x, uint8_t v) { put(x, &v, 1); }
static void wr16(X *x, uint16_t v) { put(x, &v, 2); }
static void wr32(X *x, uint32_t v) { put(x, &v, 4); }
static void wr64(X *x, uint64_t v) { put(x, &v, 8); }
static uint32_t cp32(X *x) { uint32_t v = rd32(x); wr32(x, v); return v; }
static uint64_t cp64(X *x) { uint64_t v = rd64(x); wr64(x, v); return v; }
static uint8_t cp8(X *x) { uint8_t v = rd8(x); wr8(x, v); return v; }

// ---------------------------------------------------------------- object types and atoms

// CA::Render::Type, simulator -> macOS (from both Decoder::decode_object(Type) switches and the decoding
// constructors' type stores). 0: no macOS type. macOS added ExternalAnimation (17) and lacks the gain map layers.
static int map_type(int t) {
  if (t <= 0 || t > 65) return 0;
  if (t == 6 || t == 8) return 0;    // CarPlayRegionLayer, the cloning terminator layer
  if (t <= 16) return t;
  if (t <= 18) return t + 1;         // Filter, Function
  if (t <= 20) return 0;             // GainMapLayer, GainMapExclusionLayer
  return t - 1;                      // GradientLayer (21) ... WindowLayer (65)
}

enum {   // simulator type numbers this file decodes
  T_ARRAY = 1, T_BACKDROP_LAYER = 3, T_BASIC_ANIMATION = 5, T_COMPRESSED_IMAGE = 9, T_DISTANCE_FIELD_LAYER = 12,
  T_EMITTER_BEHAVIOR = 13, T_FILTER = 17, T_FUNCTION = 18, T_GRADIENT_LAYER = 21, T_GROUP_ANIMATION = 22, T_IMAGE = 24,
  T_IMAGE_QUEUE = 26, T_KEYFRAME_ANIMATION = 28, T_KEYPATH_VALUE = 29, T_KEY_VALUE = 30, T_LAYER = 31, T_LAYER_HOST = 32,
  T_MATCH_MOVE_ANIMATION = 34, T_MATCH_PROPERTY_ANIMATION = 35, T_MEDIA_LAYER = 36, T_METAL_TEXTURE = 38, T_PATH = 40,
  T_PATTERN = 41, T_PIXEL_BUFFER = 42, T_PORTAL_LAYER = 44, T_PRESENTATION_MODIFIER = 46, T_PROXY = 47,
  T_REPLICATOR_LAYER = 48, T_SDF_ELEMENT_LAYER = 49, T_SDF_LAYER = 50, T_SHAPE_LAYER = 53, T_SHMEM = 54,
  T_SPRING_ANIMATION = 55, T_STRING = 56, T_SUBTEXTURE = 58, T_SURFACE = 59, T_TIMING = 60, T_TRANSITION_ANIMATION = 63,
  T_VECTOR = 64, T_WINDOW_LAYER = 65,
};

void xl_maps_init(XLMaps *maps, const char *const *sim_names, size_t sim_count, const char *const *mac_names, size_t mac_count) {
  memset(maps, 0, sizeof *maps);
  for (size_t a = 1; a < sim_count && a < XL_SIM_ATOMS; a++) {
    maps->sim_atom_name[a] = sim_names[a];
    if (!sim_names[a]) continue;
    // Both tables are sorted the same way and differ by a few insertions, so look near the same index first.
    for (size_t d = 0; d < mac_count; d++) {
      size_t lo = a >= d ? a - d : (size_t)-1, hi = a + d;
      if (lo < mac_count && mac_names[lo] && !strcmp(mac_names[lo], sim_names[a])) { maps->atom[a] = (uint16_t)lo; break; }
      if (hi < mac_count && mac_names[hi] && !strcmp(mac_names[hi], sim_names[a])) { maps->atom[a] = (uint16_t)hi; break; }
    }
  }
}

// Encoder::encode_atom: < 0xFE in a byte, 0xFE + u16, or 0xFF + data (the name, for atoms past the static table).
static void x_atom(X *x) {
  uint8_t b = rd8(x);
  if (b == 0xFF) {
    wr8(x, b);
    uint64_t n = cp64(x);
    copy(x, n);
    return;
  }
  uint32_t a = b == 0xFE ? rd16(x) : b;
  if (x->failed) return;
  uint32_t m = a == 0 ? 0 : a < XL_SIM_ATOMS ? x->maps->atom[a] : 0;
  TRACE(x, "atom %u %s -> %u\n", a, a < XL_SIM_ATOMS && x->maps->sim_atom_name[a] ? x->maps->sim_atom_name[a] : "?", m);
  if (a != 0 && m == 0) {   // no macOS atom of that name: send the name
    const char *name = a < XL_SIM_ATOMS ? x->maps->sim_atom_name[a] : NULL;
    if (!name) { fail(x, "unknown atom %u", a); return; }
    wr8(x, 0xFF); wr64(x, strlen(name)); put(x, name, strlen(name));
    return;
  }
  if (m < 0xFE) wr8(x, (uint8_t)m);
  else { wr8(x, 0xFE); wr16(x, (uint16_t)m); }
}

// Encoder::encode_keypath: u16 count, then per component a flag byte and an index (u32) or an atom.
static void x_keypath(X *x) {
  uint16_t n = rd16(x); wr16(x, n);
  for (uint16_t i = 0; i < n && !x->failed; i++) {
    if (cp8(x)) copy(x, 4);
    else x_atom(x);
  }
}

// Encoder::encode_data / encode_data_async: u64 length and the bytes, or ~0 when they went out of line.
static void x_data(X *x) {
  uint64_t n = cp64(x);
  if (n != UINT64_MAX) copy(x, n);
}

static void x_object(X *x);
static void x_cfobject(X *x);

// Encoder::encode_colorspace: 0 none, 1 + index into CA's colorspace table, 2 + property list, 3 the context's, 4 + name.
static void x_colorspace(X *x) {
  switch (cp8(x)) {
    case 0: case 3: break;
    case 1: copy(x, 1); break;
    case 2: case 4: x_cfobject(x); break;
    default: fail(x, "bad colorspace kind %u", x->p[-1]);
  }
}

// Encoder::encode_cfobject: a kind byte (CA::Render::cacftype_from_cfobject), then the value.
static void x_cfobject(X *x) {
  if (++x->depth > 64) { fail(x, "nesting too deep"); return; }
  uint8_t k = cp8(x);
  TRACE(x, "cf %u\n", k);
  switch (k) {
    case 0: case 1: break;                             // nothing, kCFNull
    case 2: if (cp8(x)) x_data(x); break;              // string
    case 3: copy(x, 9); break;                         // number: double/int64 flag + 8 bytes
    case 4: copy(x, 1); break;                         // boolean
    case 5: x_data(x); break;                          // data
    case 6: { uint64_t n = cp64(x); for (uint64_t i = 0; i < n && !x->failed; i++) x_cfobject(x); break; }
    case 7: { uint64_t n = cp64(x); for (uint64_t i = 0; i < n && !x->failed; i++) { x_cfobject(x); x_cfobject(x); } break; }
    case 8: x_colorspace(x); break;
    case 9: {                                          // CGImage: the render object's type byte, then the object
      uint8_t t = rd8(x);
      int m = map_type(t);
      if (!m) { fail(x, "image of type %u", t); break; }
      wr8(x, (uint8_t)m);
      x_object(x);
      break;
    }
    case 10: copy(x, 20); break;                       // CGColor
    case 11: case 13: x_object(x); break;              // CA_copyRenderValue
    case 12: copy(x, 1); x_data(x); break;             // NSValue: struct kind + bytes
    default: fail(x, "unknown cf kind %u", k);
  }
  x->depth--;
}

// ---------------------------------------------------------------- objects

// CA::Render::Layer. The first 88 bytes are the object's fields at +16..+104 copied raw. Both layouts hold the
// background colour, opacity, four bytes, a 128-bit flag field (+40..+56), position and bounds; the flag field's
// bits moved (measured by toggling each CALayer property on both platforms, see docs/layerhost.md).
static void remap_layer_flags(const uint8_t *s, uint8_t *m) {
  memset(m, 0, 16);
  for (int i = 0; i < 128; i++) {
    if (!(s[i >> 3] >> (i & 7) & 1)) continue;
    int j;
    if (i < 56) j = i;                 // filters, gravity, edge mask, corners, hidden, masksToBounds, ...
    else if (i < 75) j = i + 1;        // macOS added smartFlatten at 56
    else if (i < 87) j = i + 2;        // ...and shadowEffectsOnWindowMaskOnly at 76
    else if (i == 87) continue;        // definesDisplayRegionOfInterest: not a layer flag on macOS
    else if (i == 88) j = 90;
    else if (i == 89) j = 100;         // allowsColorMatching
    else continue;                     // not used by the simulator's CALayer
    m[j >> 3] |= (uint8_t)(1 << (j & 7));
  }
  m[97 >> 3] |= 1 << (97 & 7);         // allowsRemoteEffectHitTesting, on by default on macOS
}

static void x_layer(X *x) {
  copy(x, 4);                          // Object::encode
  if (!need(x, 88)) return;
  uint8_t core[88];
  memcpy(core, x->p, 88);
  remap_layer_flags(x->p + 24, core + 24);
  if (x->flip_layer) {
    core[29] ^= 1 << 4;                // geometryFlipped (+45 bit 4, the same bit on both)
    x->flip_layer = false;
  }
  put(x, core, 88);
  x->p += 88;
  x_object(x);                         // contents
  x_object(x);                         // sublayers
  copy(x, 8);                          // layer id
  x_object(x);                         // name
  if (!cp8(x)) return;                 // Layer::Ext
  for (int i = 0; i < 18 && !x->failed; i++) x_object(x);
  wr8(x, 0); wr8(x, 0); wr8(x, 0);     // macOS: separated options, framing options, remote effects
  copy(x, 196);                        // anchor, contents scale ... shadow, the same fields on both
  wr64(x, 0); wr8(x, 0); wr8(x, 0);    // macOS: a size_t and two filters
  copy(x, 1);
}

// CA::Render::Texture::encode, the tail of an Image's encoding. flags: the object's encoded flag word.
static void x_texture(X *x, uint32_t flags) {
  x_colorspace(x);
  copy(x, 4 + 8);
  int32_t shape = (int32_t)cp32(x);
  if (shape == -2) copy(x, 16);
  else if (shape > 3) copy(x, 4 * (size_t)(shape - 3));
  copy(x, 4 + 4 + 1 + 1);
  if (flags & 0x1000) copy(x, 20);
}

// CA::Render::InterpolatedFunction::encode (also inside a GradientLayer): count, components, flags, values,
// then locations (flag 2) and control points (flag 4).
static void x_interpolated(X *x) {
  uint64_t n = cp64(x);
  uint32_t components = cp32(x), flags = cp32(x);
  if (!n) return;
  copy(x, 4 * n * components);
  if (flags & 2) copy(x, 4 * n);
  if (flags & 4) copy(x, 32 * n - 32);
}

static void x_animation(X *x) {        // Animation::encode
  copy(x, 4);
  x_object(x);                         // timing
  x_object(x);                         // timing function
  x_cfobject(x);                       // key
  copy(x, 20);
}
static void x_property_animation(X *x) { x_animation(x); x_keypath(x); x_object(x); }
static void x_basic_animation(X *x) {  // BasicAnimation0::encode
  x_property_animation(x);
  for (int i = 0; i < 3; i++) x_object(x);
  copy(x, 16);
}

static void x_match_animation(X *x) {   // MatchAnimation::encode: source layer and context, flags, keypath
  x_animation(x);
  copy(x, 8 + 8 + 4);
  x_keypath(x);
}

static void x_body(X *x, int t) {
  switch (t) {
    case T_ARRAY: {
      uint32_t flags = cp32(x), n = cp32(x);
      if (flags & 1) copy(x, 8 * (size_t)n);           // ids (sublayers)
      else for (uint32_t i = 0; i < n && !x->failed; i++) x_object(x);
      break;
    }
    case T_BASIC_ANIMATION: x_basic_animation(x); break;
    case T_SPRING_ANIMATION: x_basic_animation(x); copy(x, 32); break;
    case T_KEYFRAME_ANIMATION:
      x_property_animation(x);
      for (int i = 0; i < 4; i++) x_object(x);
      copy(x, 1);
      for (int i = 0; i < 3; i++) x_object(x);
      break;
    case T_GROUP_ANIMATION: x_animation(x); x_object(x); break;
    case T_MATCH_PROPERTY_ANIMATION: x_match_animation(x); break;
    case T_MATCH_MOVE_ANIMATION: x_match_animation(x); x_object(x); break;
    case T_TRANSITION_ANIMATION:                      // type, subtype, two u32s, filter, ...
      x_animation(x);
      x_atom(x); x_atom(x);
      copy(x, 8);
      x_object(x); x_object(x);
      break;
    case T_TIMING: copy(x, 48); break;
    case T_FUNCTION: {
      uint8_t k = cp8(x);
      if (k == 1) copy(x, 1);                         // NamedFunction
      else if (k == 2 || k == 3) x_interpolated(x);   // InterpolatedFunction, Gradient
      else fail(x, "function kind %u", k);
      break;
    }
    case T_FILTER: {                                  // just the name, or 1, the name and two objects
      uint32_t flags = cp32(x);                       // (macOS also has 0 + an archived CIFilter)
      if (flags & 0x100) { x_atom(x); break; }
      uint8_t k = cp8(x);
      if (k != 1) { fail(x, "filter kind %u", k); break; }
      x_atom(x); x_object(x); x_object(x);
      break;
    }
    case T_VECTOR: { uint32_t n = cp32(x); copy(x, 8 * (size_t)n); break; }
    case T_STRING: { uint32_t n = cp32(x); copy(x, n); break; }
    case T_KEY_VALUE: x_atom(x); x_object(x); break;
    case T_KEYPATH_VALUE: x_keypath(x); x_object(x); break;
    case T_LAYER: x_layer(x); break;
    case T_IMAGE: {
      uint32_t flags = cp32(x);
      copy(x, 1);
      uint8_t levels = cp8(x);
      copy(x, 8 + 8 * (size_t)levels);
      if (cp8(x)) x_object(x);                        // Shmem
      else x_data(x);
      x_texture(x, flags);
      break;
    }
    case T_SUBTEXTURE: copy(x, 4); x_object(x); copy(x, 16); break;   // a texture and the part of it (bounds)
    case T_COMPRESSED_IMAGE: {                       // levels' offsets and sizes; the data is a memory entry port
      uint32_t flags = cp32(x);
      copy(x, 8);
      int32_t levels = (int32_t)cp32(x);
      if (levels > 0) copy(x, 24 * (size_t)levels);
      copy(x, 4 + 4 + 1 + 8);
      x_texture(x, flags);
      break;
    }
    case T_PIXEL_BUFFER: {
      uint32_t flags = cp32(x);
      copy(x, 8); x_object(x); copy(x, 8 + 4); x_cfobject(x);
      x_texture(x, flags);
      break;
    }
    case T_IMAGE_QUEUE: x_object(x); copy(x, 4 + 4 + 4); break;   // no flags word; a port between the u32s
    case T_METAL_TEXTURE: break;                                    // encodes nothing
    case T_PATTERN: copy(x, 4 + 112); x_object(x); break;
    case T_LAYER_HOST: copy(x, 4 + 4 + 1); break;                   // the context's port is a descriptor
    case T_MEDIA_LAYER: copy(x, 4); break;
    case T_PROXY: copy(x, 4 + 8); break;
    case T_REPLICATOR_LAYER: copy(x, 4 + 4); x_object(x); copy(x, 36); break;
    case T_DISTANCE_FIELD_LAYER: copy(x, 4 + 17); break;
    case T_WINDOW_LAYER: copy(x, 4 + 21); break;
    case T_EMITTER_BEHAVIOR: copy(x, 4); x_atom(x); x_object(x); x_object(x); break;
    case T_SURFACE: {                                 // an IOSurface (a port descriptor) or another Surface, then a Texture
      uint8_t form = cp8(x);
      uint32_t flags = cp32(x);
      if (form) {
        x_object(x);
        if (flags & 0x200000) copy(x, 1);             // nonzero: the IOSurface's port follows
      } else {
        copy(x, 4);
        uint8_t kind = cp8(x);                        // 1, 3: a port; 0: none (macOS also has 2, shared memory)
        if (kind == 2) copy(x, 8 + 16);
      }
      copy(x, 7);
      x_texture(x, flags);
      break;
    }
    case T_SHMEM: {
      uint32_t flags = cp32(x);
      if (flags & 3) copy(x, 16);                     // size and offset; the memory is a port descriptor
      else x_data(x);
      break;
    }
    case T_PATH: {
      copy(x, 4 + 32 + 16 + 8);
      uint32_t bytes = cp32(x), points = cp32(x);
      copy(x, 4);
      copy(x, bytes);
      copy(x, 16 * (size_t)points);
      break;
    }
    case T_SHAPE_LAYER:
      copy(x, 4);
      x_object(x); copy(x, 20);                       // path, fill colour
      x_object(x); copy(x, 20);                       // ..., stroke colour
      x_object(x); copy(x, 40);
      x_object(x); copy(x, 3);
      break;
    // Liquid Glass
    case T_BACKDROP_LAYER:                            // group id, mask/filter object, scales, rects, flags
      copy(x, 4 + 8); x_object(x); copy(x, 4 + 4 + 4 + 4 + 32 + 4 + 32 + 1);
      break;
    case T_PORTAL_LAYER:                              // source layer and context ids, flags, then an object
      copy(x, 4 + 8 + 8 + 4 + 1); x_object(x);
      break;
    case T_PRESENTATION_MODIFIER:                     // value, id, keypath, flags
      copy(x, 4); x_object(x); copy(x, 8); x_keypath(x); copy(x, 4);
      break;
    case T_SDF_ELEMENT_LAYER: copy(x, 4 + 1 + 1 + 12 + 1); break;
    case T_SDF_LAYER: {                               // 128 bytes of shape, a kind, ..., and for kind 3 a gradient
      copy(x, 4); x_data(x);
      uint8_t kind = cp8(x);
      copy(x, 12 + 1);
      wr8(x, 0);                                      // macOS has another flag byte here (+169)
      copy(x, 8);
      if (kind == 3) x_interpolated(x);           // Gradient::encode, no type or function-kind byte
      break;
    }
    case T_GRADIENT_LAYER: {
      uint32_t flags = cp32(x);
      x_interpolated(x);
      copy(x, 32);                                     // start and end points
      x_atom(x);                                       // type
      copy(x, 4);
      if (flags & 8) x_object(x);
      x_colorspace(x);
      break;
    }
    default: fail(x, "unsupported object type %d", t);
  }
}

// Encoder::encode_object: 0 (none), 0xFE + id + sequence + the object (first use of a cached object),
// 0xFF + id + sequence (a cached one), or the type byte and the object.
static void x_object(X *x) {
  if (x->failed) return;
  if (++x->depth > 64) { fail(x, "nesting too deep"); return; }
  uint8_t t = rd8(x);
  if (t == 0) wr8(x, 0);
  else if (t == 0xFE) { wr8(x, t); copy(x, 12); x_object(x); }
  else if (t == 0xFF) { wr8(x, t); copy(x, 12); }
  else {
    int m = map_type(t);
    TRACE(x, "object %u -> %d at %ld (out %zu)\n", t, m, (long)(x->p - x->start - 1), x->len);
    if (!m) fail(x, "object type %u has no macOS counterpart", t);
    else { wr8(x, (uint8_t)m); x_body(x, t); }
  }
  x->depth--;
}

// ---------------------------------------------------------------- render server requests

// From both CASCARenderServices_subsystem tables: macOS added RegisterCommitBatch (40210) and the context recorder
// routines (40275, 40276).
int xl_map_request(int id) {
  if (id < 40200 || id > 40290) return 0;
  if (id < 40210) return id;
  if (id < 40274) return id + 1;
  return id + 3;
}

// ---------------------------------------------------------------- context roots

// Each context's root layer handle: set by command 7 in its first commit, and the layer object itself comes with
// command 2 (then and in later commits).
static struct { uint32_t context; uint64_t root; } gRoots[256];
static pthread_mutex_t gRootsLock = PTHREAD_MUTEX_INITIALIZER;

static void set_root(uint32_t context, uint64_t root) {
  pthread_mutex_lock(&gRootsLock);
  unsigned i = context % 256;
  gRoots[i].context = context; gRoots[i].root = root;   // a collision forgets the older context's root
  pthread_mutex_unlock(&gRootsLock);
}

static bool is_root(uint32_t context, uint64_t handle) {
  pthread_mutex_lock(&gRootsLock);
  unsigned i = context % 256;
  bool r = gRoots[i].context == context && gRoots[i].root == handle;
  pthread_mutex_unlock(&gRootsLock);
  return r;
}

// ---------------------------------------------------------------- commands (Server::CmdStreamMsg::run)

uint8_t *xl_translate(const XLMaps *maps, const uint8_t *in, size_t in_len, size_t *out_len, char *err, size_t err_len) {
  X x = { .start = in, .p = in, .end = in + in_len, .maps = maps, .err = err, .err_len = err_len };
  if (err_len) err[0] = 0;
  if (!need(&x, 16)) return NULL;
  uint32_t flags, context;
  memcpy(&flags, in, 4);
  memcpy(&context, in + 4, 4);
  if (flags & 8) { fail(&x, "commit has sanity words (header flags %#x)", flags); return NULL; }
  copy(&x, 16);
  while (!x.failed) {
    uint8_t op = rd8(&x);
    if (x.failed) break;
    TRACE(&x, "command %u at %ld (out %zu)", op, (long)(x.p - x.start - 1), x.len);
    if (xl_trace && (op == 2 || op == 3 || op == 4 || op == 7) && x.end - x.p >= 8) {
      uint64_t h; memcpy(&h, x.p, 8); fprintf(xl_trace, " handle %#llx", (unsigned long long)h);
    }
    if (xl_trace) fprintf(xl_trace, "\n");
    switch (op) {
      case 0: wr8(&x, 0); goto done;
      case 1: wr8(&x, op); copy(&x, 12); break;                                   // size_t, u32
      case 2: {                                                                   // set object
        uint64_t handle = rd64(&x);
        wr8(&x, op); wr64(&x, handle); copy(&x, 4);
        x.flip_layer = maps->flip_roots && is_root(context, handle);
        x_object(&x);
        x.flip_layer = false;
        copy(&x, 4);
        break;
      }
      case 7: {                                                                   // set root layer
        uint64_t handle = rd64(&x);
        wr8(&x, op); wr64(&x, handle);
        set_root(context, handle);
        break;
      }
      case 3: case 5: case 12: case 13: wr8(&x, op); copy(&x, 8); break;
      case 4: wr8(&x, op); copy(&x, 8); x_object(&x); break;                      // add animation
      case 6: wr8(&x, op); copy(&x, 8); x_cfobject(&x); break;                    // remove animation
      case 8: case 11: wr8(&x, op); x_cfobject(&x); break;
      case 10: wr8(&x, op); x_colorspace(&x); break;
      case 14: case 16: wr8(&x, op); copy(&x, 4); break;
      case 15: wr8(&x, op); copy(&x, 4); x_object(&x); break;                     // set slot
      case 17: case 19: wr8(&x, op); copy(&x, 8); break;
      case 18: case 23: wr8(&x, op); copy(&x, 12); break;
      case 21: wr8(&x, op); copy(&x, 16); break;
      case 22: wr8(&x, op); copy(&x, 12); x_object(&x); break;                    // set fill colour
      case 24: wr8(&x, op); copy(&x, 20); x_object(&x); copy(&x, 8); break;      // set subimage
      case 25: wr8(&x, op); copy(&x, 32); break;                                  // invalidate
      case 26: wr8(&x, op); break;
      case 27: case 29: case 30: case 31: wr8(&x, op); copy(&x, 8); break;
      case 28: case 32: wr8(&x, op); copy(&x, 1); break;
      case 33: wr8(&x, op); copy(&x, 5); break;
      case 34: wr8(&x, 38); break;                                                // port (a descriptor)
      case 35: wr8(&x, 39); copy(&x, 8); break;
      case 36: wr8(&x, 40); x_object(&x); break;                                  // presentation modifier shmem
      case 37: wr8(&x, 41); copy(&x, 8); break;                                   // glitch request
      default: fail(&x, "unsupported command %u", op);
    }
  }
done:
  if (x.failed) { free(x.o); return NULL; }
  *out_len = x.len;
  return x.o;
}

// ---------------------------------------------------------------- commit messages

static size_t descriptor_size(const mach_msg_descriptor_t *d) {
  switch (d->type.type) {
    case MACH_MSG_PORT_DESCRIPTOR: return sizeof(mach_msg_port_descriptor_t);
    case MACH_MSG_OOL_DESCRIPTOR: case MACH_MSG_OOL_VOLATILE_DESCRIPTOR: return sizeof(mach_msg_ool_descriptor_t);
    case MACH_MSG_OOL_PORTS_DESCRIPTOR: return sizeof(mach_msg_ool_ports_descriptor_t);
    case MACH_MSG_GUARDED_PORT_DESCRIPTOR: return sizeof(mach_msg_guarded_port_descriptor_t);
    default: return 0;
  }
}

// CA::Render::Encoder::send_message: the descriptor count is there even in a simple message (then 0); for 40003 and
// 40005 the first descriptor is the commit; 40004/40005 have a port before the objects' descriptors.
bool xl_commit_parse(const mach_msg_header_t *m, XLCommit *c) {
  memset(c, 0, sizeof *c);
  const uint8_t *p = (const uint8_t *)(m + 1), *end = (const uint8_t *)m + m->msgh_size;
  if (p + sizeof(mach_msg_body_t) > end) return false;
  uint32_t n = (m->msgh_bits & MACH_MSGH_BITS_COMPLEX) ? ((const mach_msg_body_t *)p)->msgh_descriptor_count : 0;
  p += sizeof(mach_msg_body_t);
  bool ool = m->msgh_id == 40003 || m->msgh_id == 40005;
  for (uint32_t i = 0; i < n; i++) {
    const mach_msg_descriptor_t *d = (const void *)p;
    size_t size = descriptor_size(d);
    if (!size || p + size > end) return false;
    if (i == 0 && ool) {
      if (d->type.type != MACH_MSG_OOL_DESCRIPTOR) return false;
      c->data = d->out_of_line.address; c->len = d->out_of_line.size;
    } else {
      if (!c->descs) c->descs = p;
      c->descs_len += size; c->ndescs++;
    }
    p += size;
  }
  if (!ool) { c->data = p; c->len = (size_t)(end - p); }
  return c->data != NULL;
}

mach_msg_header_t *xl_commit_build(const mach_msg_header_t *m, const XLCommit *c, const uint8_t *data, size_t len) {
  bool fence = m->msgh_id >= 40004;
  size_t fixed = sizeof(mach_msg_header_t) + sizeof(mach_msg_body_t) + c->descs_len;
  bool ool = fixed + len + 3 >= vm_page_size;
  size_t size = ool ? fixed + sizeof(mach_msg_ool_descriptor_t) : (fixed + len + 3) & ~(size_t)3;
  mach_msg_header_t *h = calloc(1, size);
  if (!h) return NULL;
  *h = *m;
  h->msgh_size = (mach_msg_size_t)size;
  h->msgh_id = (fence ? 40004 : 40002) + ool;
  uint32_t ndescs = c->ndescs + ool;
  if (ndescs) h->msgh_bits |= MACH_MSGH_BITS_COMPLEX;
  else h->msgh_bits &= ~MACH_MSGH_BITS_COMPLEX;
  uint8_t *p = (uint8_t *)(h + 1);
  ((mach_msg_body_t *)p)->msgh_descriptor_count = ndescs;
  p += sizeof(mach_msg_body_t);
  if (ool) {
    mach_msg_ool_descriptor_t *d = (void *)p;
    d->address = (void *)data; d->size = (mach_msg_size_t)len;
    d->deallocate = false; d->copy = MACH_MSG_VIRTUAL_COPY; d->type = MACH_MSG_OOL_DESCRIPTOR;
    p += sizeof *d;
  }
  if (c->descs_len) memcpy(p, c->descs, c->descs_len);
  p += c->descs_len;
  if (!ool) memcpy(p, data, len);
  return h;
}
