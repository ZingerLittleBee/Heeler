#include "CHeelerSSHSupport.h"

#include <errno.h>

static ssize_t heeler_abandoned_send(
    libssh2_socket_t socket,
    const void *buffer,
    size_t length,
    int flags,
    void **abstract
) {
    (void)socket;
    (void)buffer;
    (void)length;
    (void)flags;
    (void)abstract;
    errno = EPIPE;
    return -1;
}

static ssize_t heeler_abandoned_receive(
    libssh2_socket_t socket,
    void *buffer,
    size_t length,
    int flags,
    void **abstract
) {
    (void)socket;
    (void)buffer;
    (void)length;
    (void)flags;
    (void)abstract;
    errno = ECONNRESET;
    return -1;
}

int heeler_libssh2_abandon_session(LIBSSH2_SESSION *session) {
    if (session == NULL) {
        return LIBSSH2_ERROR_BAD_USE;
    }

    /*
     * In pinned libssh2 1.11.1, session_free can propagate EAGAIN only while
     * freeing channels or listeners. Those paths obtain EAGAIN from transport
     * send or receive callbacks. Replacing both callbacks with fatal I/O makes
     * abandonment a one-shot local reclamation with no peer-readiness wait.
     */
    libssh2_session_callback_set2(
        session,
        LIBSSH2_CALLBACK_SEND,
        (libssh2_cb_generic *)heeler_abandoned_send
    );
    libssh2_session_callback_set2(
        session,
        LIBSSH2_CALLBACK_RECV,
        (libssh2_cb_generic *)heeler_abandoned_receive
    );

    return libssh2_session_free(session);
}
