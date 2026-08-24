#include "CHeelerSSHSupport.h"

#include <errno.h>

static ssize_t heeler_discarded_send(
    libssh2_socket_t socket,
    const void *buffer,
    size_t length,
    int flags,
    void **abstract
) {
    (void)socket;
    (void)buffer;
    (void)flags;
    (void)abstract;
    return (ssize_t)length;
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
    return -ECONNRESET;
}

void heeler_libssh2_prepare_session_abandonment(LIBSSH2_SESSION *session) {
    if (session == NULL) {
        return;
    }

    /*
     * A pending transport packet must first be completed by the exact owning
     * libssh2 call: send_existing rejects a different data pointer with EAGAIN
     * before invoking this callback. Reporting the owner's remaining bytes as
     * consumed clears that packet without peer I/O. Fatal receives then keep
     * channel teardown from waiting for remote close acknowledgements.
     */
    libssh2_session_callback_set2(
        session,
        LIBSSH2_CALLBACK_SEND,
        (libssh2_cb_generic *)heeler_discarded_send
    );
    libssh2_session_callback_set2(
        session,
        LIBSSH2_CALLBACK_RECV,
        (libssh2_cb_generic *)heeler_abandoned_receive
    );
}

int heeler_libssh2_abandon_session(LIBSSH2_SESSION *session) {
    if (session == NULL) {
        return LIBSSH2_ERROR_BAD_USE;
    }

    heeler_libssh2_prepare_session_abandonment(session);
    return libssh2_session_free(session);
}
