// Test-only cryptographic verification. The synthetic leaf is deliberately not
// Apple-trusted: verify the detached signature, not its certification path.
#include <stdio.h>
#include <stdlib.h>
#include <limits.h>
#include <wchar.h>
#include <openssl/cms.h>
#include <openssl/err.h>

static unsigned char *read_file(const wchar_t *path, int *count) {
    FILE *file = NULL;
    if (_wfopen_s(&file, path, L"rb") != 0) return NULL;
    if (_fseeki64(file, 0, SEEK_END) != 0) { fclose(file); return NULL; }
    __int64 length = _ftelli64(file);
    if (length <= 0 || length > INT_MAX || _fseeki64(file, 0, SEEK_SET) != 0) {
        fclose(file); return NULL;
    }
    unsigned char *bytes = (unsigned char *)malloc((size_t)length);
    if (!bytes || fread(bytes, 1, (size_t)length, file) != (size_t)length) {
        free(bytes); fclose(file); return NULL;
    }
    fclose(file);
    *count = (int)length;
    return bytes;
}
int wmain(int argc, wchar_t **argv) {
    if (argc != 3) return 2;
    int signature_size = 0, content_size = 0;
    unsigned char *signature_data = read_file(argv[1], &signature_size);
    unsigned char *content_data = read_file(argv[2], &content_size);
    // Never pass CRT FILE pointers into the OpenSSL DLL: memory BIOs keep the
    // verifier independent of OpenSSL's optional Windows Applink mechanism.
    BIO *signature = signature_data ? BIO_new_mem_buf(signature_data, signature_size) : NULL;
    BIO *content = content_data ? BIO_new_mem_buf(content_data, content_size) : NULL;
    CMS_ContentInfo *cms = signature ? d2i_CMS_bio(signature, NULL) : NULL;
    int verified = cms && content && CMS_verify(cms, NULL, NULL, content, NULL,
                                                CMS_NO_SIGNER_CERT_VERIFY | CMS_BINARY | CMS_DETACHED);
    if (!verified) {
        unsigned long error;
        while ((error = ERR_get_error()) != 0) {
            char description[256];
            ERR_error_string_n(error, description, sizeof(description));
            fprintf(stderr, "%s\n", description);
        }
    }
    CMS_ContentInfo_free(cms);
    BIO_free(signature); BIO_free(content);
    free(signature_data); free(content_data);
    return verified ? 0 : 1;
}
