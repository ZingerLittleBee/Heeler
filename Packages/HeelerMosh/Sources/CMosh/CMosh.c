#include "CMosh.h"

#include <locale.h>
#include <stdlib.h>

struct mosh_ws *mosh_ws_create(unsigned short col, unsigned short row) {
    struct mosh_ws *ws = malloc(sizeof(struct mosh_ws));
    if (ws == NULL) {
        return NULL;
    }
    ws->size.ws_col = col;
    ws->size.ws_row = row;
    ws->size.ws_xpixel = 0;
    ws->size.ws_ypixel = 0;
    return ws;
}

void mosh_ws_destroy(struct mosh_ws *ws) {
    free(ws);
}

void mosh_ws_update(struct mosh_ws *ws, unsigned short col, unsigned short row) {
    if (ws == NULL) {
        return;
    }
    ws->size.ws_col = col;
    ws->size.ws_row = row;
}

struct winsize *mosh_ws_pointer(struct mosh_ws *ws) {
    return ws == NULL ? NULL : &ws->size;
}

void mosh_state_discard(const void *context, const void *data, size_t length) {
    (void)context;
    (void)data;
    (void)length;
}

void mosh_prepare_locale(void) {
    if (setlocale(LC_ALL, "en_US.UTF-8") != NULL) {
        return;
    }
    setlocale(LC_ALL, "C.UTF-8");
}
