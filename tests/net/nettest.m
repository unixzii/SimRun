// nettest: which layer of networking works in a SimRun process?
#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <errno.h>
static void tcp_ip(const char *ip, int port) {
  int s = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in a = { .sin_len = sizeof a, .sin_family = AF_INET, .sin_port = htons(port) };
  inet_pton(AF_INET, ip, &a.sin_addr);
  int r = connect(s, (struct sockaddr *)&a, sizeof a);
  printf("[net] connect %s:%d -> %s\n", ip, port, r == 0 ? "OK" : strerror(errno));
  close(s);
}
static void gai(const char *host) {
  struct addrinfo hints = { .ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM }, *res = NULL;
  int r = getaddrinfo(host, "80", &hints, &res);
  if (r) {
    printf("[net] getaddrinfo %s -> %s\n", host, gai_strerror(r));
    return;
  }
  char buf[64];
  struct sockaddr_in *sin = (struct sockaddr_in *)res->ai_addr;
  printf("[net] getaddrinfo %s -> OK %s\n", host, res->ai_family == AF_INET ? inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof buf) : "(v6)");
  int s = socket(res->ai_family, SOCK_STREAM, 0);
  int c = connect(s, res->ai_addr, res->ai_addrlen);
  printf("[net] connect %s -> %s\n", host, c == 0 ? "OK" : strerror(errno));
  close(s);
  freeaddrinfo(res);
}
int main() {
  @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0);
    tcp_ip("1.1.1.1", 80);
    gai("localhost");
    gai("example.com");
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:@"https://example.com/"] completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
      printf("[net] URLSession -> %s\n", e ? e.description.UTF8String : [NSString stringWithFormat:@"HTTP %ld, %lu bytes", (long)((NSHTTPURLResponse *)r).statusCode, (unsigned long)d.length].UTF8String);
      dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
  }
}
