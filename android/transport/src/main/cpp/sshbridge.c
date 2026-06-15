// JNI bridge over libssh2: the Android equivalent of the iOS AgentSignBridge.
// Public-key auth's sign callback calls back into Kotlin, which signs with a
// non-extractable Android Keystore key — the private key never touches the
// transport. (Spike: also installs the pubkey via password first.)
#include <jni.h>
#include <libssh2.h>
#include <android/log.h>
#include <netdb.h>
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
