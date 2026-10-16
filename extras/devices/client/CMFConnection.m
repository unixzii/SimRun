#import "CMFConnection.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#if TARGET_OS_SIMULATOR

// Per-user namespace belongs to the in-process SimRun device service.
static const char *cmf_socket_path(void) {
    static char path[104];
    static dispatch_once_t once;
    dispatch_once(&once, ^{ snprintf(path, sizeof(path), "/tmp/simrun-camera-%u.sock", getuid()); });
    return path;
}
static int gSockFd = -1;
static dispatch_queue_t gReadQueue;
static dispatch_queue_t gWriteQueue;
static CMFMessageHandler gMessageHandler;
static CMFStateHandler gStateHandler;
static BOOL gConnected = NO;
static BOOL gReconnectDisabled = NO;
static NSString *gPendingDisconnectReason;
static dispatch_source_t gReconnectTimer;

static void cmf_cancel_reconnect_timer(void);
static void cmf_schedule_reconnect(void);
static void cmf_handle_disconnect(int fd);
static void cmf_start_reader(int fd);

static int cmf_find_newline(NSData *data) {
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) {
        if (bytes[i] == '\n') {
            return (int)i;
        }
    }
    return -1;
}

static void cmf_handle_line(NSData *line) {
    if (line.length == 0) {
        return;
    }
    NSError *error = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:line options:0 error:&error];
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *msg = (NSDictionary *)obj;
        NSLog(@"CAMouflage: recv type=%@", msg[@"type"]);
        if ([msg[@"type"] isEqualToString:@"connectionRejected"] &&
            [msg[@"code"] isEqualToString:@"clientBusy"]) {
            gReconnectDisabled = YES;
            gPendingDisconnectReason = msg[@"message"] ?: @"provider rejected this process as an additional client";
            cmf_cancel_reconnect_timer();
            NSLog(@"CAMouflage: second client rejected — %@; auto-reconnect disabled", gPendingDisconnectReason);
        }
        if (gMessageHandler) {
            gMessageHandler(msg);
        }
    }
}

static void cmf_set_connected(BOOL connected) {
    if (gConnected == connected) return;
    gConnected = connected;
    if (connected) {
        NSLog(@"CAMouflage: socket connected");
    }
    CMFStateHandler handler = gStateHandler;
    if (handler) {
        handler(connected);
    }
}

static void cmf_start_reader(int fd) {
    if (gReadQueue) {
        return;
    }
    gReadQueue = dispatch_queue_create("camouflage.reader", DISPATCH_QUEUE_SERIAL);
    dispatch_async(gReadQueue, ^{
        NSMutableData *buffer = [NSMutableData data];
        while (1) {
            uint8_t tmp[2048];
            ssize_t n = read(fd, tmp, sizeof(tmp));
            if (n <= 0) {
                break;
            }
            [buffer appendBytes:tmp length:(NSUInteger)n];
            while (1) {
                int idx = cmf_find_newline(buffer);
                if (idx < 0) {
                    break;
                }
                NSData *line = [buffer subdataWithRange:NSMakeRange(0, (NSUInteger)idx)];
                [buffer replaceBytesInRange:NSMakeRange(0, (NSUInteger)idx + 1) withBytes:NULL length:0];
                cmf_handle_line(line);
            }
        }
        cmf_handle_disconnect(fd);
    });
}

static BOOL cmf_write_all(int fd, const void *bytes, size_t length) {
    const uint8_t *ptr = (const uint8_t *)bytes;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t written = write(fd, ptr, remaining);
        if (written <= 0) {
            return NO;
        }
        ptr += (size_t)written;
        remaining -= (size_t)written;
    }
    return YES;
}

static int cmf_try_connect(void) {
    if (gSockFd >= 0) {
        return gSockFd;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, cmf_socket_path(), sizeof(addr.sun_path) - 1);

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
#ifdef SO_NOSIGPIPE
    int suppressSIGPIPE = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &suppressSIGPIPE, sizeof(suppressSIGPIPE));
#endif
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
        gSockFd = fd;
        cmf_start_reader(fd);
        cmf_set_connected(YES);
        return fd;
    }
    close(fd);
    return -1;
}

static int cmf_connect(void) {
    if (gReconnectDisabled) {
        NSLog(@"CAMouflage: connect suppressed — previous connection was rejected as an additional client");
        return -1;
    }
    if (gSockFd >= 0) {
        return gSockFd;
    }
    // Retry a few times in case the provider is still starting up.
    for (int attempt = 0; attempt < 5; attempt++) {
        int fd = cmf_try_connect();
        if (fd >= 0) return fd;
        if (attempt < 4) {
            usleep(200000);
        }
    }
    NSLog(@"CAMouflage: connect(%s) failed after retries", cmf_socket_path());
    cmf_schedule_reconnect();
    return -1;
}

static void cmf_handle_disconnect(int fd) {
    if (!gWriteQueue) {
        gWriteQueue = dispatch_queue_create("camouflage.writer", DISPATCH_QUEUE_SERIAL);
    }
    dispatch_async(gWriteQueue, ^{
        if (gSockFd != fd) {
            return;
        }
        close(gSockFd);
        gSockFd = -1;
        gReadQueue = nil;
        NSString *reason = gPendingDisconnectReason;
        gPendingDisconnectReason = nil;
        if (reason.length > 0) {
            NSLog(@"CAMouflage: socket disconnected (%@)", reason);
        } else {
            NSLog(@"CAMouflage: socket disconnected (provider closed connection)");
        }
        cmf_set_connected(NO);
        if (!gReconnectDisabled) {
            cmf_schedule_reconnect();
        }
    });
}

static void cmf_cancel_reconnect_timer(void) {
    if (!gReconnectTimer) return;
    dispatch_source_cancel(gReconnectTimer);
    gReconnectTimer = nil;
}

static void cmf_schedule_reconnect(void) {
    if (gReconnectDisabled) return;
    if (gReconnectTimer) return;
    if (!gWriteQueue) {
        gWriteQueue = dispatch_queue_create("camouflage.writer", DISPATCH_QUEUE_SERIAL);
    }
    gReconnectTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gWriteQueue);
    dispatch_source_set_timer(gReconnectTimer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(gReconnectTimer, ^{
        if (gReconnectDisabled) {
            cmf_cancel_reconnect_timer();
            return;
        }
        if (gSockFd >= 0) {
            cmf_cancel_reconnect_timer();
            return;
        }
        int fd = cmf_try_connect();
        if (fd >= 0) {
            cmf_cancel_reconnect_timer();
        }
    });
    dispatch_resume(gReconnectTimer);
}

void CMFConnectionSetMessageHandler(CMFMessageHandler handler) {
    gMessageHandler = [handler copy];
}

void CMFConnectionSetStateHandler(CMFStateHandler handler) {
    gStateHandler = [handler copy];
}

BOOL CMFConnectionIsConnected(void) {
    return gConnected;
}

void CMFConnectionOpen(void) {
    if (!gWriteQueue) {
        gWriteQueue = dispatch_queue_create("camouflage.writer", DISPATCH_QUEUE_SERIAL);
    }
    dispatch_async(gWriteQueue, ^{
        if (gReconnectDisabled) return;
        if (gSockFd >= 0) return;
        if (cmf_try_connect() < 0) {
            cmf_schedule_reconnect();
        }
    });
}

void CMFConnectionSend(NSDictionary *msg) {
    if (!gWriteQueue) {
        gWriteQueue = dispatch_queue_create("camouflage.writer", DISPATCH_QUEUE_SERIAL);
    }
    dispatch_async(gWriteQueue, ^{
        int fd = cmf_connect();
        if (fd < 0) {
            NSLog(@"CAMouflage: send failed — not connected");
            return;
        }
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:msg options:0 error:&error];
        if (!data) {
            NSLog(@"CAMouflage: send failed — JSON error: %@", error);
            return;
        }
        if (!cmf_write_all(fd, data.bytes, data.length) || !cmf_write_all(fd, "\n", 1)) {
            NSLog(@"CAMouflage: send failed — socket write error");
            cmf_handle_disconnect(fd);
            return;
        }
    });
}

#else

void CMFConnectionSetMessageHandler(CMFMessageHandler handler) {}
void CMFConnectionSetStateHandler(CMFStateHandler handler) {}
void CMFConnectionSend(NSDictionary *msg) {}
void CMFConnectionOpen(void) {}
BOOL CMFConnectionIsConnected(void) { return NO; }

#endif
