// Hand-written replacement for mosh's autotools-generated config.h, targeting
// Android (Linux/bionic + the NDK's OpenSSL we already build for libssh2). The
// build (-I this dir first) shadows the iOS config.h in mosh-src/src/include.
// Counterpart of app/vendor/mosh/config-ios.h.
#ifndef BSNS_MOSH_CONFIG_H
#define BSNS_MOSH_CONFIG_H

#define PACKAGE_STRING "mosh 1.4.0"
#define PACKAGE_VERSION "1.4.0"
#define MOSH_VERSION "1.4.0"
#define _XOPEN_SOURCE 700
#define _DEFAULT_SOURCE 1

// Platform capabilities present on Android (Linux/bionic, API 26+).
#define HAVE_GETTIMEOFDAY 1
#define HAVE_CLOCK_GETTIME 1
#define HAVE_PSELECT 1
#define HAVE_POSIX_MEMALIGN 1
#define HAVE_SYS_UIO_H 1
#define HAVE_STRINGS_H 1
#define HAVE_LANGINFO_H 1
#define HAVE_CFMAKERAW 1
// bionic has no getentropy/getrandom below API 28; read /dev/urandom instead.
#define HAVE_URANDOM 1
#define HAVE_DECL___BUILTIN_BSWAP64 1
#define HAVE_DECL___BUILTIN_CTZ 1
#define HAVE_DECL_FFS 1

// Linux-only socket features mosh's network.cc uses (iOS lacks these; Android
// has them) — path-MTU discovery off + per-packet ECN/TOS.
#define HAVE_IP_MTU_DISCOVER 1
#define HAVE_IP_RECVTOS 1

// Use std::shared_ptr / std::make_shared (not the TR1 fallback) in shared.h.
#define HAVE_STD_SHARED_PTR 1

// Crypto: the bundled internal OCB over OpenSSL's AES (EVP) — no CommonCrypto.
// We link the same libcrypto.a built for libssh2.
#define USE_OPENSSL_AES 1
#define USE_APPLE_COMMON_CRYPTO_AES 0
#define USE_NETTLE_AES 0

#endif
