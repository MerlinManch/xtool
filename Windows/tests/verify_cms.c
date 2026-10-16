// Test-only cryptographic verification. The synthetic leaf is deliberately not
// Apple-trusted: verify the detached signature, not its certification path.
#include <stdio.h>
#include <wchar.h>
#include <openssl/cms.h>
#include <openssl/err.h>

int wmain(int argc, wchar_t **argv) {
    if (argc != 3) return 2;
    FILE *signature_file = NULL, *content_file = NULL;
    if (_wfopen_s(&signature_file, argv[1], L"rb") != 0) return 2;
    if (_wfopen_s(&content_file, argv[2], L"rb") != 0) { fclose(signature_file); return 2; }
    BIO *signature = BIO_new_fp(signature_file, BIO_CLOSE);
    BIO *content = BIO_new_fp(content_file, BIO_CLOSE);
    if (!signature) fclose(signature_file);
    if (!content) fclose(content_file);
    CMS_ContentInfo *cms = signature ? d2i_CMS_bio(signature, NULL) : NULL;
    int verified = cms && content && CMS_verify(cms, NULL, NULL, content, NULL,
                                                CMS_NO_SIGNER_CERT_VERIFY | CMS_BINARY | CMS_DETACHED);
    if (!verified) ERR_print_errors_fp(stderr);
    CMS_ContentInfo_free(cms);
    BIO_free(signature);
    BIO_free(content);
    return verified ? 0 : 1;
}
