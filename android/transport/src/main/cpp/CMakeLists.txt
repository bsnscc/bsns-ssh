cmake_minimum_required(VERSION 3.22.1)
project(sshbridge C)

# Static libssh2 + OpenSSL built from source by android/jni/build-libssh2.sh.
# CMAKE_SOURCE_DIR = .../transport/src/main/cpp ; the prebuilt tree is under android/jni.
set(PREBUILT ${CMAKE_SOURCE_DIR}/../../../../jni/prebuilt/${ANDROID_ABI})

add_library(ssh2 STATIC IMPORTED)
set_target_properties(ssh2 PROPERTIES IMPORTED_LOCATION ${PREBUILT}/lib/libssh2.a)
add_library(ssl STATIC IMPORTED)
set_target_properties(ssl PROPERTIES IMPORTED_LOCATION ${PREBUILT}/lib/libssl.a)
add_library(crypto STATIC IMPORTED)
set_target_properties(crypto PROPERTIES IMPORTED_LOCATION ${PREBUILT}/lib/libcrypto.a)

find_library(log-lib log)

add_library(sshbridge SHARED sshbridge.c)
target_include_directories(sshbridge PRIVATE ${PREBUILT}/include)
# Order matters for static linking: libssh2 depends on ssl/crypto/z.
target_link_libraries(sshbridge ssh2 ssl crypto z ${log-lib})
