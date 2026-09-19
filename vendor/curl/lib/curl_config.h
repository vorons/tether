/* Hand-crafted curl_config.h for static vendored build
   Linux x86_64 glibc, mbedTLS backend, no autotools. */
#ifndef CURL_CURL_CONFIG_H
#define CURL_CURL_CONFIG_H

#define USE_MBEDTLS 1
#define USE_ZLIB 1
#define HAVE_CONFIG_H 1

#define SIZEOF_CURL_OFF_T 8
#define SIZEOF_OFF_T 8
#define CURL_TYPEOF_CURL_OFF_T "long"
#define CURL_SUFFIX_CURL_OFF_TU "UL"
#define CURL_TYPEOF_CURL_SSIZE_T "long"
#define CURL_SUFFIX_CURL_SSIZE_T "L"
#define CURL_FORMAT_CURL_OFF_T   "ld"
#define CURL_FORMAT_CURL_OFF_TU "lu"

/* headers */
#define HAVE_NETINET_IN_H        1
#define HAVE_NETINET_TCP_H       1
#define HAVE_NETINET_UDP_H       1

#define HAVE_SYS_TYPES_H         1
#define HAVE_SYS_SOCKET_H        1
#define HAVE_SYS_SELECT_H        1
#define HAVE_POLL_H             1
#define HAVE_SELECT              1
#define HAVE_SYS_TIME_H          1
#define HAVE_FCNTL_H             1
#define HAVE_FCNTL               1
#define HAVE_FCNTL_O_NONBLOCK    1
#define HAVE_SYS_STAT_H          1
#define HAVE_STAT_H              1
#define HAVE_UNISTD_H            1
#define HAVE_ERRNO_H             1
#define HAVE_STDINT_H            1
#define HAVE_STDDEF_H            1
#define HAVE_STDIO_H             1
#define HAVE_STRING_H            1
#define HAVE_STDLIB_H            1
#define HAVE_STRINGS_H           1
#define HAVE_TIME_H              1
#define HAVE_LIMITS_H            1
#define HAVE_INTTYPES_H          1
#define HAVE_PWD_H               1
#define HAVE_SYS_UN_H            1
#define HAVE_NETDB_H             1
#define HAVE_ARPA_INET_H         1
#define HAVE_PTHREAD_H           1
#define HAVE_POLL_H              1
#define HAVE_SELECT_H            1
#define HAVE_SOCKETS_H           1
#define HAVE_ZLIB_H              1
#define HAVE_LIBZ                1
#define HAVE_STRUCT_TIMEVAL      1
#define HAVE_LOCALTIME_R         1
#define HAVE_GMTIME_R            1
#define HAVE_GETNAMEINFO         1
#define HAVE_FREEADDRINFO        1
#define HAVE_GETADDRINFO         1
#define HAVE_SOCKETPAIR          1
#define HAVE_SOCKET                1
#define HAVE_CONNECT               1
#define HAVE_CLOSE                 1
#define HAVE_BIND                  1
#define HAVE_LISTEN                1
#define HAVE_ACCEPT                1
#define HAVE_SIGPIPE             1
#define HAVE_STDBOOL_H           1
#define HAVE_BOOL_T              1
#define USE_UNIX_SOCKETS          1
#define HAVE_NANOSLEEP           1
#define HAVE_SIGACTION           1
#define HAVE_MKSTEMP             1
#define HAVE_MKSTEMPS            0
#define HAVE_STRERROR_R          1
#define HAVE_GLIBC_STRERROR_R    1
#define HAVE_CLOCK_GETTIME       1
#define HAVE_CLOCK_GETTIME_MONOTONIC 1

/* socket API */
#define HAVE_SEND                1
#define HAVE_RECV                1
#define RECV_TYPE_ARG1           int
#define RECV_TYPE_ARG2           void *
#define RECV_TYPE_ARG3           size_t
#define RECV_TYPE_ARG4           int
#define RECV_TYPE_RETV           ssize_t
#define SEND_TYPE_ARG1           int
#define SEND_TYPE_ARG2           const void *
#define SEND_TYPE_ARG3           size_t
#define SEND_TYPE_ARG4           int
#define SEND_TYPE_RETV           ssize_t
#define SEND_QUAL_ARG2
#define SEND_4TH_ARG             0
#define SEND_ERR_ERRORS          EAGAIN
#define RECV_ERR_ERRORS          ECONNRESET

/* ssl / feature flags */
#define USE_MBEDTLS             1
#define USE_NTLM                1
#define CURL_DISABLE_IMAP       1
#define CURL_DISABLE_SMTP       1
#define CURL_DISABLE_POP3       1
#define CURL_DISABLE_LDAP       1
#define CURL_OS "linux-x86_64"
#define HAVE_LDAP                  0
#define HAVE_LIBSSH2            0
#define HAVE_ICU                0
/* Keep HAVE_LIBZSTD / HAVE_BROTLI *undefined*: curl guards those blocks with
   #ifdef, so defining them to 0 still compiles the code in and leaves
   undefined references to BrotliDecoderVersion / ZSTD_versionString. */
#undef HAVE_LIBZSTD
#undef HAVE_BROTLI
#define ENABLE_IPV6             1
#define CURLDEBUG               0

#endif
