#include "CHeelerSSHSupport.h"

/*
 * libssh2 keeps its transport callbacks behind one generic function pointer,
 * so installing a receive callback from Swift would need a reinterpreting cast
 * at the call site. Keeping the cast here lets the Swift side hand over a
 * correctly typed function instead.
 */
void heeler_libssh2_set_receive_callback(
    LIBSSH2_SESSION *session,
    heeler_libssh2_receive_callback callback
) {
    if (session == NULL || callback == NULL) {
        return;
    }

    libssh2_session_callback_set2(
        session,
        LIBSSH2_CALLBACK_RECV,
        (libssh2_cb_generic *)callback
    );
}
