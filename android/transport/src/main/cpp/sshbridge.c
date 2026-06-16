// JNI bridge over libssh2: the Android equivalent of the iOS AgentSignBridge.
// Public-key auth's sign callback calls back into Kotlin, which signs with a
// non-extractable Android Keystore key — the private key never touches the
// transport. (Spike: also installs the pubkey via password first.)
#include <jni.h>
#include <libssh2.h>
#include <libssh2_sftp.h>
#include <android/log.h>
#include <netdb.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>

#define LOG(...) __android_log_print(ANDROID_LOG_INFO, "sshbridge", __VA_ARGS__)

static int tcp_connect(const char* host, int port) {
    struct addrinfo hints, *res;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    char portstr[16];
    snprintf(portstr, sizeof(portstr), "%d", port);
    if (getaddrinfo(host, portstr, &hints, &res) != 0) return -1;
    int fd = -1;
    for (struct addrinfo* p = res; p; p = p->ai_next) {
        fd = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
        if (fd < 0) continue;
        if (connect(fd, p->ai_addr, p->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    return fd;
}

// Modern SSH algorithm allowlist — no SHA-1, CBC, or 3DES (parity with iOS
// applyAlgorithmPolicy). method_pref fails only if NONE of a list is supported,
// so unsupported entries are ignored and a fully-unsupported list fails closed.
static int apply_algorithm_policy(LIBSSH2_SESSION* s) {
    const char* kex =
        "curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256,"
        "ecdh-sha2-nistp384,ecdh-sha2-nistp521,diffie-hellman-group-exchange-sha256,"
        "diffie-hellman-group16-sha512,diffie-hellman-group14-sha256";
    const char* hostkey =
        "ssh-ed25519,ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,ecdsa-sha2-nistp521,"
        "rsa-sha2-512,rsa-sha2-256";
    const char* ciphers =
        "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,"
        "aes256-ctr,aes192-ctr,aes128-ctr";
    const char* macs =
        "hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,"
        "hmac-sha2-256,hmac-sha2-512";
    if (libssh2_session_method_pref(s, LIBSSH2_METHOD_KEX, kex)) return -1;
    if (libssh2_session_method_pref(s, LIBSSH2_METHOD_HOSTKEY, hostkey)) return -1;
    if (libssh2_session_method_pref(s, LIBSSH2_METHOD_CRYPT_CS, ciphers)) return -1;
    if (libssh2_session_method_pref(s, LIBSSH2_METHOD_CRYPT_SC, ciphers)) return -1;
    if (libssh2_session_method_pref(s, LIBSSH2_METHOD_MAC_CS, macs)) return -1;
    if (libssh2_session_method_pref(s, LIBSSH2_METHOD_MAC_SC, macs)) return -1;
    return 0;
}

static LIBSSH2_SESSION* open_session(int fd) {
    LIBSSH2_SESSION* s = libssh2_session_init();
    if (!s) return NULL;
    libssh2_session_set_blocking(s, 1);
    if (apply_algorithm_policy(s) != 0) {        // fail closed — never fall back to weak defaults
        LOG("algorithm policy could not be applied — refusing");
        libssh2_session_free(s); return NULL;
    }
    if (libssh2_session_handshake(s, fd)) { libssh2_session_free(s); return NULL; }
    return s;
}

typedef struct { JNIEnv* env; jobject signer; jmethodID sign; } SignCtx;

// libssh2 calls this to sign the auth challenge. We hand `data` to Kotlin's
// signer.sign([B)[B, which signs in the Keystore and returns the SSH signature
// body; libssh2 frames it with the algorithm name.
static int sign_cb(LIBSSH2_SESSION* session, unsigned char** sig, size_t* sig_len,
                   const unsigned char* data, size_t data_len, void** abstract) {
    (void)session;
    SignCtx* c = (SignCtx*)(*abstract);
    JNIEnv* env = c->env;
    jbyteArray jdata = (*env)->NewByteArray(env, (jsize)data_len);
    (*env)->SetByteArrayRegion(env, jdata, 0, (jsize)data_len, (const jbyte*)data);
    jbyteArray jbody = (jbyteArray)(*env)->CallObjectMethod(env, c->signer, c->sign, jdata);
    (*env)->DeleteLocalRef(env, jdata);
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); return -1; }
    if (!jbody) return -1;
    jsize n = (*env)->GetArrayLength(env, jbody);
    unsigned char* buf = (unsigned char*)malloc((size_t)n);
    if (!buf) return -1;
    (*env)->GetByteArrayRegion(env, jbody, 0, n, (jbyte*)buf);
    (*env)->DeleteLocalRef(env, jbody);
    *sig = buf;
    *sig_len = (size_t)n;
    return 0;
}

JNIEXPORT jboolean JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeInstallKey(
    JNIEnv* env, jobject thiz, jstring jhost, jint port, jstring juser,
    jstring jpassword, jstring jauthLine, jbyteArray jexpectedHostKey) {
    (void)thiz;
    if (libssh2_init(0)) return JNI_FALSE;
    const char* host = (*env)->GetStringUTFChars(env, jhost, 0);
    const char* user = (*env)->GetStringUTFChars(env, juser, 0);
    const char* pass = (*env)->GetStringUTFChars(env, jpassword, 0);
    const char* line = (*env)->GetStringUTFChars(env, jauthLine, 0);
    jboolean ok = JNI_FALSE;
    int fd = tcp_connect(host, port);
    if (fd >= 0) {
        LIBSSH2_SESSION* s = open_session(fd);
        if (s && jexpectedHostKey != NULL) {
            // Pin the host key BEFORE sending the password — never hand a reusable
            // server password to an unverified (possibly wrong) host.
            size_t hklen = 0; int hktype = 0;
            const char* hk = libssh2_session_hostkey(s, &hklen, &hktype);
            jsize explen = (*env)->GetArrayLength(env, jexpectedHostKey);
            jbyte* exp = (*env)->GetByteArrayElements(env, jexpectedHostKey, 0);
            int mismatch = (!hk || (jsize)hklen != explen || memcmp(hk, exp, hklen) != 0);
            (*env)->ReleaseByteArrayElements(env, jexpectedHostKey, exp, JNI_ABORT);
            if (mismatch) {
                LOG("installKey: host key mismatch — refusing");
                libssh2_session_disconnect(s, "host key mismatch");
                libssh2_session_free(s); s = NULL;
            }
        }
        if (s) {
            if (libssh2_userauth_password(s, user, pass) == 0) {
                LIBSSH2_CHANNEL* c = libssh2_channel_open_session(s);
                if (c) {
                    char cmd[8192];
                    snprintf(cmd, sizeof(cmd),
                             "mkdir -p ~/.ssh && chmod 700 ~/.ssh && "
                             "printf '%%s\\n' \"%s\" >> ~/.ssh/authorized_keys && "
                             "chmod 600 ~/.ssh/authorized_keys && echo INSTALLED", line);
                    libssh2_channel_exec(c, cmd);
                    char buf[256];
                    int n;
                    while ((n = libssh2_channel_read(c, buf, sizeof(buf) - 1)) > 0) {
                        buf[n] = 0;
                        if (strstr(buf, "INSTALLED")) ok = JNI_TRUE;
                    }
                    libssh2_channel_close(c);
                    libssh2_channel_free(c);
                }
            } else {
                LOG("install: password auth failed");
            }
            libssh2_session_disconnect(s, "bye");
            libssh2_session_free(s);
        }
        close(fd);
    }
    (*env)->ReleaseStringUTFChars(env, jhost, host);
    (*env)->ReleaseStringUTFChars(env, juser, user);
    (*env)->ReleaseStringUTFChars(env, jpassword, pass);
    (*env)->ReleaseStringUTFChars(env, jauthLine, line);
    return ok;
}

JNIEXPORT jstring JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeAuthAndExec(
    JNIEnv* env, jobject thiz, jstring jhost, jint port, jstring juser,
    jbyteArray jpubblob, jobject signer, jstring jcmd, jbyteArray jexpectedHostKey) {
    (void)thiz;
    if (libssh2_init(0)) return NULL;
    const char* host = (*env)->GetStringUTFChars(env, jhost, 0);
    const char* user = (*env)->GetStringUTFChars(env, juser, 0);
    const char* cmd = (*env)->GetStringUTFChars(env, jcmd, 0);
    jsize bloblen = (*env)->GetArrayLength(env, jpubblob);
    jbyte* blob = (*env)->GetByteArrayElements(env, jpubblob, 0);
    jstring result = NULL;
    int fd = tcp_connect(host, port);
    if (fd >= 0) {
        LIBSSH2_SESSION* s = open_session(fd);
        if (s && jexpectedHostKey != NULL) {
            // Pin the host key (the mosh bootstrap runs after the connect screen's
            // TOFU check — refuse if the key changed underneath us).
            size_t hklen = 0; int hktype = 0;
            const char* hk = libssh2_session_hostkey(s, &hklen, &hktype);
            jsize explen = (*env)->GetArrayLength(env, jexpectedHostKey);
            jbyte* exp = (*env)->GetByteArrayElements(env, jexpectedHostKey, 0);
            int mismatch = (!hk || (jsize)hklen != explen || memcmp(hk, exp, hklen) != 0);
            (*env)->ReleaseByteArrayElements(env, jexpectedHostKey, exp, JNI_ABORT);
            if (mismatch) {
                LOG("authAndExec: host key mismatch — refusing");
                libssh2_session_disconnect(s, "host key mismatch");
                libssh2_session_free(s);
                s = NULL;
            }
        }
        if (s) {
            jclass cls = (*env)->GetObjectClass(env, signer);
            jmethodID sign = (*env)->GetMethodID(env, cls, "sign", "([B)[B");
            SignCtx ctx = { env, signer, sign };
            void* abstract = &ctx;
            int rc = libssh2_userauth_publickey(s, user, (const unsigned char*)blob,
                                                (size_t)bloblen, sign_cb, &abstract);
            if (rc == 0) {
                LIBSSH2_CHANNEL* c = libssh2_channel_open_session(s);
                if (c) {
                    libssh2_channel_exec(c, cmd);
                    char out[4096];
                    int total = 0, n;
                    while (total < (int)sizeof(out) - 1 &&
                           (n = libssh2_channel_read(c, out + total, sizeof(out) - 1 - total)) > 0) {
                        total += n;
                    }
                    out[total > 0 ? total : 0] = 0;
                    result = (*env)->NewStringUTF(env, out);
                    libssh2_channel_close(c);
                    libssh2_channel_free(c);
                }
            } else {
                char* msg = NULL;
                libssh2_session_last_error(s, &msg, NULL, 0);
                LOG("pubkey auth failed rc=%d: %s", rc, msg ? msg : "");
            }
            libssh2_session_disconnect(s, "bye");
            libssh2_session_free(s);
        }
        close(fd);
    }
    (*env)->ReleaseStringUTFChars(env, jhost, host);
    (*env)->ReleaseStringUTFChars(env, juser, user);
    (*env)->ReleaseStringUTFChars(env, jcmd, cmd);
    (*env)->ReleaseByteArrayElements(env, jpubblob, blob, JNI_ABORT);
    return result;
}

// Connect + handshake only, return the server's host-key blob (SSH wire format)
// so the app can fingerprint it (TOFU). Returns null if unreachable.
JNIEXPORT jbyteArray JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeHostKeyBlob(
    JNIEnv* env, jobject thiz, jstring jhost, jint port) {
    (void)thiz;
    if (libssh2_init(0)) return NULL;
    const char* host = (*env)->GetStringUTFChars(env, jhost, 0);
    jbyteArray result = NULL;
    int fd = tcp_connect(host, port);
    if (fd >= 0) {
        LIBSSH2_SESSION* s = open_session(fd);   // performs the handshake
        if (s) {
            size_t len = 0;
            int type = 0;
            const char* key = libssh2_session_hostkey(s, &len, &type);
            if (key && len > 0) {
                result = (*env)->NewByteArray(env, (jsize)len);
                (*env)->SetByteArrayRegion(env, result, 0, (jsize)len, (const jbyte*)key);
            }
            libssh2_session_disconnect(s, "bye");
            libssh2_session_free(s);
        }
        close(fd);
    }
    (*env)->ReleaseStringUTFChars(env, jhost, host);
    return result;
}

// ---- Interactive PTY session ---------------------------------------------
// A session handle (returned as a jlong) the UI drives with write/read/resize.
// Auth + setup run blocking; then the channel goes non-blocking so reads don't
// hang. The caller owns one thread for the session (libssh2 sessions aren't
// thread-safe), matching the iOS SSHShell model.

// Defined later (the SFTP/forward path's shared connect helper).
static LIBSSH2_SESSION* connect_and_auth(JNIEnv* env, const char* host, int port,
        const char* user, const unsigned char* blob, size_t bloblen, jobject signer,
        jbyteArray jexpectedHostKey, int* out_fd);

// ---- ProxyJump / host chaining ------------------------------------------
// To reach a target through a bastion, we authenticate to the bastion, open a
// direct-tcpip channel to the target, and relay that channel over a socketpair.
// The target SSH handshake then runs over the socketpair fd end-to-end, so the
// target's host key is verified through the tunnel (a malicious bastion can't
// impersonate the target). The bastion's own key is trust-on-first-use for now
// (no UI pinning of the jump host yet — a documented v1 limitation).
typedef struct {
    LIBSSH2_SESSION* session;   // session to the bastion
    LIBSSH2_CHANNEL* channel;   // direct-tcpip bastion -> target
    int jump_fd;                // TCP socket to the bastion
    int pump_fd;                // pump-side end of the socketpair
    pthread_t pump;
    volatile int stop;
} JumpChain;

typedef struct { int fd; LIBSSH2_SESSION* session; LIBSSH2_CHANNEL* channel; JumpChain* jump; } SshClient;

// Relay bytes between the local socketpair end and the bastion's tunnel channel
// until either side closes. Owns the bastion session exclusively (libssh2 isn't
// thread-safe per session, so nothing else touches it once the pump runs).
static void* jump_pump(void* arg) {
    JumpChain* j = (JumpChain*)arg;
    libssh2_session_set_blocking(j->session, 0);
    char buf[16384];
    while (!j->stop) {
        int idle = 1;
        ssize_t n = libssh2_channel_read(j->channel, buf, sizeof(buf));   // bastion -> local
        if (n > 0) {
            idle = 0;
            ssize_t off = 0;
            while (off < n) {
                ssize_t w = write(j->pump_fd, buf + off, (size_t)(n - off));
                if (w < 0) { if (errno == EINTR) continue; j->stop = 1; break; }
                off += w;
            }
        } else if (n != LIBSSH2_ERROR_EAGAIN && (n < 0 || libssh2_channel_eof(j->channel))) {
            j->stop = 1; break;
        }
        ssize_t m = read(j->pump_fd, buf, sizeof(buf));                   // local -> bastion
        if (m > 0) {
            idle = 0;
            ssize_t off = 0;
            while (off < m) {
                ssize_t w = libssh2_channel_write(j->channel, buf + off, (size_t)(m - off));
                if (w == LIBSSH2_ERROR_EAGAIN) continue;
                if (w < 0) { j->stop = 1; break; }
                off += w;
            }
        } else if (m == 0) {
            j->stop = 1; break;   // local end closed
        } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            j->stop = 1; break;
        }
        if (idle) usleep(2000);   // nothing moved — yield rather than spin
    }
    return NULL;
}

// Build a tunneled fd to `dhost:dport` via the bastion. Returns the target-side
// socketpair fd (hand to open_session) and the JumpChain to free on close, or -1.
static int open_jump_fd(JNIEnv* env, const char* jhost, int jport, const char* juser,
                        const char* dhost, int dport,
                        const unsigned char* blob, size_t bloblen, jobject signer,
                        JumpChain** out) {
    int jfd = -1;
    LIBSSH2_SESSION* js = connect_and_auth(env, jhost, jport, juser, blob, bloblen, signer, NULL, &jfd);
    if (!js) { LOG("jump: connect/auth to bastion %s:%d failed", jhost, jport); return -1; }
    LIBSSH2_CHANNEL* ch = libssh2_channel_direct_tcpip_ex(js, dhost, dport, "127.0.0.1", 22);
    if (!ch) {
        LOG("jump: direct-tcpip to %s:%d failed", dhost, dport);
        libssh2_session_disconnect(js, "bye"); libssh2_session_free(js); close(jfd); return -1;
    }
    int sp[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sp) != 0) {
        libssh2_channel_free(ch); libssh2_session_disconnect(js, "bye"); libssh2_session_free(js); close(jfd); return -1;
    }
    fcntl(sp[1], F_SETFL, O_NONBLOCK);   // pump side non-blocking
    JumpChain* j = (JumpChain*)calloc(1, sizeof(JumpChain));
    j->session = js; j->channel = ch; j->jump_fd = jfd; j->pump_fd = sp[1]; j->stop = 0;
    if (pthread_create(&j->pump, NULL, jump_pump, j) != 0) {
        free(j); close(sp[0]); close(sp[1]);
        libssh2_channel_free(ch); libssh2_session_disconnect(js, "bye"); libssh2_session_free(js); close(jfd); return -1;
    }
    *out = j;
    return sp[0];   // target-side fd for the end-to-end handshake
}

static void jump_free(JumpChain* j) {
    if (!j) return;
    j->stop = 1;
    pthread_join(j->pump, NULL);
    if (j->channel) { libssh2_channel_close(j->channel); libssh2_channel_free(j->channel); }
    if (j->session) { libssh2_session_disconnect(j->session, "bye"); libssh2_session_free(j->session); }
    if (j->pump_fd >= 0) close(j->pump_fd);
    if (j->jump_fd >= 0) close(j->jump_fd);
    free(j);
}

// Fetch the target's host key THROUGH a bastion, so TOFU shows/approves the real
// target fingerprint even when the target isn't directly reachable. Needs the
// signer to authenticate to the bastion.
JNIEXPORT jbyteArray JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeHostKeyBlobVia(
    JNIEnv* env, jobject thiz, jstring jhost, jint port,
    jstring jjumpHost, jint jumpPort, jstring jjumpUser,
    jbyteArray jpubblob, jobject signer) {
    (void)thiz;
    if (libssh2_init(0)) return NULL;
    const char* host = (*env)->GetStringUTFChars(env, jhost, 0);
    const char* jh = (*env)->GetStringUTFChars(env, jjumpHost, 0);
    const char* ju = (*env)->GetStringUTFChars(env, jjumpUser, 0);
    jsize bloblen = (*env)->GetArrayLength(env, jpubblob);
    jbyte* blob = (*env)->GetByteArrayElements(env, jpubblob, 0);
    jbyteArray result = NULL;
    JumpChain* jump = NULL;
    int fd = open_jump_fd(env, jh, jumpPort, ju, host, port,
                          (const unsigned char*)blob, (size_t)bloblen, signer, &jump);
    if (fd >= 0) {
        LIBSSH2_SESSION* s = open_session(fd);
        if (s) {
            size_t len = 0; int type = 0;
            const char* key = libssh2_session_hostkey(s, &len, &type);
            if (key && len > 0) {
                result = (*env)->NewByteArray(env, (jsize)len);
                (*env)->SetByteArrayRegion(env, result, 0, (jsize)len, (const jbyte*)key);
            }
            libssh2_session_disconnect(s, "bye"); libssh2_session_free(s);
        }
        close(fd);
        if (jump) jump_free(jump);
    }
    (*env)->ReleaseStringUTFChars(env, jhost, host);
    (*env)->ReleaseStringUTFChars(env, jjumpHost, jh);
    (*env)->ReleaseStringUTFChars(env, jjumpUser, ju);
    (*env)->ReleaseByteArrayElements(env, jpubblob, blob, JNI_ABORT);
    return result;
}

JNIEXPORT jlong JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeOpenShell(
    JNIEnv* env, jobject thiz, jstring jhost, jint port, jstring juser,
    jbyteArray jpubblob, jobject signer, jint cols, jint rows, jbyteArray jexpectedHostKey,
    jstring jjumpHost, jint jumpPort, jstring jjumpUser) {
    (void)thiz;
    if (libssh2_init(0)) return 0;
    const char* host = (*env)->GetStringUTFChars(env, jhost, 0);
    const char* user = (*env)->GetStringUTFChars(env, juser, 0);
    jsize bloblen = (*env)->GetArrayLength(env, jpubblob);
    jbyte* blob = (*env)->GetByteArrayElements(env, jpubblob, 0);
    SshClient* client = NULL;
    JumpChain* jump = NULL;
    int fd;
    if (jjumpHost != NULL) {
        // Reach the target through a bastion (ProxyJump). Same key auths both hops.
        const char* jh = (*env)->GetStringUTFChars(env, jjumpHost, 0);
        const char* ju = (*env)->GetStringUTFChars(env, jjumpUser, 0);
        fd = open_jump_fd(env, jh, jumpPort, ju, host, port,
                          (const unsigned char*)blob, (size_t)bloblen, signer, &jump);
        (*env)->ReleaseStringUTFChars(env, jjumpHost, jh);
        (*env)->ReleaseStringUTFChars(env, jjumpUser, ju);
    } else {
        fd = tcp_connect(host, port);
    }
    if (fd >= 0) {
        LIBSSH2_SESSION* s = open_session(fd);
        if (s && jexpectedHostKey != NULL) {
            // Defense in depth: the session's actual host key must match what the
            // app trusted (guards against a swap between the TOFU check and now).
            size_t hklen = 0; int hktype = 0;
            const char* hk = libssh2_session_hostkey(s, &hklen, &hktype);
            jsize explen = (*env)->GetArrayLength(env, jexpectedHostKey);
            jbyte* exp = (*env)->GetByteArrayElements(env, jexpectedHostKey, 0);
            int mismatch = (!hk || (jsize)hklen != explen || memcmp(hk, exp, hklen) != 0);
            (*env)->ReleaseByteArrayElements(env, jexpectedHostKey, exp, JNI_ABORT);
            if (mismatch) {
                LOG("host key mismatch — refusing");
                libssh2_session_disconnect(s, "host key mismatch");
                libssh2_session_free(s);
                s = NULL;
            }
        }
        if (s) {
            jclass cls = (*env)->GetObjectClass(env, signer);
            jmethodID sign = (*env)->GetMethodID(env, cls, "sign", "([B)[B");
            SignCtx ctx = { env, signer, sign };
            void* abstract = &ctx;
            int rc = libssh2_userauth_publickey(s, user, (const unsigned char*)blob,
                                                (size_t)bloblen, sign_cb, &abstract);
            if (rc == 0) {
                LIBSSH2_CHANNEL* ch = libssh2_channel_open_session(s);
                if (ch &&
                    libssh2_channel_request_pty_ex(ch, "xterm-256color", 14, NULL, 0, cols, rows, 0, 0) == 0 &&
                    libssh2_channel_process_startup(ch, "shell", 5, NULL, 0) == 0) {
                    libssh2_session_set_blocking(s, 0);   // non-blocking reads from here
                    client = (SshClient*)calloc(1, sizeof(SshClient));
                    client->fd = fd; client->session = s; client->channel = ch; client->jump = jump;
                } else {
                    if (ch) { libssh2_channel_free(ch); }
                }
            } else {
                char* msg = NULL; libssh2_session_last_error(s, &msg, NULL, 0);
                LOG("openShell: pubkey auth failed rc=%d: %s", rc, msg ? msg : "");
            }
            if (!client) { libssh2_session_disconnect(s, "bye"); libssh2_session_free(s); }
        }
        if (!client) close(fd);
    }
    if (!client && jump) jump_free(jump);   // tear down the bastion tunnel on failure
    (*env)->ReleaseStringUTFChars(env, jhost, host);
    (*env)->ReleaseStringUTFChars(env, juser, user);
    (*env)->ReleaseByteArrayElements(env, jpubblob, blob, JNI_ABORT);
    return (jlong)(intptr_t)client;
}

JNIEXPORT void JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeWrite(JNIEnv* env, jobject thiz, jlong handle, jbyteArray jdata) {
    (void)thiz;
    SshClient* c = (SshClient*)(intptr_t)handle;
    if (!c) return;
    jsize n = (*env)->GetArrayLength(env, jdata);
    jbyte* d = (*env)->GetByteArrayElements(env, jdata, 0);
    ssize_t off = 0;
    while (off < n) {
        ssize_t w = libssh2_channel_write(c->channel, (const char*)d + off, (size_t)(n - off));
        if (w == LIBSSH2_ERROR_EAGAIN) continue;
        if (w < 0) break;
        off += w;
    }
    (*env)->ReleaseByteArrayElements(env, jdata, d, JNI_ABORT);
}

// Returns bytes read (>0), 0 if none available right now, or -1 on EOF/error.
JNIEXPORT jint JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeRead(JNIEnv* env, jobject thiz, jlong handle, jbyteArray jbuf) {
    (void)thiz;
    SshClient* c = (SshClient*)(intptr_t)handle;
    if (!c) return -1;
    jsize cap = (*env)->GetArrayLength(env, jbuf);
    jbyte* b = (*env)->GetByteArrayElements(env, jbuf, 0);
    ssize_t n = libssh2_channel_read(c->channel, (char*)b, (size_t)cap);
    jint result;
    if (n > 0) result = (jint)n;
    else if (n == LIBSSH2_ERROR_EAGAIN) result = 0;
    else if (n == 0 && libssh2_channel_eof(c->channel)) result = -1;
    else result = (n < 0) ? -1 : 0;
    (*env)->ReleaseByteArrayElements(env, jbuf, b, 0);
    return result;
}

JNIEXPORT void JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeResize(JNIEnv* env, jobject thiz, jlong handle, jint cols, jint rows) {
    (void)env; (void)thiz;
    SshClient* c = (SshClient*)(intptr_t)handle;
    if (c) libssh2_channel_request_pty_size_ex(c->channel, cols, rows, 0, 0);
}

JNIEXPORT void JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeClose(JNIEnv* env, jobject thiz, jlong handle) {
    (void)env; (void)thiz;
    SshClient* c = (SshClient*)(intptr_t)handle;
    if (!c) return;
    if (c->channel) { libssh2_channel_close(c->channel); libssh2_channel_free(c->channel); }
    if (c->session) { libssh2_session_disconnect(c->session, "bye"); libssh2_session_free(c->session); }
    if (c->fd >= 0) close(c->fd);   // socketpair target side (signals the pump to stop)
    if (c->jump) jump_free(c->jump);
    free(c);
}

// ---- SFTP subsystem ------------------------------------------------------
// Its own authenticated connection (the interactive shell keeps its own). All
// ops are blocking; the Kotlin side serialises them onto one thread, since a
// libssh2 session isn't thread-safe.

typedef struct { int fd; LIBSSH2_SESSION* session; LIBSSH2_SFTP* sftp; } SftpClient;

// Even on a blocking session, the first SFTP open right after another request
// can momentarily return NULL with errno EAGAIN (libssh2 quirk seen on the first
// file-open after a directory listing). Retry briefly on EAGAIN only.
static LIBSSH2_SFTP_HANDLE* sftp_open_retry(SftpClient* c, const char* path,
                                            unsigned long flags, long mode, int type) {
    for (int i = 0; i < 100; i++) {
        LIBSSH2_SFTP_HANDLE* h =
            libssh2_sftp_open_ex(c->sftp, path, (unsigned)strlen(path), flags, mode, type);
        if (h) return h;
        if (libssh2_session_last_errno(c->session) != LIBSSH2_ERROR_EAGAIN) return NULL;
        usleep(10000);   // 10ms, up to ~1s total
    }
    return NULL;
}

// Connect, verify the host key (if expected), and pubkey-auth via the Kotlin
// signer. Returns a blocking session and sets *out_fd, or NULL on any failure.
static LIBSSH2_SESSION* connect_and_auth(JNIEnv* env, const char* host, int port,
        const char* user, const unsigned char* blob, size_t bloblen, jobject signer,
        jbyteArray jexpectedHostKey, int* out_fd) {
    int fd = tcp_connect(host, port);
    if (fd < 0) return NULL;
    LIBSSH2_SESSION* s = open_session(fd);
    if (!s) { close(fd); return NULL; }
    if (jexpectedHostKey != NULL) {
        size_t hklen = 0; int hktype = 0;
        const char* hk = libssh2_session_hostkey(s, &hklen, &hktype);
        jsize explen = (*env)->GetArrayLength(env, jexpectedHostKey);
        jbyte* exp = (*env)->GetByteArrayElements(env, jexpectedHostKey, 0);
        int mismatch = (!hk || (jsize)hklen != explen || memcmp(hk, exp, hklen) != 0);
        (*env)->ReleaseByteArrayElements(env, jexpectedHostKey, exp, JNI_ABORT);
        if (mismatch) {
            LOG("sftp: host key mismatch — refusing");
            libssh2_session_disconnect(s, "host key mismatch");
            libssh2_session_free(s); close(fd); return NULL;
        }
    }
    jclass cls = (*env)->GetObjectClass(env, signer);
    jmethodID sign = (*env)->GetMethodID(env, cls, "sign", "([B)[B");
    SignCtx ctx = { env, signer, sign };
    void* abstract = &ctx;
    int rc = libssh2_userauth_publickey(s, user, blob, bloblen, sign_cb, &abstract);
    if (rc != 0) {
        char* msg = NULL; libssh2_session_last_error(s, &msg, NULL, 0);
        LOG("sftp: pubkey auth failed rc=%d: %s", rc, msg ? msg : "");
        libssh2_session_disconnect(s, "bye"); libssh2_session_free(s); close(fd);
        return NULL;
    }
    *out_fd = fd;
    return s;
}

JNIEXPORT jlong JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeSftpOpen(
    JNIEnv* env, jobject thiz, jstring jhost, jint port, jstring juser,
    jbyteArray jpubblob, jobject signer, jbyteArray jexpectedHostKey) {
    (void)thiz;
    if (libssh2_init(0)) return 0;
    const char* host = (*env)->GetStringUTFChars(env, jhost, 0);
    const char* user = (*env)->GetStringUTFChars(env, juser, 0);
    jsize bloblen = (*env)->GetArrayLength(env, jpubblob);
    jbyte* blob = (*env)->GetByteArrayElements(env, jpubblob, 0);
    SftpClient* client = NULL;
    int fd = -1;
    LIBSSH2_SESSION* s = connect_and_auth(env, host, port, user,
        (const unsigned char*)blob, (size_t)bloblen, signer, jexpectedHostKey, &fd);
    if (s) {
        LIBSSH2_SFTP* sftp = libssh2_sftp_init(s);
        if (sftp) {
            client = (SftpClient*)calloc(1, sizeof(SftpClient));
            client->fd = fd; client->session = s; client->sftp = sftp;
        } else {
            libssh2_session_disconnect(s, "bye"); libssh2_session_free(s); close(fd);
        }
    }
    (*env)->ReleaseStringUTFChars(env, jhost, host);
    (*env)->ReleaseStringUTFChars(env, juser, user);
    (*env)->ReleaseByteArrayElements(env, jpubblob, blob, JNI_ABORT);
    return (jlong)(intptr_t)client;
}

// Returns String[]: each "d\t<size>\t<name>" (dir) or "f\t<size>\t<name>" (file),
// or null if the directory couldn't be opened.
JNIEXPORT jobjectArray JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeSftpList(
    JNIEnv* env, jobject thiz, jlong handle, jstring jpath) {
    (void)thiz;
    SftpClient* c = (SftpClient*)(intptr_t)handle;
    if (!c) return NULL;
    const char* path = (*env)->GetStringUTFChars(env, jpath, 0);
    LIBSSH2_SFTP_HANDLE* dir = sftp_open_retry(c, path, 0, 0, LIBSSH2_SFTP_OPENDIR);
    (*env)->ReleaseStringUTFChars(env, jpath, path);
    if (!dir) return NULL;

    jclass strCls = (*env)->FindClass(env, "java/lang/String");
    jsize cap = 64, count = 0;
    jobjectArray arr = (*env)->NewObjectArray(env, cap, strCls, NULL);
    char namebuf[1024];
    char line[1300];
    while (1) {
        LIBSSH2_SFTP_ATTRIBUTES attrs;
        int n = libssh2_sftp_readdir_ex(dir, namebuf, sizeof(namebuf) - 1, NULL, 0, &attrs);
        if (n <= 0) break;                          // 0 = end, <0 = error
        if (n > (int)sizeof(namebuf) - 1) n = (int)sizeof(namebuf) - 1;
        namebuf[n] = 0;
        if (!strcmp(namebuf, ".") || !strcmp(namebuf, "..")) continue;
        int isdir = (attrs.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) &&
                    LIBSSH2_SFTP_S_ISDIR(attrs.permissions);
        unsigned long long size =
            (attrs.flags & LIBSSH2_SFTP_ATTR_SIZE) ? (unsigned long long)attrs.filesize : 0ULL;
        snprintf(line, sizeof(line), "%c\t%llu\t%s", isdir ? 'd' : 'f', size, namebuf);
        if (count == cap) {
            jsize ncap = cap * 2;
            jobjectArray narr = (*env)->NewObjectArray(env, ncap, strCls, NULL);
            for (jsize i = 0; i < count; i++) {
                jobject o = (*env)->GetObjectArrayElement(env, arr, i);
                (*env)->SetObjectArrayElement(env, narr, i, o);
                (*env)->DeleteLocalRef(env, o);
            }
            (*env)->DeleteLocalRef(env, arr);
            arr = narr; cap = ncap;
        }
        jstring js = (*env)->NewStringUTF(env, line);
        if (js) { (*env)->SetObjectArrayElement(env, arr, count++, js); (*env)->DeleteLocalRef(env, js); }
    }
    libssh2_sftp_close_handle(dir);

    jobjectArray out = (*env)->NewObjectArray(env, count, strCls, NULL);
    for (jsize i = 0; i < count; i++) {
        jobject o = (*env)->GetObjectArrayElement(env, arr, i);
        (*env)->SetObjectArrayElement(env, out, i, o);
        (*env)->DeleteLocalRef(env, o);
    }
    (*env)->DeleteLocalRef(env, arr);
    return out;
}

JNIEXPORT jbyteArray JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeSftpRead(
    JNIEnv* env, jobject thiz, jlong handle, jstring jpath) {
    (void)thiz;
    SftpClient* c = (SftpClient*)(intptr_t)handle;
    if (!c) return NULL;
    const char* path = (*env)->GetStringUTFChars(env, jpath, 0);
    LIBSSH2_SFTP_HANDLE* h = sftp_open_retry(c, path, LIBSSH2_FXF_READ, 0, LIBSSH2_SFTP_OPENFILE);
    if (!h) LOG("sftp read open '%s' failed sftperr=%lu", path, libssh2_sftp_last_error(c->sftp));
    (*env)->ReleaseStringUTFChars(env, jpath, path);
    if (!h) return NULL;
    size_t cap = 65536, len = 0;
    char* buf = (char*)malloc(cap);
    char tmp[32768];
    int failed = 0;
    while (buf) {
        ssize_t n = libssh2_sftp_read(h, tmp, sizeof(tmp));
        if (n > 0) {
            if (len + (size_t)n > cap) { while (len + (size_t)n > cap) cap *= 2;
                char* nb = (char*)realloc(buf, cap); if (!nb) { failed = 1; break; } buf = nb; }
            memcpy(buf + len, tmp, (size_t)n); len += (size_t)n;
        } else if (n == 0) break;
        else { failed = 1; break; }                 // read error
    }
    libssh2_sftp_close_handle(h);
    jbyteArray out = NULL;
    if (buf && !failed) {
        out = (*env)->NewByteArray(env, (jsize)len);
        if (out) (*env)->SetByteArrayRegion(env, out, 0, (jsize)len, (const jbyte*)buf);
    }
    free(buf);
    return out;
}

JNIEXPORT jboolean JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeSftpWrite(
    JNIEnv* env, jobject thiz, jlong handle, jstring jpath, jbyteArray jdata) {
    (void)thiz;
    SftpClient* c = (SftpClient*)(intptr_t)handle;
    if (!c) return JNI_FALSE;
    const char* path = (*env)->GetStringUTFChars(env, jpath, 0);
    unsigned long flags = LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC;
    LIBSSH2_SFTP_HANDLE* h = sftp_open_retry(c, path, flags, 0644, LIBSSH2_SFTP_OPENFILE);
    (*env)->ReleaseStringUTFChars(env, jpath, path);
    if (!h) return JNI_FALSE;
    jsize total = (*env)->GetArrayLength(env, jdata);
    jbyte* data = (*env)->GetByteArrayElements(env, jdata, 0);
    jboolean ok = JNI_TRUE;
    jsize off = 0;
    while (off < total) {
        ssize_t n = libssh2_sftp_write(h, (const char*)data + off, (size_t)(total - off));
        if (n <= 0) { ok = JNI_FALSE; break; }
        off += (jsize)n;
    }
    (*env)->ReleaseByteArrayElements(env, jdata, data, JNI_ABORT);
    libssh2_sftp_close_handle(h);
    return ok;
}

JNIEXPORT jboolean JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeSftpMkdir(
    JNIEnv* env, jobject thiz, jlong handle, jstring jpath) {
    (void)thiz;
    SftpClient* c = (SftpClient*)(intptr_t)handle;
    if (!c) return JNI_FALSE;
    const char* path = (*env)->GetStringUTFChars(env, jpath, 0);
    int rc = libssh2_sftp_mkdir_ex(c->sftp, path, (unsigned)strlen(path), 0755);
    if (rc != 0)
        LOG("sftp mkdir '%s' failed rc=%d sftperr=%lu", path, rc, libssh2_sftp_last_error(c->sftp));
    (*env)->ReleaseStringUTFChars(env, jpath, path);
    return rc == 0 ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jboolean JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeSftpRemove(
    JNIEnv* env, jobject thiz, jlong handle, jstring jpath, jboolean isDir) {
    (void)thiz;
    SftpClient* c = (SftpClient*)(intptr_t)handle;
    if (!c) return JNI_FALSE;
    const char* path = (*env)->GetStringUTFChars(env, jpath, 0);
    unsigned plen = (unsigned)strlen(path);
    int rc = isDir ? libssh2_sftp_rmdir_ex(c->sftp, path, plen)
                   : libssh2_sftp_unlink_ex(c->sftp, path, plen);
    (*env)->ReleaseStringUTFChars(env, jpath, path);
    return rc == 0 ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeSftpClose(JNIEnv* env, jobject thiz, jlong handle) {
    (void)env; (void)thiz;
    SftpClient* c = (SftpClient*)(intptr_t)handle;
    if (!c) return;
    if (c->sftp) libssh2_sftp_shutdown(c->sftp);
    if (c->session) { libssh2_session_disconnect(c->session, "bye"); libssh2_session_free(c->session); }
    if (c->fd >= 0) close(c->fd);
    free(c);
}

// ---- Local (-L) port forwarding -----------------------------------------
// One dedicated SSH connection hosts several local forwards. Each forward binds
// a loopback listen socket on the device; an inbound connection becomes a
// `direct-tcpip` channel to dest:port (reached from the server). All libssh2
// work runs on the owner thread (nativeForwardService); add/remove only touch
// the forward list under a mutex, so the UI can call them from any thread.

#define FWD_MAX 16
#define FWD_CONN_MAX 64
#define FWD_BUF 16384

typedef struct {
    int sock;                 // accepted loopback socket (-1 = free slot)
    LIBSSH2_CHANNEL* channel; // direct-tcpip channel to dest
    int sock_eof;             // local side closed its write
    int chan_eof;             // remote side closed its write
} FwdConn;

typedef struct {
    int listen_fd;            // -1 = free slot / removed
    int listen_port;
    char dest_host[256];
    int dest_port;
    int error;                // bind/listen errno, 0 = listening
    int remove_flag;          // owner thread tears it down on next service
    FwdConn conns[FWD_CONN_MAX];
} Forward;

typedef struct {
    int fd;
    LIBSSH2_SESSION* session;
    pthread_mutex_t lock;
    Forward fwds[FWD_MAX];
} ForwardClient;

static void fwd_conn_close(FwdConn* c) {
    if (c->channel) { libssh2_channel_close(c->channel); libssh2_channel_free(c->channel); c->channel = NULL; }
    if (c->sock >= 0) { close(c->sock); c->sock = -1; }
    c->sock_eof = c->chan_eof = 0;
}

JNIEXPORT jlong JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeForwardOpen(
    JNIEnv* env, jobject thiz, jstring jhost, jint port, jstring juser,
    jbyteArray jpubblob, jobject signer, jbyteArray jexpectedHostKey) {
    (void)thiz;
    if (libssh2_init(0)) return 0;
    const char* host = (*env)->GetStringUTFChars(env, jhost, 0);
    const char* user = (*env)->GetStringUTFChars(env, juser, 0);
    jsize bloblen = (*env)->GetArrayLength(env, jpubblob);
    jbyte* blob = (*env)->GetByteArrayElements(env, jpubblob, 0);
    ForwardClient* fc = NULL;
    int fd = -1;
    LIBSSH2_SESSION* s = connect_and_auth(env, host, port, user,
        (const unsigned char*)blob, (size_t)bloblen, signer, jexpectedHostKey, &fd);
    if (s) {
        libssh2_session_set_blocking(s, 0);   // non-blocking channel I/O
        fc = (ForwardClient*)calloc(1, sizeof(ForwardClient));
        fc->fd = fd; fc->session = s;
        pthread_mutex_init(&fc->lock, NULL);
        for (int i = 0; i < FWD_MAX; i++) {
            fc->fwds[i].listen_fd = -1;
            for (int j = 0; j < FWD_CONN_MAX; j++) fc->fwds[i].conns[j].sock = -1;
        }
    }
    (*env)->ReleaseStringUTFChars(env, jhost, host);
    (*env)->ReleaseStringUTFChars(env, juser, user);
    (*env)->ReleaseByteArrayElements(env, jpubblob, blob, JNI_ABORT);
    return (jlong)(intptr_t)fc;
}

// Bind a loopback listener for a new forward. Returns 0, or an errno on failure
// (e.g. EADDRINUSE). Safe from any thread.
JNIEXPORT jint JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeForwardAdd(
    JNIEnv* env, jobject thiz, jlong handle, jint listenPort, jstring jdestHost, jint destPort) {
    (void)thiz;
    ForwardClient* fc = (ForwardClient*)(intptr_t)handle;
    if (!fc) return -1;
    const char* dest = (*env)->GetStringUTFChars(env, jdestHost, 0);
    int rc = 0;
    pthread_mutex_lock(&fc->lock);
    int slot = -1;
    for (int i = 0; i < FWD_MAX; i++) if (fc->fwds[i].listen_fd < 0 && !fc->fwds[i].remove_flag) { slot = i; break; }
    if (slot < 0) { rc = -1; goto out; }
    int lfd = socket(AF_INET, SOCK_STREAM, 0);
    if (lfd < 0) { rc = errno ? errno : -1; goto out; }
    int yes = 1; setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr; memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);   // 127.0.0.1 only
    addr.sin_port = htons((uint16_t)listenPort);
    if (bind(lfd, (struct sockaddr*)&addr, sizeof(addr)) < 0 || listen(lfd, 8) < 0) {
        rc = errno ? errno : -1; close(lfd); goto out;
    }
    fcntl(lfd, F_SETFL, O_NONBLOCK);
    Forward* f = &fc->fwds[slot];
    f->listen_fd = lfd; f->listen_port = listenPort; f->dest_port = destPort;
    f->error = 0; f->remove_flag = 0;
    strncpy(f->dest_host, dest, sizeof(f->dest_host) - 1); f->dest_host[sizeof(f->dest_host) - 1] = 0;
out:
    pthread_mutex_unlock(&fc->lock);
    (*env)->ReleaseStringUTFChars(env, jdestHost, dest);
    return rc;
}

// Mark a forward for teardown; the owner thread frees its channels next service.
JNIEXPORT void JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeForwardRemove(
    JNIEnv* env, jobject thiz, jlong handle, jint listenPort) {
    (void)env; (void)thiz;
    ForwardClient* fc = (ForwardClient*)(intptr_t)handle;
    if (!fc) return;
    pthread_mutex_lock(&fc->lock);
    for (int i = 0; i < FWD_MAX; i++)
        if (fc->fwds[i].listen_fd >= 0 && fc->fwds[i].listen_port == listenPort) fc->fwds[i].remove_flag = 1;
    pthread_mutex_unlock(&fc->lock);
}

// Accept new connections, pump every active conn both ways, tear down removed
// forwards. Returns active connection count, or -1 if the session died. Owner
// thread only.
JNIEXPORT jint JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeForwardService(
    JNIEnv* env, jobject thiz, jlong handle, jint timeoutMs) {
    (void)env; (void)thiz;
    ForwardClient* fc = (ForwardClient*)(intptr_t)handle;
    if (!fc) return -1;

    struct pollfd pfds[1 + FWD_MAX + FWD_MAX * FWD_CONN_MAX];
    int n = 0;
    pfds[n].fd = fc->fd; pfds[n].events = POLLIN; pfds[n].revents = 0; n++;   // session (incoming channel data)

    pthread_mutex_lock(&fc->lock);
    for (int i = 0; i < FWD_MAX; i++) {
        Forward* f = &fc->fwds[i];
        if (f->listen_fd < 0) continue;
        if (!f->remove_flag) { pfds[n].fd = f->listen_fd; pfds[n].events = POLLIN; pfds[n].revents = 0; n++; }
        for (int j = 0; j < FWD_CONN_MAX; j++)
            if (f->conns[j].sock >= 0 && !f->conns[j].sock_eof) {
                pfds[n].fd = f->conns[j].sock; pfds[n].events = POLLIN; pfds[n].revents = 0; n++;
            }
    }
    pthread_mutex_unlock(&fc->lock);

    poll(pfds, n, timeoutMs);

    char buf[FWD_BUF];
    int active = 0;
    pthread_mutex_lock(&fc->lock);
    for (int i = 0; i < FWD_MAX; i++) {
        Forward* f = &fc->fwds[i];
        if (f->listen_fd < 0) continue;

        if (f->remove_flag) {
            for (int j = 0; j < FWD_CONN_MAX; j++) if (f->conns[j].sock >= 0) fwd_conn_close(&f->conns[j]);
            close(f->listen_fd); f->listen_fd = -1; f->remove_flag = 0;
            continue;
        }

        // Accept new local connections → open a direct-tcpip channel each.
        int csock;
        while ((csock = accept(f->listen_fd, NULL, NULL)) >= 0) {
            fcntl(csock, F_SETFL, O_NONBLOCK);
            LIBSSH2_CHANNEL* ch = NULL;
            for (int tries = 0; tries < 200; tries++) {
                ch = libssh2_channel_direct_tcpip_ex(fc->session, f->dest_host, f->dest_port,
                                                     "127.0.0.1", f->listen_port);
                if (ch) break;
                if (libssh2_session_last_errno(fc->session) != LIBSSH2_ERROR_EAGAIN) break;
                usleep(2000);
            }
            if (!ch) {
                char* msg = NULL; libssh2_session_last_error(fc->session, &msg, NULL, 0);
                LOG("fwd: direct-tcpip to %s:%d refused: %s", f->dest_host, f->dest_port, msg ? msg : "");
                close(csock); continue;
            }
            int slot = -1;
            for (int j = 0; j < FWD_CONN_MAX; j++) if (f->conns[j].sock < 0) { slot = j; break; }
            if (slot < 0) { libssh2_channel_close(ch); libssh2_channel_free(ch); close(csock); continue; }
            f->conns[slot].sock = csock; f->conns[slot].channel = ch;
            f->conns[slot].sock_eof = f->conns[slot].chan_eof = 0;
        }

        // Pump each active connection both directions (non-blocking).
        for (int j = 0; j < FWD_CONN_MAX; j++) {
            FwdConn* c = &f->conns[j];
            if (c->sock < 0) continue;
            active++;
            // local socket → remote channel
            if (!c->sock_eof) {
                ssize_t r = recv(c->sock, buf, sizeof(buf), 0);
                if (r > 0) {
                    ssize_t off = 0;
                    while (off < r) {
                        ssize_t w = libssh2_channel_write(c->channel, buf + off, (size_t)(r - off));
                        if (w == LIBSSH2_ERROR_EAGAIN) continue;
                        if (w < 0) { c->sock_eof = 1; break; }
                        off += w;
                    }
                } else if (r == 0) {
                    c->sock_eof = 1; libssh2_channel_send_eof(c->channel);
                } else if (errno != EAGAIN && errno != EWOULDBLOCK) {
                    c->sock_eof = 1; libssh2_channel_send_eof(c->channel);
                }
            }
            // remote channel → local socket
            if (!c->chan_eof) {
                ssize_t r = libssh2_channel_read(c->channel, buf, sizeof(buf));
                if (r > 0) {
                    ssize_t off = 0;
                    while (off < r) {
                        ssize_t w = send(c->sock, buf + off, (size_t)(r - off), 0);
                        if (w < 0) { if (errno == EAGAIN || errno == EWOULDBLOCK) continue; c->chan_eof = 1; break; }
                        off += w;
                    }
                } else if (r == 0 && libssh2_channel_eof(c->channel)) {
                    c->chan_eof = 1; shutdown(c->sock, SHUT_WR);
                } else if (r < 0 && r != LIBSSH2_ERROR_EAGAIN) {
                    c->chan_eof = 1;
                }
            }
            if (c->sock_eof && c->chan_eof) { fwd_conn_close(c); active--; }
        }
    }
    pthread_mutex_unlock(&fc->lock);
    return active;
}

JNIEXPORT void JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeForwardClose(JNIEnv* env, jobject thiz, jlong handle) {
    (void)env; (void)thiz;
    ForwardClient* fc = (ForwardClient*)(intptr_t)handle;
    if (!fc) return;
    pthread_mutex_lock(&fc->lock);
    for (int i = 0; i < FWD_MAX; i++) {
        Forward* f = &fc->fwds[i];
        if (f->listen_fd < 0) continue;
        for (int j = 0; j < FWD_CONN_MAX; j++) if (f->conns[j].sock >= 0) fwd_conn_close(&f->conns[j]);
        close(f->listen_fd); f->listen_fd = -1;
    }
    pthread_mutex_unlock(&fc->lock);
    pthread_mutex_destroy(&fc->lock);
    if (fc->session) { libssh2_session_disconnect(fc->session, "bye"); libssh2_session_free(fc->session); }
    if (fc->fd >= 0) close(fc->fd);
    free(fc);
}
