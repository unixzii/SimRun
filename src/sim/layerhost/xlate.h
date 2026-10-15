// xlate.h — translates Core Animation commits from the iOS-simulator QuartzCore to the macOS one (docs/layerhost.md).
//
// A commit is what CA::Render::Encoder builds and CA::Render::Encoder::send_message sends to the render server: a
// 16-byte header (u32 flags, u32 context id, double time), commands (an opcode byte each), and a 0 at the end. The
// objects inside are encoded by each CA::Render class's encode(); the two QuartzCores share almost all of them but
// number object types, atoms and some opcodes differently, and lay out CA::Render::Layer differently.
//
// Written against iOS 27.1 (QuartzCore 1223.6.11) and macOS 27.2 (QuartzCore 1223.10.16).
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define XL_SIM_ATOMS 806   // static atoms are 1...805 in the simulator; larger ones are sent as strings
#define XL_MAC_ATOMS 807   // ...and 1...806 on macOS (experimentalCulling was added at 251)

typedef struct {
  uint16_t atom[XL_SIM_ATOMS];               // simulator atom -> macOS atom; 0: no macOS atom, send the name
  const char *sim_atom_name[XL_SIM_ATOMS];   // for that fallback
  // The iOS render server puts a context's origin at the top left and draws layer contents that way up; the
  // macOS one does neither. With flip_roots, each context's root layer gets geometryFlipped toggled, which makes
  // macOS CA lay out and draw the tree as iOS does (UIKit needs it).
  bool flip_roots;
} XLMaps;

// Fills maps from both platforms' atom names (index = atom).
void xl_maps_init(XLMaps *maps, const char *const *sim_names, size_t sim_count, const char *const *mac_names, size_t mac_count);

// Translates one commit. On success returns a malloc'ed buffer (*out_len bytes, ending with the 0 opcode). Ports and
// out-of-line data travel as message descriptors, which the translation leaves where they are: every object that
// refers to one is translated or the whole commit fails. On failure returns NULL and describes the problem in err.
uint8_t *xl_translate(const XLMaps *maps, const uint8_t *in, size_t in_len, size_t *out_len, char *err, size_t err_len);

// The render server's MIG routines (subsystem CARenderServices, replies are id + 100): simulator request id ->
// macOS request id, 0 when macOS has no such routine.
int xl_map_request(int sim_id);

// ---- commit messages (CA::Render::Encoder::send_message): ids 40002-40005
#include <mach/message.h>
static inline bool xl_is_commit(mach_msg_id_t id) { return id >= 40002 && id <= 40005; }
// Where the commit is in m (inline after the descriptors for 40002/40004, out of line in the first descriptor for
// 40003/40005), and the descriptors that aren't it. false: not laid out as expected.
typedef struct {
  const uint8_t *data; size_t len;
  const uint8_t *descs; size_t descs_len; uint32_t ndescs;
} XLCommit;
bool xl_commit_parse(const mach_msg_header_t *m, XLCommit *c);
// m with the commit replaced by data/len (inline below a page, as CA does, else out of line pointing at data, which
// must outlive the send). The other descriptors are kept in order. Free with free().
mach_msg_header_t *xl_commit_build(const mach_msg_header_t *m, const XLCommit *c, const uint8_t *data, size_t len);

// When set, xl_translate() prints the commands and objects it reads there.
extern void *xl_trace;   // FILE *
