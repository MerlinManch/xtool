#ifdef _WIN32
#if !defined(_WIN32_WINNT) || _WIN32_WINNT < 0x0603
#undef _WIN32_WINNT
#define _WIN32_WINNT 0x0603
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>
#include <stdlib.h>
#include <string.h>
#include "CWindowsWebSocket.h"

typedef struct callback_context {
    struct xtool_websocket *owner;
    int socket;
} callback_context;

struct xtool_websocket {
    SRWLOCK handles_lock, read_lock, write_lock;
    HINTERNET session, connection, request, socket;
    HANDLE open_done, read_done, write_done, shutdown_done;
    volatile LONG references, closed, attempted;
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
        }
        release(state);
        return;
    }
    if (!context->socket) {
        if (status == WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE ||
            status == WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE) {
            complete(&state->open_error, state->open_done, ERROR_SUCCESS);
        } else if (status == WINHTTP_CALLBACK_STATUS_REQUEST_ERROR &&
                   length >= sizeof(WINHTTP_ASYNC_RESULT)) {
            complete(&state->open_error, state->open_done,
                     ((WINHTTP_ASYNC_RESULT *)information)->dwError);
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
    // Calls that issue asynchronous operations and CloseHandle are serialized.
    // Callbacks never acquire this lock and keep the state alive independently.
    if (state->socket) { WinHttpCloseHandle(state->socket); state->socket = NULL; }
    if (state->request) { WinHttpCloseHandle(state->request); state->request = NULL; }
    if (state->connection) { WinHttpCloseHandle(state->connection); state->connection = NULL; }
    if (state->session) { WinHttpCloseHandle(state->session); state->session = NULL; }
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
int xtool_ws_connect(xtool_websocket *state, const uint16_t *url, uint32_t *error, uint32_t *http_status) {
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
        state->session = WinHttpOpen(L"xtool", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                                     WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, WINHTTP_FLAG_ASYNC);
        if (!state->session) failure = GetLastError();
        if (!failure && !WinHttpSetTimeouts(state->session, 10000, 10000, 30000, 30000)) failure = GetLastError();
        if (!failure) {
            state->connection = WinHttpConnect(state->session, host, parts.nPort, 0);
            if (!state->connection) failure = GetLastError();
        }
        if (!failure) {
            state->request = WinHttpOpenRequest(state->connection, L"GET", path, NULL,
                WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                parts.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0);
            if (!state->request) failure = GetLastError();
        }
        if (!failure && !attach(state, state->request, &state->request_context)) failure = GetLastError();
        if (!failure && !WinHttpSetOption(state->request, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, NULL, 0))
            failure = GetLastError();
        if (!failure && parts.dwUserNameLength &&
            !WinHttpSetCredentials(state->request, WINHTTP_AUTH_TARGET_SERVER, WINHTTP_AUTH_SCHEME_BASIC,
                                   user, password, NULL)) failure = GetLastError();
        if (!failure) {
            ResetEvent(state->open_done);
            if (!WinHttpSendRequest(state->request, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                WINHTTP_NO_REQUEST_DATA, 0, 0, (DWORD_PTR)&state->request_context)) {
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
            if (status != 101) failure = ERROR_WINHTTP_INVALID_SERVER_RESPONSE;
        }
        if (!failure) {
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
