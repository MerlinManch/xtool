#ifdef _WIN32
#if !defined(_WIN32_WINNT) || _WIN32_WINNT < 0x0603
#undef _WIN32_WINNT
#define _WIN32_WINNT 0x0603
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>
#include <wincrypt.h>
#include <wchar.h>
#include <stdlib.h>
#include <string.h>
#include "CWindowsWebSocket.h"

struct xtool_http_client {
    volatile LONG references;
    HINTERNET session;
    HCERTCHAINENGINE chain_engine;
    int disable_tls_validation;
};
static void client_retain(xtool_http_client *client) { InterlockedIncrement(&client->references); }
void xtool_http_client_destroy(xtool_http_client *client) {
    if (!client || InterlockedDecrement(&client->references) != 0) return;
    if (client->session) WinHttpCloseHandle(client->session);
    if (client->chain_engine) CertFreeCertificateChainEngine(client->chain_engine);
    free(client);
}
static HCERTCHAINENGINE create_chain_engine(const char *pem) {
    HCERTSTORE roots = CertOpenStore(CERT_STORE_PROV_COLLECTION, 0, 0, 0, NULL);
    HCERTSTORE system = CertOpenSystemStoreW(0, L"ROOT");
    HCERTSTORE additional = CertOpenStore(CERT_STORE_PROV_MEMORY, 0, 0, 0, NULL);
    HCERTCHAINENGINE engine = NULL;
    if (!roots || !system || !additional) goto done;
    if (!CertAddStoreToCollection(roots, system, 0, 0) ||
        !CertAddStoreToCollection(roots, additional, CERT_PHYSICAL_STORE_ADD_ENABLE_FLAG, 1)) goto done;
    while (pem && *pem) {
        const char *begin = strstr(pem, "-----BEGIN CERTIFICATE-----");
        if (!begin) break;
        const char *end = strstr(begin, "-----END CERTIFICATE-----");
        if (!end) goto done;
        size_t length = (size_t)(end - begin) + strlen("-----END CERTIFICATE-----");
        if (length > MAXDWORD) goto done;
        DWORD size = 0;
        if (!CryptStringToBinaryA(begin, (DWORD)length, CRYPT_STRING_BASE64HEADER, NULL, &size, NULL, NULL)) goto done;
        BYTE *der = (BYTE *)malloc(size);
        if (!der) goto done;
        BOOL success = CryptStringToBinaryA(begin, (DWORD)length, CRYPT_STRING_BASE64HEADER, der, &size, NULL, NULL) &&
            CertAddEncodedCertificateToStore(additional, X509_ASN_ENCODING, der, size, CERT_STORE_ADD_USE_EXISTING, NULL);
        free(der);
        if (!success) goto done;
        pem = end + strlen("-----END CERTIFICATE-----");
    }
    CERT_CHAIN_ENGINE_CONFIG config = {0};
    config.cbSize = (DWORD)sizeof(config);
    config.hExclusiveRoot = roots;
    if (!CertCreateCertificateChainEngine(&config, &engine)) engine = NULL;
done:
    if (additional) CertCloseStore(additional, 0);
    if (system) CertCloseStore(system, 0);
    if (roots) CertCloseStore(roots, 0);
    return engine;
}
xtool_http_client *xtool_http_client_create(const char *roots_pem, const uint16_t *proxy,
                                            int disable_tls_validation, uint32_t *error) {
    xtool_http_client *client = (xtool_http_client *)calloc(1, sizeof(*client));
    if (!client) { *error = ERROR_NOT_ENOUGH_MEMORY; return NULL; }
    client->references = 1;
    client->disable_tls_validation = disable_tls_validation;
    client->chain_engine = create_chain_engine(roots_pem);
    if (!client->chain_engine) { *error = GetLastError(); goto failed; }
    BOOL named_proxy = proxy && *proxy;
    client->session = WinHttpOpen(L"xtool", named_proxy ? WINHTTP_ACCESS_TYPE_NAMED_PROXY : WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
        named_proxy ? (LPCWSTR)proxy : WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, WINHTTP_FLAG_ASYNC);
    if (!client->session || !WinHttpSetTimeouts(client->session, 10000, 10000, 30000, 30000)) {
        *error = GetLastError(); goto failed;
    }
    *error = ERROR_SUCCESS;
    return client;
failed:
    xtool_http_client_destroy(client);
    return NULL;
}
static BOOL verify_server(xtool_http_client *client, HINTERNET request) {
    if (client->disable_tls_validation) return TRUE;
    PCCERT_CONTEXT certificate = NULL;
    PCCERT_CHAIN_CONTEXT chain = NULL;
    wchar_t *url = NULL;
    wchar_t *host = NULL;
    BOOL valid = FALSE;
    DWORD size = 0;
    WinHttpQueryOption(request, WINHTTP_OPTION_URL, NULL, &size);
    if (!size) goto done;
    url = (wchar_t *)malloc(size);
    if (!url || !WinHttpQueryOption(request, WINHTTP_OPTION_URL, url, &size)) goto done;
    URL_COMPONENTS parts = {0};
    parts.dwStructSize = (DWORD)sizeof(parts);
    parts.dwHostNameLength = (DWORD)-1;
    if (!WinHttpCrackUrl(url, 0, 0, &parts)) goto done;
    if (parts.nScheme != INTERNET_SCHEME_HTTPS) { valid = TRUE; goto done; }
    size = (DWORD)sizeof(certificate);
    if (!WinHttpQueryOption(request, WINHTTP_OPTION_SERVER_CERT_CONTEXT, &certificate, &size)) goto done;
    host = (wchar_t *)calloc((size_t)parts.dwHostNameLength + 1, sizeof(wchar_t));
    if (!host) goto done;
    memcpy(host, parts.lpszHostName, (size_t)parts.dwHostNameLength * sizeof(wchar_t));
    LPSTR usage = szOID_PKIX_KP_SERVER_AUTH;
    CERT_CHAIN_PARA parameters = {0};
    parameters.cbSize = (DWORD)sizeof(parameters);
    parameters.RequestedUsage.dwType = USAGE_MATCH_TYPE_AND;
    parameters.RequestedUsage.Usage.cUsageIdentifier = 1;
    parameters.RequestedUsage.Usage.rgpszUsageIdentifier = &usage;
    if (!CertGetCertificateChain(client->chain_engine, certificate, NULL, certificate->hCertStore,
                                 &parameters, 0, NULL, &chain)) goto done;
    SSL_EXTRA_CERT_CHAIN_POLICY_PARA ssl = {0};
    ssl.cbSize = (DWORD)sizeof(ssl);
    ssl.dwAuthType = AUTHTYPE_SERVER;
    ssl.pwszServerName = host;
    CERT_CHAIN_POLICY_PARA policy = {0};
    policy.cbSize = (DWORD)sizeof(policy);
    policy.pvExtraPolicyPara = &ssl;
    CERT_CHAIN_POLICY_STATUS status = {0};
    status.cbSize = (DWORD)sizeof(status);
    valid = CertVerifyCertificateChainPolicy(CERT_CHAIN_POLICY_SSL, chain, &policy, &status) && status.dwError == 0;
done:
    free(url); free(host);
    if (chain) CertFreeCertificateChain(chain);
    if (certificate) CertFreeCertificateContext(certificate);
    return valid;
}

typedef struct callback_context {
    struct xtool_websocket *owner;
    int socket;
} callback_context;

struct xtool_websocket {
    SRWLOCK handles_lock, read_lock, write_lock;
    HINTERNET session, connection, request, socket;
    HANDLE open_done, read_done, write_done, shutdown_done;
    volatile LONG references, closed, attempted, tls_active;
    xtool_http_client *client;
    int secure;
    volatile LONG open_error, read_error, write_error, shutdown_error;
    volatile LONG received, buffer_type;
    callback_context request_context, socket_context;
};

static LONG atomic_read(volatile LONG *value) { return InterlockedCompareExchange(value, 0, 0); }
static void retain(xtool_websocket *state) { InterlockedIncrement(&state->references); }
static void release(xtool_websocket *state) {
    if (InterlockedDecrement(&state->references) != 0) return;
    if (state->open_done) CloseHandle(state->open_done);
    if (state->read_done) CloseHandle(state->read_done);
    if (state->write_done) CloseHandle(state->write_done);
    if (state->shutdown_done) CloseHandle(state->shutdown_done);
    if (state->client) xtool_http_client_destroy(state->client);
    free(state);
}
static void complete(volatile LONG *slot, HANDLE event, DWORD error) {
    InterlockedExchange(slot, (LONG)error);
    SetEvent(event);
}
static void CALLBACK callback(HINTERNET handle, DWORD_PTR raw_context, DWORD status,
                              LPVOID information, DWORD length) {
    (void)handle;
    callback_context *context = (callback_context *)raw_context;
    if (!context) return;
    xtool_websocket *state = context->owner;
    if (status == WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING) {
        // HANDLE_CLOSING is the final callback. Pending buffers are no longer
        // used by WinHTTP, so blocked callers can now safely release them.
        if (context->socket) {
            complete(&state->read_error, state->read_done, ERROR_OPERATION_ABORTED);
            complete(&state->write_error, state->write_done, ERROR_OPERATION_ABORTED);
            complete(&state->shutdown_error, state->shutdown_done, ERROR_OPERATION_ABORTED);
        } else {
            complete(&state->open_error, state->open_done, ERROR_OPERATION_ABORTED);
            complete(&state->read_error, state->read_done, ERROR_OPERATION_ABORTED);
        }
        release(state);
        return;
    }
    if (!context->socket) {
        if (status == WINHTTP_CALLBACK_STATUS_SENDING_REQUEST && state->client) {
            // Cancellation marks the request closed immediately, but defers
            // physical closure while this callback queries its certificate.
            InterlockedIncrement(&state->tls_active);
            BOOL valid = !atomic_read(&state->closed) && verify_server(state->client, handle);
            if (!valid) InterlockedExchange(&state->closed, 1);
            InterlockedDecrement(&state->tls_active);
            if (atomic_read(&state->closed)) {
                // Informational callbacks may close their own request. Reject
                // before any HTTP headers or body are sent, also on redirects.
                HINTERNET request = (HINTERNET)InterlockedExchangePointer((PVOID volatile *)&state->request, NULL);
                if (request) WinHttpCloseHandle(request);
                return;
            }
        }
        if (status == WINHTTP_CALLBACK_STATUS_READ_COMPLETE) {
            InterlockedExchange(&state->received, (LONG)length);
            complete(&state->read_error, state->read_done, ERROR_SUCCESS);
        } else if (status == WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE ||
            status == WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE) {
            complete(&state->open_error, state->open_done, ERROR_SUCCESS);
        } else if (status == WINHTTP_CALLBACK_STATUS_REQUEST_ERROR &&
                   length >= sizeof(WINHTTP_ASYNC_RESULT)) {
            WINHTTP_ASYNC_RESULT *result = (WINHTTP_ASYNC_RESULT *)information;
            if (result->dwResult == API_READ_DATA)
                complete(&state->read_error, state->read_done, result->dwError);
            else complete(&state->open_error, state->open_done, result->dwError);
        }
        return;
    }
    switch (status) {
    case WINHTTP_CALLBACK_STATUS_READ_COMPLETE:
        if (length >= sizeof(WINHTTP_WEB_SOCKET_STATUS)) {
            WINHTTP_WEB_SOCKET_STATUS *result = (WINHTTP_WEB_SOCKET_STATUS *)information;
            InterlockedExchange(&state->received, (LONG)result->dwBytesTransferred);
            InterlockedExchange(&state->buffer_type, (LONG)result->eBufferType);
            complete(&state->read_error, state->read_done, ERROR_SUCCESS);
        }
        break;
    case WINHTTP_CALLBACK_STATUS_WRITE_COMPLETE:
        complete(&state->write_error, state->write_done, ERROR_SUCCESS);
        break;
    case WINHTTP_CALLBACK_STATUS_SHUTDOWN_COMPLETE:
        complete(&state->shutdown_error, state->shutdown_done, ERROR_SUCCESS);
        break;
    case WINHTTP_CALLBACK_STATUS_REQUEST_ERROR:
        if (length >= sizeof(WINHTTP_WEB_SOCKET_ASYNC_RESULT)) {
            WINHTTP_WEB_SOCKET_ASYNC_RESULT *result = (WINHTTP_WEB_SOCKET_ASYNC_RESULT *)information;
            switch (result->Operation) {
            case WINHTTP_WEB_SOCKET_RECEIVE_OPERATION:
                complete(&state->read_error, state->read_done, result->AsyncResult.dwError);
                break;
            case WINHTTP_WEB_SOCKET_SEND_OPERATION:
                complete(&state->write_error, state->write_done, result->AsyncResult.dwError);
                break;
            case WINHTTP_WEB_SOCKET_SHUTDOWN_OPERATION:
                complete(&state->shutdown_error, state->shutdown_done, result->AsyncResult.dwError);
                break;
            default: break;
            }
        }
        break;
    default: break;
    }
}
static DWORD wait_for(xtool_websocket *state, HANDLE event, volatile LONG *error) {
    DWORD waited = WaitForSingleObject(event, INFINITE);
    if (waited != WAIT_OBJECT_0) return waited == WAIT_FAILED ? GetLastError() : ERROR_OPERATION_ABORTED;
    if (atomic_read(&state->closed)) return ERROR_OPERATION_ABORTED;
    return (DWORD)atomic_read(error);
}
static wchar_t *copy_wide(const wchar_t *text, DWORD count) {
    wchar_t *copy = (wchar_t *)calloc((size_t)count + 1, sizeof(wchar_t));
    if (copy && count) memcpy(copy, text, (size_t)count * sizeof(wchar_t));
    return copy;
}
xtool_websocket *xtool_ws_create(void) {
    xtool_websocket *state = (xtool_websocket *)calloc(1, sizeof(*state));
    if (!state) return NULL;
    InitializeSRWLock(&state->handles_lock);
    InitializeSRWLock(&state->read_lock);
    InitializeSRWLock(&state->write_lock);
    state->references = 1;
    state->request_context.owner = state;
    state->socket_context.owner = state;
    state->socket_context.socket = 1;
    state->open_done = CreateEventW(NULL, FALSE, FALSE, NULL);
    state->read_done = CreateEventW(NULL, FALSE, FALSE, NULL);
    state->write_done = CreateEventW(NULL, FALSE, FALSE, NULL);
    state->shutdown_done = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (!state->open_done || !state->read_done || !state->write_done || !state->shutdown_done) {
        release(state);
        return NULL;
    }
    return state;
}
void xtool_ws_abort(xtool_websocket *state) {
    if (!state) return;
    AcquireSRWLockExclusive(&state->handles_lock);
    InterlockedExchange(&state->closed, 1);
    if (atomic_read(&state->tls_active)) {
        // The informational callback closes its request after its final query.
        // open_request then releases the remaining handles on its error path.
        ReleaseSRWLockExclusive(&state->handles_lock);
        return;
    }
    // Calls that issue asynchronous operations and CloseHandle are serialized.
    // Callbacks never acquire this lock and keep the state alive independently.
    if (state->socket) { WinHttpCloseHandle(state->socket); state->socket = NULL; }
    HINTERNET request = (HINTERNET)InterlockedExchangePointer((PVOID volatile *)&state->request, NULL);
    if (request) WinHttpCloseHandle(request);
    if (state->connection) { WinHttpCloseHandle(state->connection); state->connection = NULL; }
    if (state->session && !state->client) WinHttpCloseHandle(state->session);
    state->session = NULL;
    ReleaseSRWLockExclusive(&state->handles_lock);
}
void xtool_ws_destroy(xtool_websocket *state) {
    if (!state) return;
    xtool_ws_abort(state);
    release(state);
}
static BOOL attach(xtool_websocket *state, HINTERNET handle, callback_context *context) {
    if (WinHttpSetStatusCallback(handle, callback, WINHTTP_CALLBACK_FLAG_ALL_NOTIFICATIONS, 0)
        == WINHTTP_INVALID_STATUS_CALLBACK) return FALSE;
    DWORD_PTR value = (DWORD_PTR)context;
    retain(state);
    if (!WinHttpSetOption(handle, WINHTTP_OPTION_CONTEXT_VALUE, &value, (DWORD)sizeof(value))) {
        release(state);
        return FALSE;
    }
    return TRUE;
}
static int open_request(xtool_websocket *state, xtool_http_client *client, const uint16_t *url,
                        const uint16_t *method, const uint16_t *headers, const void *body,
                        uint32_t body_size, int websocket, uint32_t *error, uint32_t *http_status) {
    retain(state);
    DWORD failure = ERROR_SUCCESS;
    wchar_t *host = NULL, *path = NULL, *user = NULL, *password = NULL;
    URL_COMPONENTS parts = {0};
    parts.dwStructSize = (DWORD)sizeof(parts);
    parts.dwHostNameLength = parts.dwUrlPathLength = parts.dwExtraInfoLength = (DWORD)-1;
    parts.dwUserNameLength = parts.dwPasswordLength = (DWORD)-1;
    *http_status = 0;
    if (InterlockedCompareExchange(&state->attempted, 1, 0) ||
        !WinHttpCrackUrl((LPCWSTR)url, 0, 0, &parts) ||
        (parts.nScheme != INTERNET_SCHEME_HTTP && parts.nScheme != INTERNET_SCHEME_HTTPS)) {
        *error = ERROR_INVALID_PARAMETER;
        release(state);
        return 0;
    }
    if (client) { client_retain(client); state->client = client; }
    state->secure = parts.nScheme == INTERNET_SCHEME_HTTPS;
    host = copy_wide(parts.lpszHostName, parts.dwHostNameLength);
    size_t path_length = (size_t)parts.dwUrlPathLength + parts.dwExtraInfoLength;
    path = (wchar_t *)calloc(path_length + 2, sizeof(wchar_t));
    user = copy_wide(parts.lpszUserName, parts.dwUserNameLength);
    password = copy_wide(parts.lpszPassword, parts.dwPasswordLength);
    if (!host || !path || !user || !password) { failure = ERROR_NOT_ENOUGH_MEMORY; goto done; }
    size_t position = 0;
    if (parts.dwUrlPathLength) {
        memcpy(path, parts.lpszUrlPath, (size_t)parts.dwUrlPathLength * sizeof(wchar_t));
        position = parts.dwUrlPathLength;
    } else path[position++] = L'/';
    if (parts.dwExtraInfoLength)
        memcpy(path + position, parts.lpszExtraInfo, (size_t)parts.dwExtraInfoLength * sizeof(wchar_t));

    AcquireSRWLockExclusive(&state->handles_lock);
    if (atomic_read(&state->closed)) failure = ERROR_OPERATION_ABORTED;
    else {
        state->session = client ? client->session : WinHttpOpen(L"xtool", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                                     WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, WINHTTP_FLAG_ASYNC);
        if (!state->session) failure = GetLastError();
        if (!failure && !WinHttpSetTimeouts(state->session, 10000, 10000, 30000, 30000)) failure = GetLastError();
        if (!failure) {
            state->connection = WinHttpConnect(state->session, host, parts.nPort, 0);
            if (!state->connection) failure = GetLastError();
        }
        if (!failure) {
            state->request = WinHttpOpenRequest(state->connection, (LPCWSTR)method, path, NULL,
                WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                parts.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0);
            if (!state->request) failure = GetLastError();
        }
        if (!failure && !attach(state, state->request, &state->request_context)) failure = GetLastError();
        if (!failure && websocket && !WinHttpSetOption(state->request, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, NULL, 0))
            failure = GetLastError();
        if (!failure && client) {
            DWORD flags = SECURITY_FLAG_IGNORE_UNKNOWN_CA;
            if (client->disable_tls_validation)
                flags |= SECURITY_FLAG_IGNORE_CERT_CN_INVALID | SECURITY_FLAG_IGNORE_CERT_DATE_INVALID | SECURITY_FLAG_IGNORE_CERT_WRONG_USAGE;
            if (!WinHttpSetOption(state->request, WINHTTP_OPTION_SECURITY_FLAGS, &flags, (DWORD)sizeof(flags)))
                failure = GetLastError();
        }
        if (!failure && client) {
            DWORD policy = WINHTTP_AUTOLOGON_SECURITY_LEVEL_HIGH;
            if (!WinHttpSetOption(state->request, WINHTTP_OPTION_AUTOLOGON_POLICY, &policy, (DWORD)sizeof(policy)))
                failure = GetLastError();
        }
        if (!failure && !websocket) {
            DWORD decompression = WINHTTP_DECOMPRESSION_FLAG_ALL;
            if (!WinHttpSetOption(state->request, WINHTTP_OPTION_DECOMPRESSION, &decompression, (DWORD)sizeof(decompression)))
                failure = GetLastError();
        }
        if (!failure && parts.dwUserNameLength &&
            !WinHttpSetCredentials(state->request, WINHTTP_AUTH_TARGET_SERVER, WINHTTP_AUTH_SCHEME_BASIC,
                                   user, password, NULL)) failure = GetLastError();
        if (!failure) {
            ResetEvent(state->open_done);
            if (!WinHttpSendRequest(state->request, (LPCWSTR)headers, headers ? (DWORD)-1 : 0,
                (LPVOID)body, body_size, body_size, (DWORD_PTR)&state->request_context)) {
                failure = GetLastError();
                if (failure == ERROR_IO_PENDING) failure = ERROR_SUCCESS;
            }
        }
    }
    ReleaseSRWLockExclusive(&state->handles_lock);
    if (failure) goto done;
    failure = wait_for(state, state->open_done, &state->open_error);
    if (failure) goto done;
    AcquireSRWLockExclusive(&state->handles_lock);
    if (atomic_read(&state->closed)) failure = ERROR_OPERATION_ABORTED;
    else {
        ResetEvent(state->open_done);
        if (!WinHttpReceiveResponse(state->request, NULL)) {
            failure = GetLastError();
            if (failure == ERROR_IO_PENDING) failure = ERROR_SUCCESS;
        }
    }
    ReleaseSRWLockExclusive(&state->handles_lock);
    if (failure) goto done;
    failure = wait_for(state, state->open_done, &state->open_error);
    if (failure) goto done;
    AcquireSRWLockExclusive(&state->handles_lock);
    if (atomic_read(&state->closed)) failure = ERROR_OPERATION_ABORTED;
    else {
        DWORD status = 0, length = (DWORD)sizeof(status);
        if (!WinHttpQueryHeaders(state->request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                                 WINHTTP_HEADER_NAME_BY_INDEX, &status, &length, WINHTTP_NO_HEADER_INDEX))
            failure = GetLastError();
        else {
            *http_status = status;
            if (websocket && status != 101) failure = ERROR_WINHTTP_INVALID_SERVER_RESPONSE;
        }
        if (!failure && websocket) {
            state->socket = WinHttpWebSocketCompleteUpgrade(state->request, 0);
            if (!state->socket) failure = GetLastError();
            else if (!attach(state, state->socket, &state->socket_context)) failure = GetLastError();
        }
    }
    ReleaseSRWLockExclusive(&state->handles_lock);
done:
    free(host); free(path); free(user); free(password);
    if (failure) xtool_ws_abort(state);
    *error = failure;
    release(state);
    return failure == ERROR_SUCCESS;
}
int xtool_ws_connect(xtool_websocket *state, const uint16_t *url, uint32_t *error, uint32_t *http_status) {
    return open_request(state, NULL, url, (const uint16_t *)L"GET", NULL, NULL, 0, 1, error, http_status);
}
int xtool_ws_connect_with_client(xtool_websocket *state, xtool_http_client *client, const uint16_t *url,
                                  uint32_t *error, uint32_t *http_status) {
    return open_request(state, client, url, (const uint16_t *)L"GET", NULL, NULL, 0, 1, error, http_status);
}
int xtool_http_open(xtool_websocket *state, xtool_http_client *client, const uint16_t *url,
                    const uint16_t *method, const uint16_t *headers, const void *body,
                    uint32_t body_size, uint32_t *error, uint32_t *http_status) {
    return open_request(state, client, url, method, headers, body, body_size, 0, error, http_status);
}
int xtool_http_headers(xtool_websocket *state, uint16_t **headers, uint32_t *error) {
    retain(state);
    DWORD failure = ERROR_OPERATION_ABORTED;
    *headers = NULL;
    AcquireSRWLockExclusive(&state->handles_lock);
    if (!atomic_read(&state->closed) && state->request) {
        DWORD size = 0;
        WinHttpQueryHeaders(state->request, WINHTTP_QUERY_RAW_HEADERS_CRLF, WINHTTP_HEADER_NAME_BY_INDEX,
                            NULL, &size, WINHTTP_NO_HEADER_INDEX);
        failure = GetLastError();
        if (failure == ERROR_INSUFFICIENT_BUFFER) {
            *headers = (uint16_t *)calloc(1, (size_t)size + sizeof(uint16_t));
            if (!*headers) failure = ERROR_NOT_ENOUGH_MEMORY;
            else if (!WinHttpQueryHeaders(state->request, WINHTTP_QUERY_RAW_HEADERS_CRLF, WINHTTP_HEADER_NAME_BY_INDEX,
                                          *headers, &size, WINHTTP_NO_HEADER_INDEX)) failure = GetLastError();
            else failure = ERROR_SUCCESS;
        }
    }
    ReleaseSRWLockExclusive(&state->handles_lock);
    if (failure) { free(*headers); *headers = NULL; }
    *error = failure;
    release(state);
    return failure == ERROR_SUCCESS;
}
int xtool_http_read(xtool_websocket *state, void *buffer, uint32_t capacity,
                    uint32_t *count, uint32_t *error) {
    retain(state);
    AcquireSRWLockExclusive(&state->read_lock);
    AcquireSRWLockExclusive(&state->handles_lock);
    DWORD failure = ERROR_OPERATION_ABORTED;
    *count = 0;
    if (!atomic_read(&state->closed) && state->request) {
        ResetEvent(state->read_done);
        if (WinHttpReadData(state->request, buffer, capacity, NULL)) failure = ERROR_SUCCESS;
        else {
            failure = GetLastError();
            if (failure == ERROR_IO_PENDING) failure = ERROR_SUCCESS;
        }
    }
    ReleaseSRWLockExclusive(&state->handles_lock);
    if (!failure) failure = wait_for(state, state->read_done, &state->read_error);
    if (!failure) *count = (uint32_t)atomic_read(&state->received);
    ReleaseSRWLockExclusive(&state->read_lock);
    *error = failure;
    release(state);
    return failure == ERROR_SUCCESS;
}
int xtool_ws_send(xtool_websocket *state, const void *data, uint32_t size, int text, uint32_t *error) {
    retain(state);
    AcquireSRWLockExclusive(&state->write_lock);
    AcquireSRWLockExclusive(&state->handles_lock);
    DWORD failure = ERROR_OPERATION_ABORTED;
    if (!atomic_read(&state->closed) && state->socket) {
        ResetEvent(state->write_done);
        failure = WinHttpWebSocketSend(state->socket,
            text ? WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE : WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE,
            size ? (PVOID)data : NULL, size);
        if (failure == ERROR_IO_PENDING) failure = ERROR_SUCCESS;
    }
    ReleaseSRWLockExclusive(&state->handles_lock);
    if (!failure) failure = wait_for(state, state->write_done, &state->write_error);
    ReleaseSRWLockExclusive(&state->write_lock);
    *error = failure;
    release(state);
    return failure == ERROR_SUCCESS;
}
int xtool_ws_receive(xtool_websocket *state, void **data, uint32_t *size, int *text,
                     uint32_t *close_status, uint32_t *error) {
    retain(state);
    unsigned char chunk[65536];
    unsigned char *message = NULL;
    size_t count = 0, capacity = 0;
    int message_text = -1;
    DWORD failure = ERROR_SUCCESS;
    *data = NULL; *size = 0; *text = 0; *close_status = 0;
    AcquireSRWLockExclusive(&state->read_lock);
    for (;;) {
        AcquireSRWLockExclusive(&state->handles_lock);
        if (atomic_read(&state->closed) || !state->socket) failure = ERROR_OPERATION_ABORTED;
        else {
            ResetEvent(state->read_done);
            failure = WinHttpWebSocketReceive(state->socket, chunk, (DWORD)sizeof(chunk), NULL, NULL);
            if (failure == ERROR_IO_PENDING) failure = ERROR_SUCCESS;
        }
        ReleaseSRWLockExclusive(&state->handles_lock);
        if (!failure) failure = wait_for(state, state->read_done, &state->read_error);
        if (failure) break;
        DWORD received = (DWORD)atomic_read(&state->received);
        WINHTTP_WEB_SOCKET_BUFFER_TYPE type = (WINHTTP_WEB_SOCKET_BUFFER_TYPE)atomic_read(&state->buffer_type);
        if (type == WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE) {
            USHORT status = WINHTTP_WEB_SOCKET_EMPTY_CLOSE_STATUS;
            DWORD ignored = 0;
            AcquireSRWLockExclusive(&state->handles_lock);
            if (!atomic_read(&state->closed) && state->socket)
                WinHttpWebSocketQueryCloseStatus(state->socket, &status, NULL, 0, &ignored);
            ReleaseSRWLockExclusive(&state->handles_lock);
            *close_status = status;
            break;
        }
        int current_text = type == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE ||
                           type == WINHTTP_WEB_SOCKET_UTF8_FRAGMENT_BUFFER_TYPE;
        if (message_text != -1 && current_text != message_text) { failure = ERROR_INVALID_DATA; break; }
        message_text = current_text;
        if (received > 64U * 1024U * 1024U - count) { failure = ERROR_NOT_ENOUGH_MEMORY; break; }
        if (count + received > capacity) {
            size_t next = capacity ? capacity * 2 : sizeof(chunk);
            if (next < count + received) next = count + received;
            void *grown = realloc(message, next);
            if (!grown) { failure = ERROR_NOT_ENOUGH_MEMORY; break; }
            message = (unsigned char *)grown; capacity = next;
        }
        if (received) memcpy(message + count, chunk, received);
        count += received;
        if (type == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE ||
            type == WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE) break;
    }
    ReleaseSRWLockExclusive(&state->read_lock);
    if (failure || *close_status) free(message);
    else { *data = message; *size = (uint32_t)count; *text = message_text == 1; }
    *error = failure;
    release(state);
    return failure == ERROR_SUCCESS;
}
void xtool_ws_release_data(void *data) { free(data); }
void xtool_ws_shutdown(xtool_websocket *state) {
    retain(state);
    if (!TryAcquireSRWLockExclusive(&state->write_lock)) {
        xtool_ws_abort(state);
        release(state);
        return;
    }
    AcquireSRWLockExclusive(&state->handles_lock);
    DWORD failure = ERROR_OPERATION_ABORTED;
    if (!atomic_read(&state->closed) && state->socket) {
        ResetEvent(state->shutdown_done);
        failure = WinHttpWebSocketShutdown(state->socket, WINHTTP_WEB_SOCKET_SUCCESS_CLOSE_STATUS, NULL, 0);
        if (failure == ERROR_IO_PENDING) failure = ERROR_SUCCESS;
    }
    ReleaseSRWLockExclusive(&state->handles_lock);
    if (!failure) (void)WaitForSingleObject(state->shutdown_done, 1000);
    ReleaseSRWLockExclusive(&state->write_lock);
    xtool_ws_abort(state);
    release(state);
}
#endif
