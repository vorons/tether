/* Compatibility shim: mbedTLS 3.6 removed deprecated APIs that libcurl-8.13
   references. No-op stubs so the vendored curl source compiles. */
#include <stddef.h>
#include <mbedtls/entropy.h>
#include <mbedtls/ssl.h>
#include <mbedtls/ssl_cookie.h>
#include <mbedtls/ssl_ticket.h>
#include <mbedtls/x509_crl.h>

int mbedtls_havege_init(void) { return 0; }
int mbedtls_havege_free(void) { return 0; }
