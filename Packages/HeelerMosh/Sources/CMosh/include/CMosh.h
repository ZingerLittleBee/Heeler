#ifndef C_MOSH_H
#define C_MOSH_H

#include <stddef.h>
#include <sys/ioctl.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Caller-owned window-size storage visible to mosh_main as a plain
/// `struct winsize *`. The library never ioctls it: a resize is
/// `mosh_ws_update` (in-place mutation) followed by SIGWINCH, which pushes
/// the new geometry to the remote emulator.
struct mosh_ws {
    struct winsize size;
};

struct mosh_ws *mosh_ws_create(unsigned short col, unsigned short row);
void mosh_ws_destroy(struct mosh_ws *ws);
void mosh_ws_update(struct mosh_ws *ws, unsigned short col, unsigned short row);
struct winsize *mosh_ws_pointer(struct mosh_ws *ws);

/// Phase-1 state-export callback: the library fires it with a serialized
/// `Restoration::Context` on SIGINFO / suspend / clean shutdown. Session
/// resume is not wired yet, so the bytes are discarded.
void mosh_state_discard(const void *context, const void *data, size_t length);

/// mosh's init() exits the whole process when the native locale is not
/// UTF-8, so it must run before mosh_main. Darwin has no environment to
/// inherit; try the explicit UTF-8 locale and fall back to C.UTF-8.
void mosh_prepare_locale(void);

#ifdef __cplusplus
}
#endif

#endif /* C_MOSH_H */
