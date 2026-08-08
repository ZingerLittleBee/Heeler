#ifndef C_HEELER_SSH_SUPPORT_H
#define C_HEELER_SSH_SUPPORT_H

#include <CLibSSH2/libssh2.h>

int heeler_libssh2_abandon_session(LIBSSH2_SESSION *session);

typedef ssize_t (*heeler_libssh2_receive_callback)(
    libssh2_socket_t socket,
    void *buffer,
    size_t length,
    int flags,
    void **abstract
);

void heeler_libssh2_set_receive_callback(
    LIBSSH2_SESSION *session,
    heeler_libssh2_receive_callback callback
);

#endif
