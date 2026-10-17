// simrund_proto.h — client (the simrun CLI) <-> server (SimRun.app) protocol over a Unix-domain socket. Host (macOS)
// code only.
//
// Every message is a uint32 length (host byte order) followed by a binary property list (a dictionary). A client sends
// one request per connection; `action` says what it is:
//   run         { argv: [string], env: [string], cwd: string, profile?, runtime?, device?, insert?, headless?: bool,
//                 pick?: [string] }
//               argv[0] is an .app bundle or a sim executable (absolute, or relative to cwd); the rest are the app's
//               arguments. env is the client's environment, which the app inherits: the server adds the simulator
//               environment itself (runtime, device, data container, injected libraries). profile: the app's data
//               container to use (default: its default one); runtime: an installed iOS runtime (build, version, name
//               or RuntimeRoot; default: SimRun's); device: a device type (identifier or name; default: the runtime's);
//               insert: an extra sim dylib to inject; headless: no window, SimRun never comes forward, the app gets
//               pasteboards of its own and no file panels (SRSession headless); pick: files and folders its document
//               pickers choose from, with no panel (docpickerhost.h). The message carries the client's
//               stdin/stdout/stderr as SCM_RIGHTS, so the app writes straight to the client's terminal.
//               replies: { pid: int } app started, then { exit: int } app finished (raw wait(2) status); or
//               { error: string } launch failed. Closing the connection before { exit } terminates the app (this is how
//               Ctrl-C on the client propagates).
//   list        -> { instances: [ { pid, title, executable, app?, bundleID?, profile?, runtime, device?, ready, headless? } ] }
//   quit        { instance: string, profile? } -> { ok: true }
//   screenshot  { instance: string, profile? } -> { png: data } (the app's screen, at its pixel size)
//               instance: a pid, or an app (name, bundle ID or executable name), among the instances in `profile`
//               when given; an app running in several profiles needs one.
//   eval        { instance: string, profile?, source: string, snapshot?: bool }   run JavaScript in the app (the script module,
//               scripting.md). replies: { log: string } for each console line; with snapshot, { snapshot: string } (the
//               screen as text once the script has ended and the UI has settled); then { result: string } (the
//               script's value, "" if none) or { exception: string } (it threw: message and where); { error: string }
//               if it can't run. instance and profile as for screenshot.
//   pick        { instance: string, profile?, paths?: [string], cancel?: bool, timeout?: number }   answer the app's
//               document picker as if `paths` (absolute) were chosen, or cancel it: the one open now, else the next
//               one within timeout s (default 10). -> { chosen: [string] } what the app got. Neither paths nor cancel:
//               -> { picker?: { panel, files, directories, multiple, types, extensions, name, description } } what
//               the open one asks for. instance and profile as for screenshot.
//   profiles    { app? } -> { apps: [ { id, profiles: [string] } ] }   the data containers each app has ("default" first)
//               app: a bundle ID, or the path of an .app or executable
//   runtimes    -> { runtimes: [ { name, version, build, root, current: bool } ] }   current: what SimRun runs on
//   devices     { runtime? } -> { runtime: string, devices: [ { identifier, name, width, height, scale, default: bool } ] }
//   status      -> { pid, runtime, instances: int }
//   remote      { enable?: bool, reset?: bool } -> { enabled, port, link?, localLink?, viewers? }   remote control
//               (remote.md): turn it on or off (kept for later launches), or make a new link (reset: the access
//               key changes, so links given out before stop working)
//   stop        -> { ok: true }, then SimRun quits (ending every app)
//   show        { open: [string] } (no reply) a second SimRun instance handing over: show the launcher, open these apps
// Any request can be answered with { error: string } instead.
#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

// The real home directory, whatever $HOME says.
static inline const char *simrund_home(void) {
  struct passwd *pw = getpwuid(getuid());
  return pw && pw->pw_dir ? pw->pw_dir : "/tmp";
}
static inline void simrund_socket_path(char *buf, size_t n) {
  const char *o = getenv("SIMRUND_SOCKET");
  if (o) { snprintf(buf, n, "%s", o); return; }
  snprintf(buf, n, "%s/Library/Developer/SimRun/simrund.sock", simrund_home());
}
// Unix socket paths are limited to sizeof(sun_path) - 1 (103) bytes; a longer SIMRUND_SOCKET would be silently
// truncated by strlcpy (and the truncated file then left behind). Returns 0 if the path fits.
static inline int simrund_socket_addr(const char *path, struct sockaddr_un *a) {
  memset(a, 0, sizeof *a); a->sun_family = AF_UNIX;
  if (strlen(path) >= sizeof a->sun_path) { fprintf(stderr, "simrun: socket path too long (max %zu bytes): %s\n", sizeof a->sun_path - 1, path); return -1; }
  strlcpy(a->sun_path, path, sizeof a->sun_path); return 0;
}
static inline void simrund_log_path(char *buf, size_t n) {
  char dir[1024]; snprintf(dir, sizeof dir, "%s/Library/Logs/SimRun", simrund_home());
  mkdir(dir, 0755);
  snprintf(buf, n, "%s/simrund.log", dir);
}

static inline int simrund_write_all(int fd, const void *p, size_t n) {
  while (n) { ssize_t w = write(fd, p, n); if (w <= 0) return -1; p = (const char *)p + w; n -= (size_t)w; }
  return 0;
}
static inline int simrund_read_all(int fd, void *p, size_t n) {
  while (n) { ssize_t r = read(fd, p, n); if (r <= 0) return -1; p = (char *)p + r; n -= (size_t)r; }
  return 0;
}

// Sends one message; if fds != NULL, attaches nfds descriptors to it.
static inline int simrund_send(int sock, CFDictionaryRef dict, const int *fds, int nfds) {
  CFDataRef data = CFPropertyListCreateData(NULL, dict, kCFPropertyListBinaryFormat_v1_0, 0, NULL);
  if (!data) return -1;
  uint32_t len = (uint32_t)CFDataGetLength(data);
  int rc;
  if (fds && nfds > 0) {
    struct iovec iov = { &len, sizeof len };
    char ctl[CMSG_SPACE(sizeof(int) * 3)] = {0};
    struct msghdr mh = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = ctl, .msg_controllen = (socklen_t)CMSG_SPACE(sizeof(int) * nfds) };
    struct cmsghdr *c = CMSG_FIRSTHDR(&mh);
    c->cmsg_level = SOL_SOCKET; c->cmsg_type = SCM_RIGHTS; c->cmsg_len = (socklen_t)CMSG_LEN(sizeof(int) * nfds);
    memcpy(CMSG_DATA(c), fds, sizeof(int) * nfds);
    rc = sendmsg(sock, &mh, 0) == (ssize_t)sizeof len ? 0 : -1;
  } else rc = simrund_write_all(sock, &len, sizeof len);
  if (rc == 0) rc = simrund_write_all(sock, CFDataGetBytePtr(data), len);
  CFRelease(data);
  return rc;
}

// Receives one message (caller releases). Received descriptors (if any) go to fds[0..*nfds), up to 3.
static inline CFDictionaryRef simrund_recv(int sock, int *fds, int *nfds) {
  uint32_t len = 0;
  struct iovec iov = { &len, sizeof len };
  char ctl[CMSG_SPACE(sizeof(int) * 3)] = {0};
  struct msghdr mh = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = ctl, .msg_controllen = sizeof ctl };
  ssize_t r = recvmsg(sock, &mh, MSG_WAITALL);
  if (nfds) *nfds = 0;
  if (r != (ssize_t)sizeof len) return NULL;
  for (struct cmsghdr *c = CMSG_FIRSTHDR(&mh); c; c = CMSG_NXTHDR(&mh, c))
    if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS && fds && nfds) {
      int n = (int)((c->cmsg_len - CMSG_LEN(0)) / sizeof(int)); if (n > 3) n = 3;
      memcpy(fds, CMSG_DATA(c), sizeof(int) * n); *nfds = n;
    }
  if (len == 0 || len > (64u << 20)) return NULL;
  UInt8 *buf = malloc(len);
  if (simrund_read_all(sock, buf, len)) { free(buf); return NULL; }
  CFDataRef data = CFDataCreateWithBytesNoCopy(NULL, buf, len, kCFAllocatorMalloc);
  CFPropertyListRef pl = CFPropertyListCreateWithData(NULL, data, kCFPropertyListImmutable, NULL, NULL);
  CFRelease(data);
  if (pl && CFGetTypeID(pl) != CFDictionaryGetTypeID()) { CFRelease(pl); pl = NULL; }
  return (CFDictionaryRef)pl;
}
