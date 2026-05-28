// slirpnet — libslirp glue for vmfast-linux. See slirpnet.h for the
// contract. All libslirp entry points are serialized behind s->lock;
// the poll thread sleeps in poll() until either a socket is ready, a
// TCP timer is due, or slnet_tx/notify pokes the self-pipe.
#include "slirpnet.h"

#include <libslirp.h>
#include <pthread.h>
#include <poll.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>
#include <fcntl.h>
#include <arpa/inet.h>

struct slnet {
    Slirp *slirp;
    pthread_mutex_t lock;
    pthread_t thread;
    int running;

    // Self-pipe: libslirp's notify() and our slnet_tx() write a byte to
    // wake the poll thread so newly-readable sockets / freshly-injected
    // input get serviced without waiting out the poll timeout.
    int wake_rd, wake_wr;

    slnet_deliver_fn deliver;
    void *ctx;

    // Scratch pollfd array rebuilt every poll iteration.
    struct pollfd *pfds;
    int npfds, cap_pfds;
};

// ── libslirp callbacks ───────────────────────────────────────────────

static int64_t clock_get_ns_cb(void *opaque) {
    (void)opaque;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static slirp_ssize_t send_packet_cb(const void *buf, size_t len, void *opaque) {
    struct slnet *s = (struct slnet *)opaque;
    s->deliver((const uint8_t *)buf, len, s->ctx);
    return (slirp_ssize_t)len;
}

static void guest_error_cb(const char *msg, void *opaque) {
    (void)msg; (void)opaque;   // guest misbehavior — ignore for a demo
}

static void notify_cb(void *opaque) {
    struct slnet *s = (struct slnet *)opaque;
    char b = 1;
    ssize_t r = write(s->wake_wr, &b, 1);
    (void)r;
}

// IPv6 RA is libslirp's only timer user and we disable IPv6, so these
// never actually fire — but they must be non-NULL and not crash.
static void *timer_new_cb(SlirpTimerCb cb, void *cb_opaque, void *opaque) {
    (void)cb; (void)cb_opaque; (void)opaque;
    return calloc(1, 1);
}
static void timer_free_cb(void *timer, void *opaque) { (void)opaque; free(timer); }
static void timer_mod_cb(void *timer, int64_t e, void *opaque) {
    (void)timer; (void)e; (void)opaque;
}
// Deprecated, but this libslirp build still invokes them, so provide
// no-op stubs (leaving them NULL hangs slirp_new on this version).
static void register_poll_fd_cb(int fd, void *opaque)   { (void)fd; (void)opaque; }
static void unregister_poll_fd_cb(int fd, void *opaque) { (void)fd; (void)opaque; }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static const SlirpCb g_callbacks = {
    .send_packet       = send_packet_cb,
    .guest_error       = guest_error_cb,
    .clock_get_ns      = clock_get_ns_cb,
    .timer_new         = timer_new_cb,
    .timer_free        = timer_free_cb,
    .timer_mod         = timer_mod_cb,
    .register_poll_fd  = register_poll_fd_cb,
    .unregister_poll_fd= unregister_poll_fd_cb,
    .notify            = notify_cb,
};
#pragma clang diagnostic pop

// ── poll loop ────────────────────────────────────────────────────────

static int add_poll_cb(slirp_os_socket fd, int events, void *opaque) {
    struct slnet *s = (struct slnet *)opaque;
    if (s->npfds >= s->cap_pfds) {
        s->cap_pfds = s->cap_pfds ? s->cap_pfds * 2 : 16;
        s->pfds = (struct pollfd *)realloc(s->pfds, s->cap_pfds * sizeof(struct pollfd));
    }
    short ev = 0;
    if (events & SLIRP_POLL_IN)  ev |= POLLIN;
    if (events & SLIRP_POLL_OUT) ev |= POLLOUT;
    if (events & SLIRP_POLL_PRI) ev |= POLLPRI;
    if (events & SLIRP_POLL_ERR) ev |= POLLERR;
    if (events & SLIRP_POLL_HUP) ev |= POLLHUP;
    s->pfds[s->npfds].fd = fd;
    s->pfds[s->npfds].events = ev;
    s->pfds[s->npfds].revents = 0;
    return s->npfds++;
}

static int get_revents_cb(int idx, void *opaque) {
    struct slnet *s = (struct slnet *)opaque;
    short re = s->pfds[idx].revents;
    int r = 0;
    if (re & POLLIN)  r |= SLIRP_POLL_IN;
    if (re & POLLOUT) r |= SLIRP_POLL_OUT;
    if (re & POLLPRI) r |= SLIRP_POLL_PRI;
    if (re & POLLERR) r |= SLIRP_POLL_ERR;
    if (re & POLLHUP) r |= SLIRP_POLL_HUP;
    return r;
}

static void *poll_thread(void *arg) {
    struct slnet *s = (struct slnet *)arg;
    while (s->running) {
        s->npfds = 0;

        pthread_mutex_lock(&s->lock);
        uint32_t timeout = ~0u;   // UINT32_MAX → "infinite" to slirp
        slirp_pollfds_fill_socket(s->slirp, &timeout, add_poll_cb, s);
        pthread_mutex_unlock(&s->lock);

        // Always watch the wake pipe so notify()/slnet_tx() can break us
        // out of poll() promptly.
        int wake_idx = add_poll_cb(s->wake_rd, SLIRP_POLL_IN, s);

        int to = (timeout == ~0u) ? -1 : (int)timeout;
        // Cap the wait so libslirp's TCP retransmit/keepalive timers,
        // which it services inside slirp_pollfds_poll, still tick even
        // when nothing else is happening.
        if (to < 0 || to > 1000) to = 1000;

        int n = poll(s->pfds, s->npfds, to);
        int err = (n < 0) ? 1 : 0;

        if (s->pfds[wake_idx].revents & POLLIN) {
            char buf[64];
            while (read(s->wake_rd, buf, sizeof buf) > 0) { }
        }

        pthread_mutex_lock(&s->lock);
        slirp_pollfds_poll(s->slirp, err, get_revents_cb, s);
        pthread_mutex_unlock(&s->lock);
    }
    return NULL;
}

// ── public API ───────────────────────────────────────────────────────

void *slnet_start(slnet_deliver_fn deliver, void *ctx) {
    struct slnet *s = (struct slnet *)calloc(1, sizeof *s);
    if (!s) return NULL;
    s->deliver = deliver;
    s->ctx = ctx;
    pthread_mutex_init(&s->lock, NULL);

    int fds[2];
    if (pipe(fds) != 0) { free(s); return NULL; }
    s->wake_rd = fds[0];
    s->wake_wr = fds[1];
    fcntl(s->wake_rd, F_SETFL, O_NONBLOCK);
    fcntl(s->wake_wr, F_SETFL, O_NONBLOCK);

    SlirpConfig cfg;
    memset(&cfg, 0, sizeof cfg);
    cfg.version              = 1;
    cfg.restricted           = 0;
    cfg.in_enabled           = true;
    cfg.vnetwork.s_addr      = htonl(0x0a000200);  // 10.0.2.0
    cfg.vnetmask.s_addr      = htonl(0xffffff00);  // /24
    cfg.vhost.s_addr         = htonl(0x0a000202);  // 10.0.2.2 (gateway)
    cfg.in6_enabled          = false;
    cfg.vdhcp_start.s_addr   = htonl(0x0a00020f);  // 10.0.2.15
    cfg.vnameserver.s_addr   = htonl(0x0a000203);  // 10.0.2.3
    cfg.if_mtu               = 0;                  // libslirp default (1500)
    cfg.if_mru               = 0;
    cfg.disable_host_loopback= false;
    cfg.enable_emu           = false;

    s->slirp = slirp_new(&cfg, &g_callbacks, s);
    if (!s->slirp) { close(s->wake_rd); close(s->wake_wr); free(s); return NULL; }

    s->running = 1;
    if (pthread_create(&s->thread, NULL, poll_thread, s) != 0) {
        slirp_cleanup(s->slirp);
        close(s->wake_rd); close(s->wake_wr); free(s);
        return NULL;
    }
    return s;
}

int slnet_hostfwd(void *handle, int host_port, int guest_port) {
    struct slnet *s = (struct slnet *)handle;
    struct in_addr haddr, gaddr;
    haddr.s_addr = htonl(0x7f000001);   // 127.0.0.1
    gaddr.s_addr = htonl(0x0a00020f);   // 10.0.2.15
    pthread_mutex_lock(&s->lock);
    int r = slirp_add_hostfwd(s->slirp, 0 /*TCP*/, haddr, host_port, gaddr, guest_port);
    pthread_mutex_unlock(&s->lock);
    return r;
}

void slnet_tx(void *handle, const uint8_t *frame, size_t len) {
    struct slnet *s = (struct slnet *)handle;
    pthread_mutex_lock(&s->lock);
    slirp_input(s->slirp, frame, (int)len);
    pthread_mutex_unlock(&s->lock);
    // slirp_input may have queued replies / changed socket interest;
    // poke the poll thread so it re-evaluates immediately.
    char b = 1;
    ssize_t w = write(s->wake_wr, &b, 1);
    (void)w;
}
