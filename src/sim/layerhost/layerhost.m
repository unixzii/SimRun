// layerhost — app.dylib's layerhost module (layerhost.h, docs/layerhost.md). An experiment, on with SIMRUN_LAYERHOST=1:
// the app's CAContexts live on the Mac's WindowServer, which composites them into SimRun's window directly, instead of
// on the in-process render server (render/), whose frames SimRun shows today.
//
// SimRun publishes WindowServer's com.apple.CARenderServer in simns as dev.simrun.windowserver. A mach_msg()
// interposer then sends the app's requests to the in-process render server (MIG subsystem CARenderServices) on to
// WindowServer, renumbered for macOS (xl_map_request), except the display ones: UIScreen keeps describing the
// simulated phone. Contexts registered there get their commits translated to macOS's encoding (xl_translate). The
// render module tells SimRun which contexts to show (SRLayerHostShow) instead of hosting them on its display.
// LAYERHOST_VERBOSE=1 logs each redirected request and commit; LAYERHOST_DUMP=<dir> records each commit before and
// after translation (<n>-in.bin, <n>-out.bin) and the atom names (sim-atoms.txt), for tools/layerhost/xltest.c.
#import "layerhost.h"
#import "app.h"
#include <pthread.h>
#include <sys/stat.h>
#import "spi.h"
#include "protocol.h"
#include "xlate.h"
#include "atoms_mac.h"

#define LOG(...) fprintf(stderr, "[layerhost] " __VA_ARGS__)

extern CFStringRef CAAtomGetString(unsigned);

static BOOL gOn, gVerbose;
static const char *gDump;
static _Atomic int gDumpSeq;

static void Dump(int n, const char *suffix, const void *p, size_t len) {
  char path[1024];
  snprintf(path, sizeof path, "%s/%04d-%s.bin", gDump, n, suffix);
  FILE *f = fopen(path, "wb");
  if (f) { fwrite(p, 1, len, f); fclose(f); }
}
static mach_port_t gWindowServer;            // WindowServer's render server
static _Atomic mach_port_t gLocalServer;     // the in-process one (render/), once it has checked in
static XLMaps gMaps;

// Ports WindowServer handed out in replies (the contexts' ports): commits to them are translated.
static mach_port_t gRemotePorts[256];
static size_t gRemoteCount;
static pthread_mutex_t gRemoteLock = PTHREAD_MUTEX_INITIALIZER;

static void AddRemotePort(mach_port_t p) {
  pthread_mutex_lock(&gRemoteLock);
  BOOL known = NO;
  for (size_t i = 0; i < gRemoteCount; i++) known |= gRemotePorts[i] == p;
  if (!known) gRemotePorts[gRemoteCount++ % 256] = p;   // the oldest is forgotten past 256
  if (gRemoteCount > 256) gRemoteCount = 256;
  pthread_mutex_unlock(&gRemoteLock);
}

static BOOL IsRemotePort(mach_port_t p) {
  pthread_mutex_lock(&gRemoteLock);
  BOOL r = NO;
  for (size_t i = 0; i < gRemoteCount && !r; i++) r = gRemotePorts[i] == p;
  pthread_mutex_unlock(&gRemoteLock);
  return r;
}

static mach_port_t LocalServer(void) {
  mach_port_t p = gLocalServer;
  if (p) return p;
  // the same port QuartzCore looks up (a send right has one name per task), once the render module checked it in
  if (bootstrap_look_up(bootstrap_port, "com.apple.CARenderServer", &p) != KERN_SUCCESS) return MACH_PORT_NULL;
  gLocalServer = p;
  return p;
}

// The display's requests stay with the in-process server (simulator ids): GetDisplays ... SetDisplayLatency, and
// GetDisplayStateShmem ... GetDisplayInfoShmem (display state, power and frame rate assertions, cloning).
static BOOL IsDisplayRequest(mach_msg_id_t id) { return (id >= 40231 && id <= 40241) || (id >= 40274 && id <= 40290); }

// A request for the in-process server, sent to WindowServer instead; the reply comes back with the simulator's id.
static mach_msg_return_t ToWindowServer(mach_msg_header_t *m, mach_msg_option_t opt, mach_msg_size_t send_size, mach_msg_size_t rcv_size,
                                        mach_port_t rcv_name, mach_msg_timeout_t timeout, mach_port_t notify) {
  mach_msg_id_t id = m->msgh_id, mapped = xl_map_request(id);
  if (!mapped) { LOG("request %d has no macOS counterpart\n", id); return MIG_BAD_ID; }
  mach_port_t local = m->msgh_remote_port;
  if (MACH_MSGH_BITS_REMOTE(m->msgh_bits) == MACH_MSG_TYPE_MOVE_SEND) {
    mach_port_mod_refs(mach_task_self(), gWindowServer, MACH_PORT_RIGHT_SEND, 1);
    mach_port_deallocate(mach_task_self(), local);
  }
  m->msgh_remote_port = gWindowServer;
  m->msgh_id = mapped;
  mach_msg_return_t kr = mach_msg(m, opt, send_size, rcv_size, rcv_name, timeout, notify);
  if (!(opt & MACH_RCV_MSG)) return kr;
  if (kr != MACH_MSG_SUCCESS) { if (gVerbose) LOG("request %d -> %#x\n", id, kr); return kr; }
  if (m->msgh_id == mapped + 100) m->msgh_id = id + 100;
  if (m->msgh_bits & MACH_MSGH_BITS_COMPLEX) {   // remember the ports that came back (RegisterClient: the context's)
    const mach_msg_body_t *b = (const void *)(m + 1);
    const uint8_t *p = (const uint8_t *)(b + 1), *end = (const uint8_t *)m + m->msgh_size;
    for (uint32_t i = 0; i < b->msgh_descriptor_count && p + sizeof(mach_msg_port_descriptor_t) <= end; i++) {
      const mach_msg_descriptor_t *d = (const void *)p;
      if (d->type.type == MACH_MSG_PORT_DESCRIPTOR) { if (d->port.name) AddRemotePort(d->port.name); p += sizeof d->port; }
      else if (d->type.type == MACH_MSG_OOL_DESCRIPTOR || d->type.type == MACH_MSG_OOL_VOLATILE_DESCRIPTOR) p += sizeof d->out_of_line;
      else break;
    }
  }
  if (gVerbose) LOG("request %d (macOS %d) -> reply %d\n", id, mapped, m->msgh_id);
  return kr;
}

static mach_msg_return_t TranslateCommit(mach_msg_header_t *m, mach_msg_option_t opt, mach_msg_size_t send_size, mach_msg_size_t rcv_size,
                                         mach_port_t rcv_name, mach_msg_timeout_t timeout, mach_port_t notify) {
  XLCommit c;
  char err[256];
  size_t len = 0;
  uint8_t *out = NULL;
  mach_msg_header_t *t = NULL;
  int n = gDump ? gDumpSeq++ : 0;
  if (!xl_commit_parse(m, &c)) snprintf(err, sizeof err, "unexpected message layout (id %d, %u bytes)", m->msgh_id, m->msgh_size);
  else if ((out = xl_translate(&gMaps, c.data, c.len, &len, err, sizeof err))) t = xl_commit_build(m, &c, out, len);
  if (gDump && c.data) { Dump(n, "in", c.data, c.len); if (out) Dump(n, "out", out, len); }
  if (!t) {   // sent as it is: WindowServer drops what it can't decode, and the log says why
    LOG("commit (%zu bytes) not translated: %s\n", c.len, err);
    free(out);
    return mach_msg(m, opt, send_size, rcv_size, rcv_name, timeout, notify);
  }
  if (gVerbose) LOG("commit %zu -> %zu bytes, %u descriptors\n", c.len, len, c.ndescs);
  // send ours; a reply (synchronous commits) still arrives in the caller's buffer
  mach_msg_return_t kr = mach_msg(t, opt & ~MACH_RCV_MSG, t->msgh_size, 0, MACH_PORT_NULL, timeout, notify);
  free(t); free(out);
  if (kr == MACH_MSG_SUCCESS && (opt & MACH_RCV_MSG)) kr = mach_msg(m, opt & ~MACH_SEND_MSG, 0, rcv_size, rcv_name, timeout, notify);
  return kr;
}

static mach_msg_return_t lh_mach_msg(mach_msg_header_t *m, mach_msg_option_t opt, mach_msg_size_t send_size, mach_msg_size_t rcv_size,
                                     mach_port_t rcv_name, mach_msg_timeout_t timeout, mach_port_t notify) {
  if (gOn && (opt & MACH_SEND_MSG)) {
    mach_msg_id_t id = m->msgh_id;
    if (id >= 40200 && id <= 40290 && !IsDisplayRequest(id) && m->msgh_remote_port && m->msgh_remote_port == LocalServer())
      return ToWindowServer(m, opt, send_size, rcv_size, rcv_name, timeout, notify);
    if (xl_is_commit(id) && IsRemotePort(m->msgh_remote_port))
      return TranslateCommit(m, opt, send_size, rcv_size, rcv_name, timeout, notify);
  }
  return mach_msg(m, opt, send_size, rcv_size, rcv_name, timeout, notify);
}

__attribute__((used, section("__DATA,__interpose"))) static struct { const void *n, *o; } interposers[] = {
  { (const void *)lh_mach_msg, (const void *)mach_msg },
};

BOOL SRLayerHostOn(void) { return gOn; }

void SRLayerHostShow(const uint32_t *ids, size_t count, CGSize size) {
  mach_port_t host = SRSessionPort();
  if (!host) return;
  sr_layerhost_msg_t msg = {0};
  msg.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
  msg.h.msgh_size = sizeof msg; msg.h.msgh_remote_port = host; msg.h.msgh_id = SR_MSG_LAYERHOST;
  msg.count = (uint32_t)MIN(count, SR_LAYERHOST_MAX);
  msg.width = size.width; msg.height = size.height;
  for (uint32_t i = 0; i < msg.count; i++) msg.ids[i] = ids[i];
  mach_msg(&msg.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof msg, 0, MACH_PORT_NULL, 1000, MACH_PORT_NULL);
  LOG("showing %u WindowServer context%s in SimRun's window:", msg.count, msg.count == 1 ? "" : "s");
  for (uint32_t i = 0; i < msg.count; i++) fprintf(stderr, " %u", msg.ids[i]);
  fprintf(stderr, "\n");
}

void SRLayerHostStart(void) {
  if (!getenv("SIMRUN_LAYERHOST")) return;
  gVerbose = getenv("LAYERHOST_VERBOSE") != NULL;
  if (bootstrap_look_up(bootstrap_port, "dev.simrun.windowserver", &gWindowServer) != KERN_SUCCESS) {
    LOG("SimRun doesn't publish dev.simrun.windowserver: off\n");
    return;
  }
  gDump = getenv("LAYERHOST_DUMP");
  FILE *atoms = NULL;
  if (gDump) {
    mkdir(gDump, 0755);
    char path[1024]; snprintf(path, sizeof path, "%s/sim-atoms.txt", gDump);
    atoms = fopen(path, "w");
  }
  static const char *simNames[XL_SIM_ATOMS];
  for (unsigned a = 1; a < XL_SIM_ATOMS; a++) {
    CFStringRef s = CAAtomGetString(a);
    simNames[a] = s ? strdup([(__bridge NSString *)s UTF8String]) : NULL;
    if (atoms) fprintf(atoms, "%s\n", simNames[a] ?: "");
  }
  if (atoms) fclose(atoms);
  xl_maps_init(&gMaps, simNames, XL_SIM_ATOMS, kMacAtomNames, sizeof kMacAtomNames / sizeof *kMacAtomNames);
  gMaps.flip_roots = YES;   // iOS's top-left origin and contents orientation (xlate.h)
  gOn = YES;
  LOG("on: the app's contexts go to WindowServer\n");
}
