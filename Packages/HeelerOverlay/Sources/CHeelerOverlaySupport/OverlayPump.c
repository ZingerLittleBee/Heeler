#include "CHeelerOverlaySupport.h"

#include <CZeroTier/ZeroTierSockets.h>
#include <CZeroTier/heeler_zerotier.h>

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

/* Bytes buffered per direction. */
#define PUMP_BUFFER_SIZE (64 * 1024)
/*
 * The pump waits on one side at a time, so a byte arriving on the side not
 * being waited on is noticed at the end of the current slice. The slice
 * adapts: right after traffic it is PUMP_WAIT_SLICE_MIN_MS, keeping
 * interactive latency negligible, and it doubles with each idle round up to
 * PUMP_WAIT_SLICE_MAX_MS. An idle stream therefore costs about 40 wakeups a
 * second, and the first byte after a long pause can wait at most one
 * maximum slice (25 ms) before the pump sees it; every byte after that moves
 * at the minimum slice again.
 */
#define PUMP_WAIT_SLICE_MIN_MS 1
#define PUMP_WAIT_SLICE_MAX_MS 25
/*
 * How long a side may keep reporting readiness without any byte moving
 * before the pump gives up. libzt's zts_errno is a process-wide global, so a
 * failed lwIP call cannot be classified reliably and a stall budget stands
 * in for it. It is measured on the wall clock and set well above TCP's
 * maximum retransmission timeout (60 s), so a slow but healthy connection is
 * never cut; while stalled the pump sleeps a full slice per round instead of
 * spinning.
 */
#define PUMP_STALL_BUDGET_MS 90000
/* After one side fails, how long the pump keeps delivering what it already
 * buffered from that side to the other before closing both. */
#define PUMP_DRAIN_BUDGET_MS 2000
/* Longest single wait while connecting, so cancellation is noticed. */
#define CONNECT_SLICE_MS 50

static long long monotonic_ms(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (long long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

enum {
    READY_READ = 1,
    READY_WRITE = 2,
    READY_ERROR = 4,
};

enum {
    IO_WOULD_BLOCK = -1,
    IO_FAILED = -2,
};

/* One side of the pump. recv returns bytes, 0 for EOF, or an IO_* code;
 * send returns bytes or an IO_* code; wait returns a READY_* mask (0 on
 * timeout). */
typedef struct {
    ssize_t (*recv)(int fd, void *buffer, size_t length);
    ssize_t (*send)(int fd, const void *buffer, size_t length);
    int (*wait)(int fd, int want_read, int want_write, int timeout_ms);
    void (*shutdown_write)(int fd);
    void (*close)(int fd);
} endpoint_ops;

struct heeler_overlay_pump {
    atomic_int references;
    atomic_int stop;
    int local_fd;
    int remote_fd;
    const endpoint_ops *remote_ops;
    /* Test fault injection: sends to the remote side report would-block,
     * despite readiness, until this monotonic time. */
    long long remote_send_blocked_until_ms;
};

struct heeler_overlay_cancel {
    atomic_int flag;
};

static atomic_int live_pumps;

// MARK: - Cancellation

heeler_overlay_cancel *heeler_overlay_cancel_create(void) {
    heeler_overlay_cancel *cancel = calloc(1, sizeof(*cancel));
    if (cancel != NULL) {
        atomic_init(&cancel->flag, 0);
    }
    return cancel;
}

void heeler_overlay_cancel_set(heeler_overlay_cancel *cancel) {
    if (cancel != NULL) {
        atomic_store(&cancel->flag, 1);
    }
}

int heeler_overlay_cancel_is_set(const heeler_overlay_cancel *cancel) {
    return cancel != NULL && atomic_load(&((heeler_overlay_cancel *)cancel)->flag) != 0;
}

void heeler_overlay_cancel_destroy(heeler_overlay_cancel *cancel) {
    free(cancel);
}

// MARK: - POSIX endpoint

static ssize_t posix_recv(int fd, void *buffer, size_t length) {
    for (;;) {
        ssize_t received = recv(fd, buffer, length, MSG_DONTWAIT);
        if (received >= 0) {
            return received;
        }
        if (errno == EINTR) {
            continue;
        }
        return (errno == EAGAIN || errno == EWOULDBLOCK) ? IO_WOULD_BLOCK : IO_FAILED;
    }
}

static ssize_t posix_send(int fd, const void *buffer, size_t length) {
    for (;;) {
        ssize_t sent = send(fd, buffer, length, MSG_DONTWAIT);
        if (sent >= 0) {
            return sent;
        }
        if (errno == EINTR) {
            continue;
        }
        return (errno == EAGAIN || errno == EWOULDBLOCK) ? IO_WOULD_BLOCK : IO_FAILED;
    }
}

static int posix_wait(int fd, int want_read, int want_write, int timeout_ms) {
    struct pollfd descriptor = {
        .fd = fd,
        .events = (short)((want_read ? POLLIN : 0) | (want_write ? POLLOUT : 0)),
        .revents = 0,
    };
    int result = poll(&descriptor, 1, timeout_ms);
    if (result < 0) {
        return errno == EINTR ? 0 : READY_ERROR;
    }
    if (result == 0) {
        return 0;
    }
    int ready = 0;
    if (descriptor.revents & POLLIN) {
        ready |= READY_READ;
    }
    if (descriptor.revents & POLLOUT) {
        ready |= READY_WRITE;
    }
    if (descriptor.revents & (POLLERR | POLLNVAL)) {
        ready |= READY_ERROR;
    }
    if (descriptor.revents & POLLHUP) {
        /* Darwin reports a peer's write shutdown as POLLIN|POLLHUP, so a
         * read finds the EOF. Hang-up without readable interest means the
         * peer is gone entirely and nothing more can be written to it. */
        ready |= want_read ? READY_READ : READY_ERROR;
    }
    return ready;
}

static void posix_shutdown_write(int fd) {
    shutdown(fd, SHUT_WR);
}

static void posix_close(int fd) {
    close(fd);
}

static const endpoint_ops posix_ops = {
    .recv = posix_recv,
    .send = posix_send,
    .wait = posix_wait,
    .shutdown_write = posix_shutdown_write,
    .close = posix_close,
};

// MARK: - libzt endpoint

static ssize_t zt_recv(int fd, void *buffer, size_t length) {
    ssize_t received = zts_bsd_recv(fd, buffer, length, ZTS_MSG_DONTWAIT);
    if (received >= 0) {
        return received;
    }
    /* -1 is a socket error whose cause zts_errno cannot report reliably;
     * other negative values are libzt service errors. */
    return received == -1 ? IO_WOULD_BLOCK : IO_FAILED;
}

static ssize_t zt_send(int fd, const void *buffer, size_t length) {
    ssize_t sent = zts_bsd_send(fd, buffer, length, ZTS_MSG_DONTWAIT);
    if (sent >= 0) {
        return sent;
    }
    return sent == -1 ? IO_WOULD_BLOCK : IO_FAILED;
}

static int zt_wait(int fd, int want_read, int want_write, int timeout_ms) {
    struct zts_pollfd descriptor = {
        .fd = fd,
        .events = (short)((want_read ? ZTS_POLLIN : 0) | (want_write ? ZTS_POLLOUT : 0)),
        .revents = 0,
    };
    int result = zts_bsd_poll(&descriptor, 1, timeout_ms);
    if (result < 0) {
        return READY_ERROR;
    }
    if (result == 0) {
        return 0;
    }
    int ready = 0;
    if (descriptor.revents & ZTS_POLLIN) {
        ready |= READY_READ;
    }
    if (descriptor.revents & ZTS_POLLOUT) {
        ready |= READY_WRITE;
    }
    if (descriptor.revents & (ZTS_POLLERR | ZTS_POLLNVAL | ZTS_POLLHUP)) {
        ready |= READY_ERROR;
    }
    return ready;
}

static void zt_shutdown_write(int fd) {
    zts_bsd_shutdown(fd, ZTS_SHUT_WR);
}

static void zt_close(int fd) {
    zts_bsd_close(fd);
}

static const endpoint_ops zt_ops = {
    .recv = zt_recv,
    .send = zt_send,
    .wait = zt_wait,
    .shutdown_write = zt_shutdown_write,
    .close = zt_close,
};

// MARK: - Pump

typedef struct {
    unsigned char data[PUMP_BUFFER_SIZE];
    size_t start;
    size_t end;
} pump_buffer;

typedef struct {
    const endpoint_ops *ops;
    int fd;
    int read_eof;
    int write_shut;
    long long send_blocked_until_ms;
} pump_endpoint;

static size_t buffer_pending(const pump_buffer *buffer) {
    return buffer->end - buffer->start;
}

static size_t buffer_space(pump_buffer *buffer) {
    if (buffer->start == buffer->end) {
        buffer->start = 0;
        buffer->end = 0;
    } else if (buffer->end == PUMP_BUFFER_SIZE && buffer->start > 0) {
        memmove(buffer->data, buffer->data + buffer->start, buffer->end - buffer->start);
        buffer->end -= buffer->start;
        buffer->start = 0;
    }
    return PUMP_BUFFER_SIZE - buffer->end;
}

static void pump_drop_reference(heeler_overlay_pump *pump) {
    if (atomic_fetch_sub(&pump->references, 1) == 1) {
        free(pump);
    }
}

static ssize_t endpoint_send(pump_endpoint *end, const void *buffer, size_t length) {
    if (end->send_blocked_until_ms > 0 && monotonic_ms() < end->send_blocked_until_ms) {
        return IO_WOULD_BLOCK;
    }
    return end->ops->send(end->fd, buffer, length);
}

/* After `source` failed, delivers what was already read from it to
 * `destination` for at most PUMP_DRAIN_BUDGET_MS, then shuts down the
 * destination's write side so the reader sees the stream end. */
static void pump_drain(heeler_overlay_pump *pump, pump_endpoint *destination, pump_buffer *buffer) {
    long long deadline = monotonic_ms() + PUMP_DRAIN_BUDGET_MS;
    while (!destination->write_shut && buffer_pending(buffer) > 0
           && !atomic_load(&pump->stop) && monotonic_ms() < deadline) {
        int ready = destination->ops->wait(destination->fd, 0, 1, PUMP_WAIT_SLICE_MAX_MS);
        if (ready & READY_ERROR) {
            return;
        }
        if (!(ready & READY_WRITE)) {
            continue;
        }
        ssize_t sent = endpoint_send(destination, buffer->data + buffer->start, buffer_pending(buffer));
        if (sent > 0) {
            buffer->start += (size_t)sent;
        } else if (sent == IO_FAILED) {
            return;
        } else {
            usleep(PUMP_WAIT_SLICE_MAX_MS * 1000);
        }
    }
    if (!destination->write_shut && buffer_pending(buffer) == 0) {
        destination->ops->shutdown_write(destination->fd);
        destination->write_shut = 1;
    }
}

/* Moves bytes until both directions have finished, either side fails, or
 * the owner asks the pump to stop. buffers[i] carries bytes read from
 * ends[i] and written to ends[1 - i]. */
static void pump_run(heeler_overlay_pump *pump, pump_endpoint ends[2], pump_buffer buffers[2]) {
    long long stalled_since = 0;
    int first_waiter = 0;
    int slice = PUMP_WAIT_SLICE_MIN_MS;

    while (!atomic_load(&pump->stop)) {
        int want_read[2];
        int want_write[2];
        for (int i = 0; i < 2; i++) {
            want_read[i] = !ends[i].read_eof && buffer_space(&buffers[i]) > 0;
            want_write[i] = !ends[i].write_shut && buffer_pending(&buffers[1 - i]) > 0;
        }

        int finished = 1;
        for (int i = 0; i < 2; i++) {
            if (!(ends[i].read_eof && buffer_pending(&buffers[i]) == 0 && ends[1 - i].write_shut)) {
                finished = 0;
            }
        }
        if (finished) {
            return;
        }

        int ready[2] = {0, 0};
        int any_ready = 0;
        for (int i = 0; i < 2; i++) {
            if (want_read[i] || want_write[i]) {
                ready[i] = ends[i].ops->wait(ends[i].fd, want_read[i], want_write[i], 0);
                any_ready |= ready[i];
            }
        }
        if (!any_ready) {
            int waited = 0;
            for (int step = 0; step < 2 && !any_ready && !atomic_load(&pump->stop); step++) {
                int i = (first_waiter + step) % 2;
                if (want_read[i] || want_write[i]) {
                    ready[i] = ends[i].ops->wait(ends[i].fd, want_read[i], want_write[i], slice);
                    any_ready |= ready[i];
                    waited = 1;
                }
            }
            first_waiter = 1 - first_waiter;
            if (!waited) {
                /* Nothing is wanted yet the pump has not finished; this
                 * should not happen, but never spin if it does. */
                usleep(PUMP_WAIT_SLICE_MAX_MS * 1000);
            }
            if (!any_ready) {
                slice = slice * 2 > PUMP_WAIT_SLICE_MAX_MS ? PUMP_WAIT_SLICE_MAX_MS : slice * 2;
                continue;
            }
        }

        int progressed = 0;
        int failed = -1;

        /* Read first, even from a side that also reports an error: lwIP and
         * Darwin both raise readable with the error, and those bytes are
         * the last the peer sent. */
        for (int i = 0; i < 2; i++) {
            if ((ready[i] & READY_READ) && want_read[i]) {
                pump_buffer *buffer = &buffers[i];
                size_t space = buffer_space(buffer);
                ssize_t received = ends[i].ops->recv(ends[i].fd, buffer->data + buffer->end, space);
                if (received > 0) {
                    buffer->end += (size_t)received;
                    progressed = 1;
                } else if (received == 0) {
                    ends[i].read_eof = 1;
                    progressed = 1;
                } else if (received == IO_FAILED && failed < 0) {
                    failed = i;
                }
            }
            if ((ready[i] & READY_ERROR) && failed < 0) {
                failed = i;
            }
        }

        for (int i = 0; i < 2; i++) {
            pump_buffer *buffer = &buffers[1 - i];
            if (i == failed) {
                continue;
            }
            if ((ready[i] & READY_WRITE) && !ends[i].write_shut && buffer_pending(buffer) > 0) {
                ssize_t sent = endpoint_send(&ends[i], buffer->data + buffer->start, buffer_pending(buffer));
                if (sent > 0) {
                    buffer->start += (size_t)sent;
                    progressed = 1;
                } else if (sent == IO_FAILED && failed < 0) {
                    failed = i;
                }
            }
        }

        if (failed >= 0) {
            /* The failed side can neither be read nor written any more;
             * hand the other side what it already sent, then stop. */
            pump_drain(pump, &ends[1 - failed], &buffers[failed]);
            return;
        }

        /* Forward a delivered EOF as a write shutdown on the other side. */
        for (int i = 0; i < 2; i++) {
            if (ends[i].read_eof && buffer_pending(&buffers[i]) == 0 && !ends[1 - i].write_shut) {
                ends[1 - i].ops->shutdown_write(ends[1 - i].fd);
                ends[1 - i].write_shut = 1;
                progressed = 1;
            }
        }

        if (progressed) {
            stalled_since = 0;
            slice = PUMP_WAIT_SLICE_MIN_MS;
        } else {
            /* Ready but nothing moved: wait a full slice rather than spin,
             * and give up only after the wall-clock stall budget. */
            long long now = monotonic_ms();
            if (stalled_since == 0) {
                stalled_since = now;
            } else if (now - stalled_since > PUMP_STALL_BUDGET_MS) {
                return;
            }
            slice = PUMP_WAIT_SLICE_MAX_MS;
            usleep(PUMP_WAIT_SLICE_MAX_MS * 1000);
        }
    }
}

static void *pump_thread(void *argument) {
    heeler_overlay_pump *pump = argument;
    pthread_setname_np("dev.bybee.heeler.overlay-pump");

    pump_buffer *buffers = calloc(2, sizeof(pump_buffer));
    if (buffers != NULL) {
        pump_endpoint ends[2] = {
            {.ops = &posix_ops, .fd = pump->local_fd, .read_eof = 0, .write_shut = 0,
             .send_blocked_until_ms = 0},
            {.ops = pump->remote_ops, .fd = pump->remote_fd, .read_eof = 0, .write_shut = 0,
             .send_blocked_until_ms = pump->remote_send_blocked_until_ms},
        };
        pump_run(pump, ends, buffers);
        free(buffers);
    }

    pump->remote_ops->close(pump->remote_fd);
    close(pump->local_fd);
    atomic_fetch_sub(&live_pumps, 1);
    pump_drop_reference(pump);
    return NULL;
}

static int set_no_sigpipe(int fd) {
    int enabled = 1;
    return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
}

static int set_cloexec(int fd) {
    int flags = fcntl(fd, F_GETFD, 0);
    return flags < 0 ? -1 : fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

static int set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    return flags < 0 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static int pump_start(
    int remote_fd,
    const endpoint_ops *remote_ops,
    long long remote_send_blocked_until_ms,
    heeler_overlay_pump **pump_out) {
    int pair[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) {
        remote_ops->close(remote_fd);
        return HEELER_OVERLAY_ERR_RESOURCES;
    }
    /* pair[0] goes to the caller; pair[1] stays with the pump thread. */
    if (set_no_sigpipe(pair[0]) != 0 || set_no_sigpipe(pair[1]) != 0
        || set_cloexec(pair[0]) != 0 || set_cloexec(pair[1]) != 0
        || set_nonblocking(pair[1]) != 0) {
        close(pair[0]);
        close(pair[1]);
        remote_ops->close(remote_fd);
        return HEELER_OVERLAY_ERR_SOCKET;
    }

    heeler_overlay_pump *pump = calloc(1, sizeof(*pump));
    if (pump == NULL) {
        close(pair[0]);
        close(pair[1]);
        remote_ops->close(remote_fd);
        return HEELER_OVERLAY_ERR_RESOURCES;
    }
    atomic_init(&pump->references, 2);
    atomic_init(&pump->stop, 0);
    pump->local_fd = pair[1];
    pump->remote_fd = remote_fd;
    pump->remote_ops = remote_ops;
    pump->remote_send_blocked_until_ms = remote_send_blocked_until_ms;

    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    atomic_fetch_add(&live_pumps, 1);
    pthread_t thread;
    int created = pthread_create(&thread, &attributes, pump_thread, pump);
    pthread_attr_destroy(&attributes);
    if (created != 0) {
        atomic_fetch_sub(&live_pumps, 1);
        close(pair[0]);
        close(pair[1]);
        remote_ops->close(remote_fd);
        free(pump);
        return HEELER_OVERLAY_ERR_RESOURCES;
    }

    *pump_out = pump;
    return pair[0];
}

int heeler_posix_pump_start(int remote_fd, heeler_overlay_pump **pump_out) {
    if (remote_fd < 0 || pump_out == NULL) {
        return HEELER_OVERLAY_ERR_ARGUMENT;
    }
    if (set_no_sigpipe(remote_fd) != 0 || set_nonblocking(remote_fd) != 0) {
        close(remote_fd);
        return HEELER_OVERLAY_ERR_SOCKET;
    }
    return pump_start(remote_fd, &posix_ops, 0, pump_out);
}

int heeler_posix_pump_start_stalling_sends(
    int remote_fd,
    int stall_ms,
    heeler_overlay_pump **pump_out) {
    if (remote_fd < 0 || pump_out == NULL || stall_ms < 0) {
        return HEELER_OVERLAY_ERR_ARGUMENT;
    }
    if (set_no_sigpipe(remote_fd) != 0 || set_nonblocking(remote_fd) != 0) {
        close(remote_fd);
        return HEELER_OVERLAY_ERR_SOCKET;
    }
    return pump_start(remote_fd, &posix_ops, monotonic_ms() + stall_ms, pump_out);
}

int heeler_zt_pump_start(int zts_fd, heeler_overlay_pump **pump_out) {
    if (zts_fd < 0 || pump_out == NULL) {
        return HEELER_OVERLAY_ERR_ARGUMENT;
    }
    if (zts_bsd_fcntl(zts_fd, ZTS_F_SETFL, ZTS_O_NONBLOCK) < 0) {
        zts_bsd_close(zts_fd);
        return HEELER_OVERLAY_ERR_SOCKET;
    }
    return pump_start(zts_fd, &zt_ops, 0, pump_out);
}

void heeler_overlay_pump_release(heeler_overlay_pump *pump) {
    if (pump == NULL) {
        return;
    }
    atomic_store(&pump->stop, 1);
    pump_drop_reference(pump);
}

int heeler_overlay_pump_live_count(void) {
    return atomic_load(&live_pumps);
}

// MARK: - libzt connect

/* The socket's own pending error (SO_ERROR), read through lwIP rather than
 * the process-wide zts_errno. 0 while a connect is still in progress or
 * after it succeeded. */
static int zt_socket_error(int fd) {
    int error = 0;
    zts_socklen_t length = sizeof(error);
    if (zts_bsd_getsockopt(fd, ZTS_SOL_SOCKET, ZTS_SO_ERROR, &error, &length) != 0) {
        return ZTS_EBADF;
    }
    return (error == ZTS_EINPROGRESS || error == ZTS_EALREADY) ? 0 : error;
}

/* The node's own address on `net_id` in `family`, port 0, ready for bind.
 * libzt keeps a managed address's netmask bits in its port field. */
static int zt_network_source(
    uint64_t net_id,
    zts_sa_family_t family,
    struct zts_sockaddr_storage *source,
    zts_socklen_t *source_length) {
    memset(source, 0, sizeof(*source));
    if (zts_addr_get(net_id, family, source) != ZTS_ERR_OK) {
        return HEELER_OVERLAY_ERR_NO_SOURCE;
    }
    if (family == ZTS_AF_INET) {
        struct zts_sockaddr_in *in4 = (struct zts_sockaddr_in *)source;
        if (in4->sin_family != ZTS_AF_INET) {
            return HEELER_OVERLAY_ERR_NO_SOURCE;
        }
        in4->sin_port = 0;
        *source_length = sizeof(struct zts_sockaddr_in);
    } else {
        struct zts_sockaddr_in6 *in6 = (struct zts_sockaddr_in6 *)source;
        if (in6->sin6_family != ZTS_AF_INET6) {
            return HEELER_OVERLAY_ERR_NO_SOURCE;
        }
        in6->sin6_port = 0;
        *source_length = sizeof(struct zts_sockaddr_in6);
    }
    return HEELER_OVERLAY_OK;
}

int heeler_zt_connect(
    const char *ip,
    uint16_t port,
    uint64_t net_id,
    int timeout_ms,
    const heeler_overlay_cancel *cancel,
    int *zts_fd_out) {
    if (ip == NULL || zts_fd_out == NULL || timeout_ms < 0) {
        return HEELER_OVERLAY_ERR_ARGUMENT;
    }

    struct zts_sockaddr_storage storage;
    memset(&storage, 0, sizeof(storage));
    zts_socklen_t address_length = sizeof(storage);
    struct zts_sockaddr *address = (struct zts_sockaddr *)&storage;
    if (zts_util_ipstr_to_saddr(ip, port, address, &address_length) != ZTS_ERR_OK) {
        return HEELER_OVERLAY_ERR_ARGUMENT;
    }

    /* The connection leaves from the node's address on `net_id` and is
     * bound to that network's interface (heeler_zt_bind_network, like
     * SO_BINDTODEVICE). Two joined networks can assign this node the same
     * address and overlapping subnets, so the source address alone does not
     * name the network; the interface does. A bound socket bypasses lwIP's
     * routing table, so it never takes a route another network's controller
     * pushed, and a destination its own network cannot reach would go
     * unanswered until the timeout: heeler_zt_network_reaches refuses that
     * at once (IPv4 only; the network's subnet, or one of its managed routes
     * through a gateway on that subnet). */
    struct zts_sockaddr_storage source_storage;
    zts_socklen_t source_length = 0;
    if (net_id != 0) {
        int source = zt_network_source(net_id, address->sa_family, &source_storage, &source_length);
        if (source != HEELER_OVERLAY_OK) {
            return source;
        }
        const void *destination = address->sa_family == ZTS_AF_INET
            ? (const void *)&((struct zts_sockaddr_in *)address)->sin_addr
            : (const void *)&((struct zts_sockaddr_in6 *)address)->sin6_addr;
        int reaches = heeler_zt_network_reaches(net_id, address->sa_family, destination);
        if (reaches == HEELER_ZT_ERR_NO_ROUTE) {
            return HEELER_OVERLAY_ERR_NO_ROUTE;
        }
        if (reaches == ZTS_ERR_NO_RESULT) {
            return HEELER_OVERLAY_ERR_NO_SOURCE;
        }
        if (reaches != ZTS_ERR_OK) {
            return HEELER_OVERLAY_ERR_SOCKET;
        }
    }

    int fd = zts_bsd_socket(address->sa_family, ZTS_SOCK_STREAM, 0);
    if (fd < 0) {
        return HEELER_OVERLAY_ERR_SOCKET;
    }
    if (net_id != 0) {
        if (zts_bsd_bind(fd, (struct zts_sockaddr *)&source_storage, source_length) < 0) {
            zts_bsd_close(fd);
            return HEELER_OVERLAY_ERR_SOCKET;
        }
        int bound = heeler_zt_bind_network(fd, net_id, address->sa_family);
        if (bound != ZTS_ERR_OK) {
            zts_bsd_close(fd);
            return bound == ZTS_ERR_NO_RESULT ? HEELER_OVERLAY_ERR_NO_SOURCE : HEELER_OVERLAY_ERR_SOCKET;
        }
    }
    if (zts_bsd_fcntl(fd, ZTS_F_SETFL, ZTS_O_NONBLOCK) < 0) {
        zts_bsd_close(fd);
        return HEELER_OVERLAY_ERR_SOCKET;
    }
    int enabled = 1;
    zts_bsd_setsockopt(fd, ZTS_IPPROTO_TCP, ZTS_TCP_NODELAY, &enabled, sizeof(enabled));

    if (zts_bsd_connect(fd, address, address_length) == 0) {
        *zts_fd_out = fd;
        return HEELER_OVERLAY_OK;
    }
    /* Never zts_errno: it is process-wide and other streams' pumps write
     * it concurrently. The socket's own SO_ERROR reports an immediate
     * failure; otherwise the connect is in progress. */
    if (zt_socket_error(fd) != 0) {
        zts_bsd_close(fd);
        return HEELER_OVERLAY_ERR_REFUSED;
    }

    long long deadline = monotonic_ms() + timeout_ms;
    for (;;) {
        if (heeler_overlay_cancel_is_set(cancel)) {
            zts_bsd_close(fd);
            return HEELER_OVERLAY_ERR_CANCELLED;
        }
        long long remaining = deadline - monotonic_ms();
        if (remaining <= 0) {
            zts_bsd_close(fd);
            return HEELER_OVERLAY_ERR_TIMEOUT;
        }
        int slice = remaining < CONNECT_SLICE_MS ? (int)remaining : CONNECT_SLICE_MS;
        struct zts_pollfd descriptor = {.fd = fd, .events = ZTS_POLLOUT, .revents = 0};
        int result = zts_bsd_poll(&descriptor, 1, slice);
        if (result < 0) {
            zts_bsd_close(fd);
            return HEELER_OVERLAY_ERR_SOCKET;
        }
        if (result == 0) {
            if (zt_socket_error(fd) != 0) {
                zts_bsd_close(fd);
                return HEELER_OVERLAY_ERR_REFUSED;
            }
            continue;
        }
        if (descriptor.revents & (ZTS_POLLERR | ZTS_POLLNVAL | ZTS_POLLHUP)) {
            zts_bsd_close(fd);
            return HEELER_OVERLAY_ERR_REFUSED;
        }
        if (descriptor.revents & ZTS_POLLOUT) {
            if (zt_socket_error(fd) != 0) {
                zts_bsd_close(fd);
                return HEELER_OVERLAY_ERR_REFUSED;
            }
            *zts_fd_out = fd;
            return HEELER_OVERLAY_OK;
        }
    }
}
