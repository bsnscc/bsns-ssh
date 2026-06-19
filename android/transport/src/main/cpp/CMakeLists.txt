cmake_minimum_required(VERSION 3.22.1)
project(sshbridge C CXX)

# Static libssh2 + OpenSSL (build-libssh2.sh) and mosh + protobuf-lite
# (build-mosh.sh), both built from source for ${ANDROID_ABI} under android/jni.
set(PREBUILT ${CMAKE_SOURCE_DIR}/../../../../jni/prebuilt/${ANDROID_ABI})

add_library(ssh2 STATIC IMPORTED)
set_target_properties(ssh2 PROPERTIES IMPORTED_LOCATION ${PREBUILT}/lib/libssh2.a)
add_library(ssl STATIC IMPORTED)
set_target_properties(ssl PROPERTIES IMPORTED_LOCATION ${PREBUILT}/lib/libssl.a)
add_library(crypto STATIC IMPORTED)
set_target_properties(crypto PROPERTIES IMPORTED_LOCATION ${PREBUILT}/lib/libcrypto.a)
add_library(mosh STATIC IMPORTED)
set_target_properties(mosh PROPERTIES IMPORTED_LOCATION ${PREBUILT}/lib/libmosh.a)

find_library(log-lib log)

add_library(sshbridge SHARED sshbridge.c mosh_bridge.cpp)
target_include_directories(sshbridge PRIVATE ${PREBUILT}/include)
# Align ELF segments to 16 KB so the library loads on Android's 16 KB-page
# devices (required by Google Play for apps targeting Android 15+). The bundled
# androidx .so is already 16 KB-aligned; this brings ours in line.
target_link_options(sshbridge PRIVATE "-Wl,-z,max-page-size=16384")
# Order matters for static linking: libssh2 → ssl/crypto/z; libmosh → crypto.
target_link_libraries(sshbridge mosh ssh2 ssl crypto z ${log-lib})
