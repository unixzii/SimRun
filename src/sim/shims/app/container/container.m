// container — app.dylib module: the app's data container as its sandbox container (SIM platform).
// Apps run unsandboxed, so the kernel has no container for them and sandbox_container_path_for_pid() fails. Apple's apps
// ask it where their container is (Safari's SafariCore, then LaunchServices' dataContainerURL, which is nil here too)
// and crash on the nil path. The container is the app's HOME (its data container, set by SimRun), so answer that for
// our own process.
// Env: CONTAINER_VERBOSE=1.
#import <Foundation/Foundation.h>
#import "app.h"

static int gVerbose;
#define LOG(...) do { if (gVerbose) fprintf(stderr, "[container] " __VA_ARGS__); } while (0)

int sandbox_container_path_for_pid(pid_t pid, char *buf, size_t size);
static int my_sandbox_container_path_for_pid(pid_t pid, char *buf, size_t size) {
  const char *home = getenv("HOME");
  if (SRModuleOn(SRModuleContainer) && (pid == 0 || pid == getpid()) && home && *home) {
    size_t n = strlen(home);
    if (!buf || n >= size) {
      errno = ERANGE;
      return -1;
    }
    memcpy(buf, home, n + 1);
    LOG("sandbox_container_path_for_pid(%d) -> %s\n", pid, home);
    return 0;
  }
  return sandbox_container_path_for_pid(pid, buf, size);
}

__attribute__((used, section("__DATA,__interpose"))) static struct {
  const void *n, *o;
} interposers[] = {
  { (const void *)my_sandbox_container_path_for_pid, (const void *)sandbox_container_path_for_pid },
};

void SRContainerStart(void) {
  gVerbose = getenv("CONTAINER_VERBOSE") != NULL;
}
