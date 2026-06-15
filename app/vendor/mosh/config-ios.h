// Hand-written replacement for mosh's autotools-generated config.h, targeting
// iOS. Copied to mosh-src/src/include/config.h by fetch-mosh.sh.
#ifndef BSNS_MOSH_CONFIG_H
#define BSNS_MOSH_CONFIG_H

#define PACKAGE_STRING "mosh 1.4.0"
#define PACKAGE_VERSION "1.4.0"
#define MOSH_VERSION "1.4.0"
#define _XOPEN_SOURCE 700

// Platform capabilities present on iOS / Darwin.
#define HAVE_GETTIMEOFDAY 1
#define HAVE_CLOCK_GETTIME 1
#define HAVE_PSELECT 1
#define HAVE_POSIX_MEMALIGN 1
#define HAVE_SYS_UIO_H 1
#define HAVE_STRINGS_H 1
#define HAVE_LANGINFO_H 1
// iOS has no <sys/random.h> and doesn't declare getentropy/getrandom, so the
// PRNG reads /dev/urandom (accessible from the iOS sandbox).
#define HAVE_URANDOM 1
#define HAVE_CFMAKERAW 1
#define HAVE_MACH_ABSOLUTE_TIME 1
#define HAVE_OSX_SWAP 1
#define HAVE_DECL___BUILTIN_BSWAP64 1
#define HAVE_DECL___BUILTIN_CTZ 1
#define HAVE_DECL_FFS 1

// Use std::shared_ptr / std::make_shared (not the TR1 fallback) in shared.h.
#define HAVE_STD_SHARED_PTR 1

// Crypto: use Apple CommonCrypto's AES for the bundled OCB (no OpenSSL).
#define USE_APPLE_COMMON_CRYPTO_AES 1
#define USE_OPENSSL_AES 0
#define USE_NETTLE_AES 0

#endif
