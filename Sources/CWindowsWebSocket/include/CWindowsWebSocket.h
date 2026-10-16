#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct xtool_websocket xtool_websocket;
typedef struct xtool_http_client xtool_http_client;
xtool_http_client *xtool_http_client_create(const char *roots_pem, const uint16_t *proxy,
                                            int disable_tls_validation, uint32_t *error);
void xtool_http_client_destroy(xtool_http_client *);
int xtool_ws_connect_with_client(xtool_websocket *, xtool_http_client *, const uint16_t *url,
                                  uint32_t *error, uint32_t *http_status);
int xtool_http_open(xtool_websocket *, xtool_http_client *, const uint16_t *url,
                    const uint16_t *method, const uint16_t *headers, const void *body,
                    uint32_t body_size, uint32_t *error, uint32_t *http_status);
int xtool_http_headers(xtool_websocket *, uint16_t **headers, uint32_t *error);
int xtool_http_read(xtool_websocket *, void *buffer, uint32_t capacity,
                    uint32_t *count, uint32_t *error);
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
