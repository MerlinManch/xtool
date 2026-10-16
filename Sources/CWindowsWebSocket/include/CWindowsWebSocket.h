#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct xtool_websocket xtool_websocket;
xtool_websocket *xtool_ws_create(void);
int xtool_ws_connect(xtool_websocket *, const uint16_t *url, uint32_t *error, uint32_t *http_status);
int xtool_ws_send(xtool_websocket *, const void *data, uint32_t size, int text, uint32_t *error);
int xtool_ws_receive(xtool_websocket *, void **data, uint32_t *size, int *text,
                     uint32_t *close_status, uint32_t *error);
void xtool_ws_release_data(void *);
void xtool_ws_shutdown(xtool_websocket *);
void xtool_ws_abort(xtool_websocket *);
void xtool_ws_destroy(xtool_websocket *);
#ifdef __cplusplus
}
#endif
