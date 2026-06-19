// JNI bridge over libssh2: the Android equivalent of the iOS AgentSignBridge.
// Public-key auth's sign callback calls back into Kotlin, which signs with a
// non-extractable Android Keystore key — the private key never touches the
// transport. nativeInstallKey is the "Install my key" feature: a one-time
// password connect that appends the pubkey to the server's authorized_keys.
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

// Why the last open on THIS thread failed, so the UI can show something better
// than one generic error. Set by every connect path (shell, exec/mosh-bootstrap,
// forwards) and read immediately after on the same (factory) thread — thread-local
// is safe and needs no locking. Mirrors the categories of iOS TerminalSession.describe.
enum {
    OPEN_OK = 0,
    OPEN_UNREACHABLE,     // TCP connect / bastion tunnel failed
    OPEN_HANDSHAKE,       // SSH handshake / algorithm policy failed
    OPEN_AUTH,            // public-key (or sk) auth rejected
    OPEN_HOST_KEY,        // pinned host key didn't match (possible MITM)
    OPEN_NO_SHELL,        // authed, but couldn't open the channel / PTY / shell
};
static __thread int g_open_reason = OPEN_OK;

// Connect with a deadline so a black-holed (silently dropped) host is bounded to
// seconds instead of the OS default (often ~2 minutes). Non-blocking connect +
// poll(POLLOUT) per address; on timeout/failure we fall through to the next
// address, then restore blocking mode for the handshake (open_session expects a
// blocking fd).
#define TCP_CONNECT_TIMEOUT_MS 10000

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
        int fl = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, fl | O_NONBLOCK);   // non-blocking so connect() returns immediately
        int rc = connect(fd, p->ai_addr, p->ai_addrlen);
        if (rc != 0 && errno == EINPROGRESS) {
            struct pollfd pfd = { fd, POLLOUT, 0 };
            int pr = poll(&pfd, 1, TCP_CONNECT_TIMEOUT_MS);
            if (pr <= 0) { close(fd); fd = -1; continue; }   // timeout (0) or poll error (<0)
            int soerr = 0; socklen_t slen = sizeof(soerr);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &slen) != 0 || soerr != 0) {
                close(fd); fd = -1; continue;                // connect failed underneath poll
            }
            rc = 0;
        }
        if (rc == 0) {
            fcntl(fd, F_SETFL, fl);   // restore blocking mode for the handshake
            break;
        }
        close(fd);                    // immediate connect() error
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

// ---- FIDO2 security-key (sk-ecdsa) auth ----------------------------------
// Authenticate through the patched libssh2_userauth_publickey_raw (vendor
// patch libssh2-1.11.0-webauthn-sk.patch): the sign callback returns a
// COMPLETE SSH signature blob, emitted verbatim, while the pubkey-algorithm
// field carries the key type from `blob`. We hand `data` to Kotlin's
// signer.signSk([B)[B, which asks the authenticator (YubiKey) for an assertion
// and returns the full native sk-ecdsa signature:
//   string "sk-ecdsa-sha2-nistp256@openssh.com" | string(mpint r || mpint s) |
//   byte flags | uint32 counter
// (Stock libssh2_userauth_publickey_sk frames the sk packet in a way OpenSSH
// rejects with "parse publickey packet: invalid format"; the raw path matches
// the validated iOS bridge and needs no private-key blob — the callback owns
// the whole signature.)
typedef struct { JNIEnv* env; jobject signer; jmethodID signSk; } SkSignCtx;

static int sk_raw_sign_cb(LIBSSH2_SESSION* session, unsigned char** sig, size_t* sig_len,
                          const unsigned char* data, size_t data_len, void** abstract) {
    (void)session;
    SkSignCtx* c = (SkSignCtx*)(*abstract);
    JNIEnv* env = c->env;
    jbyteArray jdata = (*env)->NewByteArray(env, (jsize)data_len);
    (*env)->SetByteArrayRegion(env, jdata, 0, (jsize)data_len, (const jbyte*)data);
    jbyteArray jout = (jbyteArray)(*env)->CallObjectMethod(env, c->signer, c->signSk, jdata);
    (*env)->DeleteLocalRef(env, jdata);
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); return -1; }
    if (!jout) return -1;
    jsize n = (*env)->GetArrayLength(env, jout);
    unsigned char* buf = (unsigned char*)malloc((size_t)n ? (size_t)n : 1);
    if (!buf) { (*env)->DeleteLocalRef(env, jout); return -1; }
    (*env)->GetByteArrayRegion(env, jout, 0, n, (jbyte*)buf);
    (*env)->DeleteLocalRef(env, jout);
    *sig = buf;                 // libssh2 takes ownership and frees it
    *sig_len = (size_t)n;
    return 0;
}

// Authenticate `s` with an sk key. Returns 0 on success (the caller keeps the
// session), non-zero on failure (the caller tears the session down). The signer
// exposes signSk([B)[B. The raw path needs no private-key blob, so `priv` /
// `privlen` are still accepted by callers but unused here.
static int sk_authenticate(JNIEnv* env, LIBSSH2_SESSION* s, const char* user,
                           const unsigned char* blob, size_t bloblen,
                           const char* priv, size_t privlen, jobject signer) {
    (void)priv; (void)privlen;
    jclass cls = (*env)->GetObjectClass(env, signer);
    jmethodID signSk = (*env)->GetMethodID(env, cls, "signSk", "([B)[B");
    SkSignCtx ctx = { env, signer, signSk };
    void* abstract = &ctx;
    int rc = libssh2_userauth_publickey_raw(s, user, blob, bloblen, sk_raw_sign_cb, &abstract);
    if (rc != 0) {
        char* msg = NULL; libssh2_session_last_error(s, &msg, NULL, 0);
        LOG("sk auth failed rc=%d: %s", rc, msg ? msg : "");
    }
    return rc;
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
                    // Single-quote-escape the authorized_keys line before interpolating
                    // it into the remote command, so spaces/metacharacters can't break
                    // out of the quoting (mirrors the iOS installer's '...'\''...'
                    // pattern). Worst case each char becomes the 4-char "'\''", so a
                    // 2-byte preamble + 4x the line + 2-byte trailer + NUL bounds it.
                    size_t linelen = strlen(line);
                    char* qline = (char*)malloc(linelen * 4 + 3);
                    char cmd[8192];
                    int built = 0;
                    if (qline) {
                        size_t qi = 0;
                        qline[qi++] = '\'';
                        for (size_t i = 0; i < linelen; i++) {
                            if (line[i] == '\'') { qline[qi++]='\''; qline[qi++]='\\'; qline[qi++]='\''; qline[qi++]='\''; }
                            else qline[qi++] = line[i];
                        }
                        qline[qi++] = '\'';
                        qline[qi] = 0;
                        // Append the key only if it isn't already present (dedup), matching
                        // the iOS installer's `grep -qxF || append` so repeated installs
                        // don't pile up duplicate authorized_keys lines. qline is already
                        // a fully shell-quoted word, so it goes in unquoted.
                        int need = snprintf(cmd, sizeof(cmd),
                                 "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && "
                                 "chmod 600 ~/.ssh/authorized_keys && "
                                 "line=%s && { grep -qxF -- \"$line\" ~/.ssh/authorized_keys || "
                                 "printf '%%s\\n' \"$line\" >> ~/.ssh/authorized_keys; } && echo INSTALLED",
                                 qline);
                        built = (need > 0 && need < (int)sizeof(cmd));
                        free(qline);
                    }
                    if (built) libssh2_channel_exec(c, cmd);
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

// Run `cmd` on an already-authenticated, BLOCKING session and capture its full
// stdout (the mosh bootstrap: `mosh-server new …` → the caller parses
// MOSH CONNECT out of the returned string). Correctness over the old fixed 4 KiB
// stdout-only loop:
//   - check libssh2_channel_exec rc (request failure → OPEN_NO_SHELL, no string)
//   - drain BOTH stdout (stream 0) and stderr (stream 1) until channel EOF — a
//     single 0-read is NOT EOF, and a chatty stderr left unread can fill the
//     window and stall the exec, so we read both each pass
//   - stdout grows up to a generous cap (256 KiB) so a preamble before
//     MOSH CONNECT isn't truncated; stderr is drained but discarded
//   - then wait_closed + read the remote exit status
// Returns a malloc'd NUL-terminated stdout buffer the caller must free (NULL on
// channel_exec failure). g_open_reason is set to OPEN_OK when the SSH side
// genuinely ran the command; OPEN_NO_SHELL if the exec request itself failed.
#define EXEC_STDOUT_CAP (256 * 1024)

static char* exec_capture(LIBSSH2_CHANNEL* c, const char* cmd) {
    if (libssh2_channel_exec(c, cmd) != 0) {
        g_open_reason = OPEN_NO_SHELL;
        return NULL;
    }
    size_t cap = 8192, len = 0;
    char* out = (char*)malloc(cap);
    if (!out) { g_open_reason = OPEN_NO_SHELL; return NULL; }
    char buf[8192];
    // Blocking session: read both streams until the channel reports EOF, draining
    // fairly so neither stream's window can wedge the other.
    while (!libssh2_channel_eof(c)) {
        int progress = 0;
        // stdout (stream 0) → captured, capped
        ssize_t n = libssh2_channel_read_ex(c, 0, buf, sizeof(buf));
        if (n > 0) {
            progress = 1;
            if (len < EXEC_STDOUT_CAP) {
                size_t room = EXEC_STDOUT_CAP - len;
                size_t take = (size_t)n < room ? (size_t)n : room;
                if (len + take + 1 > cap) {
                    while (len + take + 1 > cap) cap *= 2;
                    if (cap > EXEC_STDOUT_CAP + 1) cap = EXEC_STDOUT_CAP + 1;
                    char* nb = (char*)realloc(out, cap);
                    if (!nb) { free(out); g_open_reason = OPEN_NO_SHELL; return NULL; }
                    out = nb;
                }
                memcpy(out + len, buf, take); len += take;
            }
            // beyond the cap we keep draining stdout but discard, so the window
            // can't stall and stderr stays serviceable
        } else if (n < 0 && n != LIBSSH2_ERROR_EAGAIN) {
            break;   // hard read error
        }
        // stderr (stream 1) → drained (discarded) so it can't fill the window and stall
        ssize_t e = libssh2_channel_read_ex(c, SSH_EXTENDED_DATA_STDERR, buf, sizeof(buf));
        if (e > 0) progress = 1;
        else if (e < 0 && e != LIBSSH2_ERROR_EAGAIN) break;
        if (!progress) {
            // Both streams returned EAGAIN/0 without EOF on a blocking session —
            // nothing to do but yield briefly rather than busy-spin.
            usleep(2000);
        }
    }
    out[len] = 0;
    libssh2_channel_wait_closed(c);
    (void)libssh2_channel_get_exit_status(c);   // surfaced via the returned string today
    g_open_reason = OPEN_OK;
    return out;
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
    g_open_reason = OPEN_UNREACHABLE;   // refined as we get further in
    int fd = tcp_connect(host, port);
    if (fd >= 0) {
        LIBSSH2_SESSION* s = open_session(fd);
        if (!s) g_open_reason = OPEN_HANDSHAKE;
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
                g_open_reason = OPEN_HOST_KEY;
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
                    // Capture full stdout (both streams drained); exec_capture sets
                    // g_open_reason. A missing MOSH CONNECT in the output is a
                    // mosh-server problem, not an auth/connect one — exec_capture
                    // keeps OK in that case so the caller shows "is mosh on the host?".
                    char* out = exec_capture(c, cmd);
                    if (out) {
                        result = (*env)->NewStringUTF(env, out);
                        free(out);
                    }
                    libssh2_channel_close(c);
                    libssh2_channel_free(c);
                } else {
                    g_open_reason = OPEN_NO_SHELL;
                }
            } else {
                g_open_reason = OPEN_AUTH;
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
// impersonate the target). The bastion's own key is also verified: the caller
// passes its expected host-key blob (jexpectedBastionHostKey) and the handshake
// to the bastion is refused on mismatch, same as the target.
// A grow-on-demand FIFO byte buffer (head/tail indices; compacts on consume) so
// a relayed connection can buffer a bounded amount in each direction and stop
// reading its source when full — instead of spinning on EAGAIN to drain a slow
// peer. Mirrors the iOS forwarder's ByteQueue. Used by both the ProxyJump pump
// and the local-forward service below.
typedef struct { unsigned char* data; size_t cap, head, tail; } ByteQueue;

static size_t bq_count(const ByteQueue* q) { return q->tail - q->head; }

static int bq_append(ByteQueue* q, const unsigned char* src, size_t n) {
    if (q->head == q->tail) { q->head = q->tail = 0; }
    if (q->tail + n > q->cap) {
        if (q->head > 0) {   // compact before growing
            memmove(q->data, q->data + q->head, q->tail - q->head);
            q->tail -= q->head; q->head = 0;
        }
        if (q->tail + n > q->cap) {
            size_t ncap = q->cap ? q->cap : 8192;
            while (ncap < q->tail + n) ncap *= 2;
            unsigned char* nd = (unsigned char*)realloc(q->data, ncap);
            if (!nd) return -1;
            q->data = nd; q->cap = ncap;
        }
    }
    memcpy(q->data + q->tail, src, n); q->tail += n;
    return 0;
}

static void bq_consume(ByteQueue* q, size_t n) {
    q->head += n;
    if (q->head == q->tail) { q->head = q->tail = 0; }
}

static void bq_free(ByteQueue* q) { free(q->data); q->data = NULL; q->cap = q->head = q->tail = 0; }

typedef struct {
    LIBSSH2_SESSION* session;   // session to the bastion
    LIBSSH2_CHANNEL* channel;   // direct-tcpip bastion -> target
    int jump_fd;                // TCP socket to the bastion
    int pump_fd;                // pump-side end of the socketpair
    pthread_t pump;
    volatile int stop;
} JumpChain;

#define JUMP_CAP (1 << 20)   // 1 MiB per-direction buffer cap → backpressure

typedef struct {
    int fd; LIBSSH2_SESSION* session; LIBSSH2_CHANNEL* channel; JumpChain* jump;
    int wake[2];   // self-pipe: wake[1] written to interrupt nativeWait's poll
} SshClient;

// Create the wake self-pipe on a fresh client (best-effort: -1 fds just mean
// nativeWait falls back to its timeout, never blocking forever). Both ends are
// non-blocking so a poke never stalls the poking thread and a drain never hangs.
static void ssh_client_init_wake(SshClient* c) {
    if (pipe(c->wake) == 0) {
        fcntl(c->wake[0], F_SETFL, O_NONBLOCK);
        fcntl(c->wake[1], F_SETFL, O_NONBLOCK);
    } else {
        c->wake[0] = c->wake[1] = -1;
    }
}

// Poke the wake-pipe so a blocked nativeWait returns now (called from the owner
// thread's write/resize/close staging path, mirroring the mosh bridge).
static void ssh_client_wake(SshClient* c) {
    if (c && c->wake[1] >= 0) { char b = 1; ssize_t w = write(c->wake[1], &b, 1); (void)w; }
}


// Relay bytes between the local socketpair end and the bastion's tunnel channel
// until both directions close. Owns the bastion session exclusively (libssh2
// isn't thread-safe per session, so nothing else touches it once the pump runs).
//
// Bounded bidirectional relay modeled on nativeForwardService below: a per-
// direction ByteQueue holds bytes that couldn't be written yet, so a read chunk
// is never lost when its write would block; we stop reading a source while its
// destination buffer is at cap (backpressure); and we poll() the socketpair fd
// plus consult libssh2_session_block_directions() for the channel, retrying only
// on the relevant readiness instead of spinning on EAGAIN. Half-close propagates
// (one side's EOF doesn't tear the other down until its buffer drains).
static void* jump_pump(void* arg) {
    JumpChain* j = (JumpChain*)arg;
    libssh2_session_set_blocking(j->session, 0);
    char buf[16384];
    ByteQueue to_chan = {0};    // local socket → bastion channel
    ByteQueue to_sock = {0};    // bastion channel → local socket
    int sock_eof = 0;           // local end sent EOF (read returned 0)
    int chan_eof = 0;           // channel reported EOF
    int sent_chan_eof = 0;      // forwarded local half-close to the channel

    while (!j->stop) {
        // channel → to_sock (stop while the local side is backed up)
        while (!chan_eof && bq_count(&to_sock) < JUMP_CAP) {
            ssize_t r = libssh2_channel_read(j->channel, buf, sizeof(buf));
            if (r > 0) bq_append(&to_sock, (unsigned char*)buf, (size_t)r);
            else if (r == LIBSSH2_ERROR_EAGAIN) break;
            else { chan_eof = 1; break; }   // 0 = EOF, <0 = error
        }
        if (libssh2_channel_eof(j->channel)) chan_eof = 1;

        // to_sock → local socket (one non-blocking pass)
        while (bq_count(&to_sock) > 0) {
            ssize_t w = write(j->pump_fd, to_sock.data + to_sock.head, bq_count(&to_sock));
            if (w > 0) bq_consume(&to_sock, (size_t)w);
            else if (w < 0 && errno == EINTR) continue;
            else { if (w < 0 && errno != EAGAIN && errno != EWOULDBLOCK) sock_eof = 1; break; }
        }

        // local socket → to_chan (stop while the remote side is backed up)
        while (!sock_eof && bq_count(&to_chan) < JUMP_CAP) {
            ssize_t r = read(j->pump_fd, buf, sizeof(buf));
            if (r > 0) bq_append(&to_chan, (unsigned char*)buf, (size_t)r);
            else if (r == 0) { sock_eof = 1; break; }
            else { if (errno == EINTR) continue;
                   if (errno != EAGAIN && errno != EWOULDBLOCK) sock_eof = 1; break; }
        }

        // to_chan → channel (one non-blocking pass)
        while (bq_count(&to_chan) > 0) {
            ssize_t w = libssh2_channel_write(j->channel, (char*)(to_chan.data + to_chan.head),
                                              bq_count(&to_chan));
            if (w > 0) bq_consume(&to_chan, (size_t)w);
            else break;   // EAGAIN/error: retry after the next poll
        }

        // Propagate the local half-close once our outbound buffer is flushed.
        if (sock_eof && bq_count(&to_chan) == 0 && !sent_chan_eof) {
            libssh2_channel_send_eof(j->channel); sent_chan_eof = 1;
        }

        int remote_done = chan_eof && bq_count(&to_sock) == 0;
        int local_done = sock_eof && bq_count(&to_chan) == 0;
        if (remote_done && local_done) break;   // both directions drained

        // Wait for readiness on whichever fd/direction we still need, so we never
        // busy-spin on EAGAIN. Poll the socketpair fd for the side that has work,
        // and the session fd for the channel's current block direction.
        struct pollfd pfds[2];
        int n = 0;
        short sev = 0;
        if (!sock_eof && bq_count(&to_chan) < JUMP_CAP) sev |= POLLIN;   // room to read more local
        if (bq_count(&to_sock) > 0) sev |= POLLOUT;                      // bytes waiting for the socket
        if (sev) { pfds[n].fd = j->pump_fd; pfds[n].events = sev; pfds[n].revents = 0; n++; }
        // The channel rides the bastion session fd; ask libssh2 which direction it
        // currently needs and poll for exactly that.
        short cev = 0;
        int dir = libssh2_session_block_directions(j->session);
        if ((!chan_eof && bq_count(&to_sock) < JUMP_CAP) || bq_count(&to_chan) > 0) {
            if (dir & LIBSSH2_SESSION_BLOCK_INBOUND) cev |= POLLIN;
            if (dir & LIBSSH2_SESSION_BLOCK_OUTBOUND) cev |= POLLOUT;
            if (cev == 0) cev = POLLIN;   // nothing pending — wait for more channel data
        }
        if (cev) { pfds[n].fd = j->jump_fd; pfds[n].events = cev; pfds[n].revents = 0; n++; }
        if (n == 0) { usleep(2000); continue; }   // nothing to wait on — brief yield
        poll(pfds, n, 200);   // bounded wait; loop re-checks j->stop on wake/timeout
    }
    bq_free(&to_chan); bq_free(&to_sock);
    return NULL;
}

// Build a tunneled fd to `dhost:dport` via the bastion. Returns the target-side
// socketpair fd (hand to open_session) and the JumpChain to free on close, or -1.
static int open_jump_fd(JNIEnv* env, const char* jhost, int jport, const char* juser,
                        const char* dhost, int dport,
                        const unsigned char* blob, size_t bloblen, jobject signer,
                        jbyteArray jexpectedBastionHostKey, JumpChain** out) {
    int jfd = -1;
    // Verify the bastion's OWN host key (if supplied) before authenticating to it.
    LIBSSH2_SESSION* js = connect_and_auth(env, jhost, jport, juser, blob, bloblen, signer,
                                           jexpectedBastionHostKey, &jfd);
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
    jbyteArray jpubblob, jobject signer, jbyteArray jexpectedBastionHostKey) {
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
                          (const unsigned char*)blob, (size_t)bloblen, signer, jexpectedBastionHostKey, &jump);
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
    jstring jjumpHost, jint jumpPort, jstring jjumpUser, jbyteArray jexpectedBastionHostKey) {
    (void)thiz;
    g_open_reason = OPEN_UNREACHABLE;   // refined as we get further in
    if (libssh2_init(0)) return 0;
    const char* host = (*env)->GetStringUTFChars(env, jhost, 0);
    const char* user = (*env)->GetStringUTFChars(env, juser, 0);
    jsize bloblen = (*env)->GetArrayLength(env, jpubblob);
    jbyte* blob = (*env)->GetByteArrayElements(env, jpubblob, 0);
    SshClient* client = NULL;
    JumpChain* jump = NULL;
    int fd;
    if (jjumpHost != NULL) {
        // Reach the target through a bastion (ProxyJump). The bastion's own host key
        // is verified (jexpectedBastionHostKey) before auth; same key auths both hops.
        const char* jh = (*env)->GetStringUTFChars(env, jjumpHost, 0);
        const char* ju = (*env)->GetStringUTFChars(env, jjumpUser, 0);
        fd = open_jump_fd(env, jh, jumpPort, ju, host, port,
                          (const unsigned char*)blob, (size_t)bloblen, signer, jexpectedBastionHostKey, &jump);
        (*env)->ReleaseStringUTFChars(env, jjumpHost, jh);
        (*env)->ReleaseStringUTFChars(env, jjumpUser, ju);
    } else {
        fd = tcp_connect(host, port);
    }
    if (fd >= 0) {
        LIBSSH2_SESSION* s = open_session(fd);
        if (!s) g_open_reason = OPEN_HANDSHAKE;   // connected, but SSH handshake/policy failed
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
                g_open_reason = OPEN_HOST_KEY;
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
                    ssh_client_init_wake(client);
                    g_open_reason = OPEN_OK;
                } else {
                    g_open_reason = OPEN_NO_SHELL;   // authed, but no channel/PTY/shell
                    if (ch) { libssh2_channel_free(ch); }
                }
            } else {
                g_open_reason = OPEN_AUTH;
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

// Write what the channel will take in one non-blocking pass and return how many
// bytes went out (0..len), or -1 on a hard error. On EAGAIN (the channel is
// backed up — slow link, large paste, remote not reading) we stop instead of
// busy-spinning; the caller requeues the unsent tail and waits for writability
// via nativeWait (which polls OUTBOUND). This both kills the CPU spin and avoids
// silently dropping bytes on backpressure.
JNIEXPORT jint JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeWrite(JNIEnv* env, jobject thiz, jlong handle, jbyteArray jdata) {
    (void)thiz;
    SshClient* c = (SshClient*)(intptr_t)handle;
    if (!c) return -1;
    jsize n = (*env)->GetArrayLength(env, jdata);
    jbyte* d = (*env)->GetByteArrayElements(env, jdata, 0);
    ssize_t off = 0;
    jint result = 0;
    while (off < n) {
        ssize_t w = libssh2_channel_write(c->channel, (const char*)d + off, (size_t)(n - off));
        if (w == LIBSSH2_ERROR_EAGAIN) break;   // backpressure — caller requeues the tail
        if (w < 0) { result = -1; break; }      // hard error — caller tears down
        off += w;
    }
    (*env)->ReleaseByteArrayElements(env, jdata, d, JNI_ABORT);
    return result < 0 ? -1 : (jint)off;
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

// Block up to timeoutMs for the session fd to become readable/writable (per
// libssh2's current block directions) or for the wake-pipe to be poked, then
// return. This replaces a busy-poll on EAGAIN: an idle session parks here
// instead of spinning at 100Hz, while a poke (nativeWake) returns immediately so
// typed input and resizes are never delayed. libssh2 stays non-blocking — we
// only wait on the socket via poll(), then the owner thread retries nativeRead.
// For a ProxyJump session c->fd is the local socketpair end the jump-pump relays
// onto, so polling it for POLLIN still sees tunneled data. Owner thread only.
JNIEXPORT jint JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeWait(JNIEnv* env, jobject thiz, jlong handle, jint timeoutMs) {
    (void)env; (void)thiz;
    SshClient* c = (SshClient*)(intptr_t)handle;
    if (!c) return -1;
    struct pollfd pfds[2];
    int n = 0;
    if (c->fd >= 0) {
        int dir = libssh2_session_block_directions(c->session);
        short ev = 0;
        if (dir & LIBSSH2_SESSION_BLOCK_INBOUND) ev |= POLLIN;
        if (dir & LIBSSH2_SESSION_BLOCK_OUTBOUND) ev |= POLLOUT;
        if (ev == 0) ev = POLLIN;   // nothing pending — wait for more server output
        pfds[n].fd = c->fd; pfds[n].events = ev; pfds[n].revents = 0; n++;
    }
    if (c->wake[0] >= 0) { pfds[n].fd = c->wake[0]; pfds[n].events = POLLIN; pfds[n].revents = 0; n++; }
    if (n == 0) return 0;
    int r = poll(pfds, n, timeoutMs);
    if (r > 0) {
        for (int i = 0; i < n; i++) {
            if ((pfds[i].revents & POLLIN) && c->wake[0] >= 0 && pfds[i].fd == c->wake[0]) {
                char buf[64];
                while (read(c->wake[0], buf, sizeof(buf)) > 0) {}   // drain
            }
        }
    }
    return r < 0 ? -1 : 0;
}

// Poke the wake-pipe so a blocked nativeWait returns now (any thread). Used by
// the Kotlin write/resize/close staging path so input goes out immediately.
JNIEXPORT void JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeWake(JNIEnv* env, jobject thiz, jlong handle) {
    (void)env; (void)thiz;
    ssh_client_wake((SshClient*)(intptr_t)handle);
}

// Why the last nativeOpenShell(Sk) on this thread failed (an OPEN_* code), so
// the caller can show a specific message. Read it right after a 0-handle open,
// on the same thread that called open.
JNIEXPORT jint JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeLastOpenReason(JNIEnv* env, jobject thiz) {
    (void)env; (void)thiz;
    return (jint)g_open_reason;
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
    if (c->wake[0] >= 0) close(c->wake[0]);
    if (c->wake[1] >= 0) close(c->wake[1]);
    if (c->jump) jump_free(c->jump);
    free(c);
}

// ---- FIDO2 sk interactive shell + exec -----------------------------------
// Direct connections only (no ProxyJump for sk keys in v1). Mirrors
// nativeOpenShell / nativeAuthAndExec but authenticates via the sk path.

JNIEXPORT jlong JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeOpenShellSk(
    JNIEnv* env, jobject thiz, jstring jhost, jint port, jstring juser,
    jbyteArray jpubblob, jstring jprivpem, jobject signer, jint cols, jint rows,
    jbyteArray jexpectedHostKey) {
    (void)thiz;
    g_open_reason = OPEN_UNREACHABLE;   // refined as we get further in
    if (libssh2_init(0)) return 0;
    const char* host = (*env)->GetStringUTFChars(env, jhost, 0);
    const char* user = (*env)->GetStringUTFChars(env, juser, 0);
    const char* priv = (*env)->GetStringUTFChars(env, jprivpem, 0);
    size_t privlen = strlen(priv);
    jsize bloblen = (*env)->GetArrayLength(env, jpubblob);
    jbyte* blob = (*env)->GetByteArrayElements(env, jpubblob, 0);
    SshClient* client = NULL;
    int fd = tcp_connect(host, port);
    if (fd >= 0) {
        LIBSSH2_SESSION* s = open_session(fd);
        if (!s) g_open_reason = OPEN_HANDSHAKE;
        if (s && jexpectedHostKey != NULL) {
            size_t hklen = 0; int hktype = 0;
            const char* hk = libssh2_session_hostkey(s, &hklen, &hktype);
            jsize explen = (*env)->GetArrayLength(env, jexpectedHostKey);
            jbyte* exp = (*env)->GetByteArrayElements(env, jexpectedHostKey, 0);
            int mismatch = (!hk || (jsize)hklen != explen || memcmp(hk, exp, hklen) != 0);
            (*env)->ReleaseByteArrayElements(env, jexpectedHostKey, exp, JNI_ABORT);
            if (mismatch) {
                LOG("openShellSk: host key mismatch — refusing");
                g_open_reason = OPEN_HOST_KEY;
                libssh2_session_disconnect(s, "host key mismatch");
                libssh2_session_free(s); s = NULL;
            }
        }
        if (s) {
            int rc = sk_authenticate(env, s, user, (const unsigned char*)blob,
                                     (size_t)bloblen, priv, privlen, signer);
            if (rc == 0) {
                LIBSSH2_CHANNEL* ch = libssh2_channel_open_session(s);
                if (ch &&
                    libssh2_channel_request_pty_ex(ch, "xterm-256color", 14, NULL, 0, cols, rows, 0, 0) == 0 &&
                    libssh2_channel_process_startup(ch, "shell", 5, NULL, 0) == 0) {
                    libssh2_session_set_blocking(s, 0);
                    client = (SshClient*)calloc(1, sizeof(SshClient));
                    client->fd = fd; client->session = s; client->channel = ch; client->jump = NULL;
                    ssh_client_init_wake(client);
                    g_open_reason = OPEN_OK;
                } else {
                    g_open_reason = OPEN_NO_SHELL;
                    if (ch) libssh2_channel_free(ch);
                }
            } else {
                g_open_reason = OPEN_AUTH;
            }
            if (!client) { libssh2_session_disconnect(s, "bye"); libssh2_session_free(s); }
        }
        if (!client) close(fd);
    }
    (*env)->ReleaseStringUTFChars(env, jhost, host);
    (*env)->ReleaseStringUTFChars(env, juser, user);
    (*env)->ReleaseStringUTFChars(env, jprivpem, priv);
    (*env)->ReleaseByteArrayElements(env, jpubblob, blob, JNI_ABORT);
    return (jlong)(intptr_t)client;
}

JNIEXPORT jstring JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeAuthAndExecSk(
    JNIEnv* env, jobject thiz, jstring jhost, jint port, jstring juser,
    jbyteArray jpubblob, jstring jprivpem, jobject signer, jstring jcmd,
    jbyteArray jexpectedHostKey) {
    (void)thiz;
    if (libssh2_init(0)) return NULL;
    const char* host = (*env)->GetStringUTFChars(env, jhost, 0);
    const char* user = (*env)->GetStringUTFChars(env, juser, 0);
    const char* priv = (*env)->GetStringUTFChars(env, jprivpem, 0);
    const char* cmd = (*env)->GetStringUTFChars(env, jcmd, 0);
    size_t privlen = strlen(priv);
    jsize bloblen = (*env)->GetArrayLength(env, jpubblob);
    jbyte* blob = (*env)->GetByteArrayElements(env, jpubblob, 0);
    jstring result = NULL;
    g_open_reason = OPEN_UNREACHABLE;   // refined as we get further in
    int fd = tcp_connect(host, port);
    if (fd >= 0) {
        LIBSSH2_SESSION* s = open_session(fd);
        if (!s) g_open_reason = OPEN_HANDSHAKE;
        if (s && jexpectedHostKey != NULL) {
            size_t hklen = 0; int hktype = 0;
            const char* hk = libssh2_session_hostkey(s, &hklen, &hktype);
            jsize explen = (*env)->GetArrayLength(env, jexpectedHostKey);
            jbyte* exp = (*env)->GetByteArrayElements(env, jexpectedHostKey, 0);
            int mismatch = (!hk || (jsize)hklen != explen || memcmp(hk, exp, hklen) != 0);
            (*env)->ReleaseByteArrayElements(env, jexpectedHostKey, exp, JNI_ABORT);
            if (mismatch) {
                LOG("authAndExecSk: host key mismatch — refusing");
                g_open_reason = OPEN_HOST_KEY;
                libssh2_session_disconnect(s, "host key mismatch");
                libssh2_session_free(s); s = NULL;
            }
        }
        if (s) {
            int rc = sk_authenticate(env, s, user, (const unsigned char*)blob,
                                     (size_t)bloblen, priv, privlen, signer);
            if (rc == 0) {
                LIBSSH2_CHANNEL* c = libssh2_channel_open_session(s);
                if (c) {
                    // Full stdout capture (both streams drained); exec_capture sets
                    // g_open_reason. SSH OK; a missing MOSH CONNECT = mosh-server problem.
                    char* out = exec_capture(c, cmd);
                    if (out) {
                        result = (*env)->NewStringUTF(env, out);
                        free(out);
                    }
                    libssh2_channel_close(c);
                    libssh2_channel_free(c);
                } else {
                    g_open_reason = OPEN_NO_SHELL;
                }
            } else {
                g_open_reason = OPEN_AUTH;
            }
            libssh2_session_disconnect(s, "bye");
            libssh2_session_free(s);
        }
        close(fd);
    }
    (*env)->ReleaseStringUTFChars(env, jhost, host);
    (*env)->ReleaseStringUTFChars(env, juser, user);
    (*env)->ReleaseStringUTFChars(env, jprivpem, priv);
    (*env)->ReleaseStringUTFChars(env, jcmd, cmd);
    (*env)->ReleaseByteArrayElements(env, jpubblob, blob, JNI_ABORT);
    return result;
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
        unsigned mode =
            (attrs.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) ? (unsigned)(attrs.permissions & 07777) : 0u;
        snprintf(line, sizeof(line), "%c\t%llu\t%o\t%s", isdir ? 'd' : 'f', size, mode, namebuf);
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

// ---- Streaming SFTP transfer ---------------------------------------------
// Open a remote file and read/write it in chunks via a remote-file handle, so a
// large transfer flows through a fixed buffer instead of materializing the whole
// file in memory. All calls must stay on the SftpClient's single owner thread.

JNIEXPORT jlong JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeSftpOpenRead(
    JNIEnv* env, jobject thiz, jlong handle, jstring jpath) {
    (void)thiz;
    SftpClient* c = (SftpClient*)(intptr_t)handle;
    if (!c) return 0;
    const char* path = (*env)->GetStringUTFChars(env, jpath, 0);
    LIBSSH2_SFTP_HANDLE* h = sftp_open_retry(c, path, LIBSSH2_FXF_READ, 0, LIBSSH2_SFTP_OPENFILE);
    if (!h) LOG("sftp read open '%s' failed sftperr=%lu", path, libssh2_sftp_last_error(c->sftp));
    (*env)->ReleaseStringUTFChars(env, jpath, path);
    return (jlong)(intptr_t)h;
}

JNIEXPORT jlong JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeSftpOpenWrite(
    JNIEnv* env, jobject thiz, jlong handle, jstring jpath) {
    (void)thiz;
    SftpClient* c = (SftpClient*)(intptr_t)handle;
    if (!c) return 0;
    const char* path = (*env)->GetStringUTFChars(env, jpath, 0);
    unsigned long flags = LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC;
    LIBSSH2_SFTP_HANDLE* h = sftp_open_retry(c, path, flags, 0644, LIBSSH2_SFTP_OPENFILE);
    (*env)->ReleaseStringUTFChars(env, jpath, path);
    return (jlong)(intptr_t)h;
}

// Read up to buf.length bytes into buf. Returns bytes read (>0), 0 at EOF, -1 on error.
JNIEXPORT jint JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeSftpReadChunk(
    JNIEnv* env, jobject thiz, jlong fileHandle, jbyteArray jbuf) {
    (void)thiz;
    LIBSSH2_SFTP_HANDLE* h = (LIBSSH2_SFTP_HANDLE*)(intptr_t)fileHandle;
    if (!h) return -1;
    jsize cap = (*env)->GetArrayLength(env, jbuf);
    jbyte* buf = (*env)->GetByteArrayElements(env, jbuf, 0);
    ssize_t n = libssh2_sftp_read(h, (char*)buf, (size_t)cap);
    (*env)->ReleaseByteArrayElements(env, jbuf, buf, n > 0 ? 0 : JNI_ABORT);
    if (n > 0) return (jint)n;
    return n == 0 ? 0 : -1;
}

// Write exactly `len` bytes from buf. Returns true if all bytes were written.
JNIEXPORT jboolean JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeSftpWriteChunk(
    JNIEnv* env, jobject thiz, jlong fileHandle, jbyteArray jbuf, jint len) {
    (void)thiz;
    LIBSSH2_SFTP_HANDLE* h = (LIBSSH2_SFTP_HANDLE*)(intptr_t)fileHandle;
    if (!h) return JNI_FALSE;
    jbyte* buf = (*env)->GetByteArrayElements(env, jbuf, 0);
    jboolean ok = JNI_TRUE;
    jint off = 0;
    int stalls = 0;
    while (off < len) {
        ssize_t n = libssh2_sftp_write(h, (const char*)buf + off, (size_t)(len - off));
        if (n < 0 && n != LIBSSH2_ERROR_EAGAIN) { ok = JNI_FALSE; break; }   // hard error
        if (n <= 0) {                 // EAGAIN or no progress: throttle, don't busy-spin;
            if (++stalls > 5000) { ok = JNI_FALSE; break; }   // ~2.5s of true stall → bail
            usleep(500);
            continue;
        }
        stalls = 0;
        off += (jint)n;
    }
    (*env)->ReleaseByteArrayElements(env, jbuf, buf, JNI_ABORT);
    return ok;
}

JNIEXPORT void JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeSftpCloseFile(JNIEnv* env, jobject thiz, jlong fileHandle) {
    (void)env; (void)thiz;
    LIBSSH2_SFTP_HANDLE* h = (LIBSSH2_SFTP_HANDLE*)(intptr_t)fileHandle;
    if (h) libssh2_sftp_close_handle(h);
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

JNIEXPORT jboolean JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeSftpRename(
    JNIEnv* env, jobject thiz, jlong handle, jstring jfrom, jstring jto) {
    (void)thiz;
    SftpClient* c = (SftpClient*)(intptr_t)handle;
    if (!c) return JNI_FALSE;
    const char* from = (*env)->GetStringUTFChars(env, jfrom, 0);
    const char* to = (*env)->GetStringUTFChars(env, jto, 0);
    // overwrite | atomic | native — best-effort POSIX rename/move.
    long flags = LIBSSH2_SFTP_RENAME_OVERWRITE | LIBSSH2_SFTP_RENAME_ATOMIC |
                 LIBSSH2_SFTP_RENAME_NATIVE;
    int rc = libssh2_sftp_rename_ex(c->sftp, from, (unsigned)strlen(from),
                                    to, (unsigned)strlen(to), flags);
    if (rc != 0)
        LOG("sftp rename '%s'->'%s' failed rc=%d sftperr=%lu", from, to, rc,
            libssh2_sftp_last_error(c->sftp));
    (*env)->ReleaseStringUTFChars(env, jfrom, from);
    (*env)->ReleaseStringUTFChars(env, jto, to);
    return rc == 0 ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jboolean JNICALL
Java_cc_bsns_ssh_transport_SshBridge_nativeSftpSetPermissions(
    JNIEnv* env, jobject thiz, jlong handle, jstring jpath, jint mode) {
    (void)thiz;
    SftpClient* c = (SftpClient*)(intptr_t)handle;
    if (!c) return JNI_FALSE;
    const char* path = (*env)->GetStringUTFChars(env, jpath, 0);
    LIBSSH2_SFTP_ATTRIBUTES attrs;
    memset(&attrs, 0, sizeof(attrs));
    attrs.flags = LIBSSH2_SFTP_ATTR_PERMISSIONS;
    attrs.permissions = (unsigned long)(mode & 07777);
    int rc = libssh2_sftp_stat_ex(c->sftp, path, (unsigned)strlen(path),
                                  LIBSSH2_SFTP_SETSTAT, &attrs);
    if (rc != 0)
        LOG("sftp setstat '%s' mode=%o failed rc=%d sftperr=%lu", path, mode & 07777,
            rc, libssh2_sftp_last_error(c->sftp));
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
#define FWD_CAP (1 << 20)   // 1 MiB per-direction buffer cap → backpressure

typedef struct {
    int sock;                 // accepted loopback socket (-1 = free slot)
    LIBSSH2_CHANNEL* channel; // direct-tcpip channel to dest
    int sock_eof;             // local side closed its write
    int chan_eof;             // remote side closed its write
    int sent_chan_eof;        // we forwarded the local half-close to the channel
    ByteQueue to_channel;     // buffered local → remote
    ByteQueue to_local;       // buffered remote → local
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
    c->sock_eof = c->chan_eof = c->sent_chan_eof = 0;
    bq_free(&c->to_channel); bq_free(&c->to_local);
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
        for (int j = 0; j < FWD_CONN_MAX; j++) {
            FwdConn* c = &f->conns[j];
            if (c->sock < 0) continue;
            short ev = 0;
            // Read the local socket only while its outbound buffer has room (backpressure).
            if (!c->sock_eof && bq_count(&c->to_channel) < FWD_CAP) ev |= POLLIN;
            // Wait for writability when we have buffered bytes to push to the socket.
            if (bq_count(&c->to_local) > 0) ev |= POLLOUT;
            if (ev) { pfds[n].fd = c->sock; pfds[n].events = ev; pfds[n].revents = 0; n++; }
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

        // Pump each active connection both directions, all non-blocking and
        // bounded. We never spin to drain a slow peer: bytes that can't be sent
        // right now stay buffered and go out when poll() reports the destination
        // writable. Reading a source stops while its buffer is at cap, so a slow
        // consumer applies backpressure (TCP / the SSH window) instead of OOM.
        for (int j = 0; j < FWD_CONN_MAX; j++) {
            FwdConn* c = &f->conns[j];
            if (c->sock < 0) continue;
            active++;

            // remote channel → to_local buffer (stop while the local side is backed up)
            while (!c->chan_eof && bq_count(&c->to_local) < FWD_CAP) {
                ssize_t r = libssh2_channel_read(c->channel, buf, sizeof(buf));
                if (r > 0) bq_append(&c->to_local, (unsigned char*)buf, (size_t)r);
                else if (r == LIBSSH2_ERROR_EAGAIN) break;
                else { c->chan_eof = 1; break; }   // 0 = EOF, <0 = error
            }
            if (libssh2_channel_eof(c->channel)) c->chan_eof = 1;

            // to_local buffer → local socket (one non-blocking pass)
            while (bq_count(&c->to_local) > 0) {
                ssize_t w = send(c->sock, c->to_local.data + c->to_local.head, bq_count(&c->to_local), 0);
                if (w > 0) bq_consume(&c->to_local, (size_t)w);
                else { if (w < 0 && errno != EAGAIN && errno != EWOULDBLOCK) c->sock_eof = 1; break; }
            }

            // local socket → to_channel buffer (stop while the remote side is backed up)
            while (!c->sock_eof && bq_count(&c->to_channel) < FWD_CAP) {
                ssize_t r = recv(c->sock, buf, sizeof(buf), 0);
                if (r > 0) bq_append(&c->to_channel, (unsigned char*)buf, (size_t)r);
                else if (r == 0) { c->sock_eof = 1; break; }
                else { if (errno != EAGAIN && errno != EWOULDBLOCK) c->sock_eof = 1; break; }
            }

            // to_channel buffer → remote channel (one non-blocking pass)
            while (bq_count(&c->to_channel) > 0) {
                ssize_t w = libssh2_channel_write(c->channel, (char*)(c->to_channel.data + c->to_channel.head),
                                                  bq_count(&c->to_channel));
                if (w > 0) bq_consume(&c->to_channel, (size_t)w);
                else break;   // EAGAIN/error: retry next service
            }

            // Forward the local half-close once our outbound buffer is flushed.
            if (c->sock_eof && bq_count(&c->to_channel) == 0 && !c->sent_chan_eof) {
                libssh2_channel_send_eof(c->channel); c->sent_chan_eof = 1;
            }

            int remote_done = c->chan_eof && bq_count(&c->to_local) == 0;
            int local_done = c->sock_eof && bq_count(&c->to_channel) == 0;
            if (remote_done && local_done) { fwd_conn_close(c); active--; }
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
