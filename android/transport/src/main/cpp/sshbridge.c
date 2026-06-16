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

static LIBSSH2_SESSION* open_session(int fd) {
    LIBSSH2_SESSION* s = libssh2_session_init();
    if (!s) return NULL;
    libssh2_session_set_blocking(s, 1);
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
    jstring jpassword, jstring jauthLine) {
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
    jbyteArray jpubblob, jobject signer, jstring jcmd) {
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

typedef struct { int fd; LIBSSH2_SESSION* session; LIBSSH2_CHANNEL* channel; } SshClient;

JNIEXPORT jlong JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeOpenShell(
    JNIEnv* env, jobject thiz, jstring jhost, jint port, jstring juser,
    jbyteArray jpubblob, jobject signer, jint cols, jint rows, jbyteArray jexpectedHostKey) {
    (void)thiz;
    if (libssh2_init(0)) return 0;
    const char* host = (*env)->GetStringUTFChars(env, jhost, 0);
    const char* user = (*env)->GetStringUTFChars(env, juser, 0);
    jsize bloblen = (*env)->GetArrayLength(env, jpubblob);
    jbyte* blob = (*env)->GetByteArrayElements(env, jpubblob, 0);
    SshClient* client = NULL;
    int fd = tcp_connect(host, port);
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
                    client->fd = fd; client->session = s; client->channel = ch;
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
    if (c->fd >= 0) close(c->fd);
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
