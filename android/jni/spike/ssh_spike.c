// Transport spike: prove the NDK-built libssh2 + OpenSSL stack connects,
// handshakes, authenticates, and execs against a real SSH server from Android
// arm64. Password auth here only de-risks the crypto/runtime/networking; the
// agent sign-callback to a Keystore key is the next (JNI) layer.
#include <libssh2.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char** argv) {
    const char* host = argc > 1 ? argv[1] : "10.0.2.2";
    int port         = argc > 2 ? atoi(argv[2]) : 2222;
    const char* user = argc > 3 ? argv[3] : "tester";
    const char* pass = argc > 4 ? argv[4] : "testpw";

    if (libssh2_init(0)) { printf("FAIL: libssh2_init\n"); return 1; }

    int sock = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in sin;
    memset(&sin, 0, sizeof(sin));
    sin.sin_family = AF_INET;
    sin.sin_port = htons(port);
    if (inet_pton(AF_INET, host, &sin.sin_addr) != 1) { printf("FAIL: bad host\n"); return 1; }
    if (connect(sock, (struct sockaddr*)&sin, sizeof(sin))) { printf("FAIL: connect %s:%d\n", host, port); return 1; }

    LIBSSH2_SESSION* s = libssh2_session_init();
    libssh2_session_set_blocking(s, 1);
    if (libssh2_session_handshake(s, sock)) { printf("FAIL: handshake\n"); return 1; }
    printf("handshake ok; server kex banner: %s\n", libssh2_session_banner_get(s));

    if (libssh2_userauth_password(s, user, pass)) { printf("FAIL: password auth\n"); return 1; }
    printf("auth ok as %s\n", user);

    LIBSSH2_CHANNEL* c = libssh2_channel_open_session(s);
    if (!c) { printf("FAIL: channel\n"); return 1; }
    libssh2_channel_exec(c, "echo HELLO_FROM_ANDROID_LIBSSH2; uname -m");
    char buf[1024]; int n;
    while ((n = libssh2_channel_read(c, buf, sizeof(buf) - 1)) > 0) { buf[n] = 0; printf("%s", buf); }
    libssh2_channel_close(c);
    libssh2_channel_free(c);
    libssh2_session_disconnect(s, "bye");
    libssh2_session_free(s);
    close(sock);
    libssh2_exit();
    printf("SPIKE_OK client libssh2 %s\n", libssh2_version(0));
    return 0;
}
