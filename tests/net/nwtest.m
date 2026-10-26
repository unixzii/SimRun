#import <Foundation/Foundation.h>
#import <Network/Network.h>
static void try(const char *host, const char *port, bool tls) {
  nw_parameters_t p = tls ? nw_parameters_create_secure_tcp(NW_PARAMETERS_DEFAULT_CONFIGURATION, NW_PARAMETERS_DEFAULT_CONFIGURATION)
                          : nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
  nw_connection_t c = nw_connection_create(nw_endpoint_create_host(host, port), p);
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  __block bool done = false;
  nw_connection_set_queue(c, dispatch_get_global_queue(0, 0));
  nw_connection_set_state_changed_handler(c, ^(nw_connection_state_t st, nw_error_t err) {
    const char *n[] = {"invalid", "waiting", "preparing", "ready", "failed", "cancelled"};
    printf("[nw] %s:%s%s -> %s", host, port, tls ? " (TLS)" : "", n[st]);
    if (err) {
      printf(" err=%d domain=%d", nw_error_get_error_code(err), nw_error_get_error_domain(err));
    }
    printf("\n");
    if ((st == nw_connection_state_ready || st == nw_connection_state_failed || st == nw_connection_state_waiting) && !done) {
      done = true;
      dispatch_semaphore_signal(sem);
    }
  });
  nw_connection_start(c);
  if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC))) {
    printf("[nw] %s:%s -> TIMEOUT (stuck preparing)\n", host, port);
  }
  nw_connection_cancel(c);
}
int main() {
  setvbuf(stdout, NULL, _IONBF, 0);
  try("1.1.1.1", "80", false);
  try("example.com", "80", false);
  try("example.com", "443", true);
}
