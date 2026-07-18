#include <arpa/inet.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <netdb.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static void trace(const char *operation) {
    const char *path = getenv("TYPE_WAVE_NETWORK_TRACE");
    if (path == NULL) return;
    const char *run = getenv("TYPE_WAVE_NETWORK_RUN_ID");
    if (run == NULL) run = "missing";
    char process[128] = "unknown";
    getprogname() && snprintf(process, sizeof(process), "%s", getprogname());
    char line[256];
    int length = snprintf(line, sizeof(line), "run=%s pid=%d process=%s operation=%s\n", run, getpid(), process, operation);
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd >= 0) {
        (void)write(fd, line, (size_t)length);
        (void)close(fd);
    }
}

__attribute__((constructor)) static void loaded(void) { trace("instrumentation_loaded"); }

int traced_socket(int domain, int type, int protocol) {
    trace("socket");
    int (*next)(int, int, int) = dlsym(RTLD_NEXT, "socket");
    return next(domain, type, protocol);
}

int traced_connect(int socket_fd, const struct sockaddr *address, socklen_t length) {
    trace("connect");
    int (*next)(int, const struct sockaddr *, socklen_t) = dlsym(RTLD_NEXT, "connect");
    return next(socket_fd, address, length);
}

ssize_t traced_sendto(int socket_fd, const void *buffer, size_t length, int flags,
                      const struct sockaddr *address, socklen_t address_length) {
    trace("sendto");
    ssize_t (*next)(int, const void *, size_t, int, const struct sockaddr *, socklen_t) =
        dlsym(RTLD_NEXT, "sendto");
    return next(socket_fd, buffer, length, flags, address, address_length);
}

int traced_getaddrinfo(const char *node, const char *service,
                       const struct addrinfo *hints, struct addrinfo **result) {
    trace("getaddrinfo");
    int (*next)(const char *, const char *, const struct addrinfo *, struct addrinfo **) =
        dlsym(RTLD_NEXT, "getaddrinfo");
    return next(node, service, hints, result);
}

#define DYLD_INTERPOSE(_replacement, _replacee)                                    \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
        _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = {   \
            (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee };

DYLD_INTERPOSE(traced_socket, socket)
DYLD_INTERPOSE(traced_connect, connect)
DYLD_INTERPOSE(traced_sendto, sendto)
DYLD_INTERPOSE(traced_getaddrinfo, getaddrinfo)
