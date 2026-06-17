// JNI bridge over the vendored mosh client (libmosh.a / moshclient.h). mosh's
// Transport isn't thread-safe, so the Kotlin MoshSession drives every call from
// one owner thread; write()/resize() stage work and poke a wake-pipe so the
// poll in nativeMoshService returns promptly (low input latency without a busy
// loop). Mirrors the iOS MoshSession run loop. (C++ JNI: env->Method(args).)
#include <jni.h>
#include <android/log.h>
#include <poll.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdint.h>

#include "moshclient.h"

#define LOG(...) __android_log_print(ANDROID_LOG_INFO, "moshbridge", __VA_ARGS__)

namespace {
struct MoshHandle {
    MoshClient* client;
    int wake[2];          // self-pipe: wake[1] written to interrupt the poll
    uint64_t lastContactMs;   // monotonic time of the last datagram from the server
};

uint64_t nowMonoMs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}
}

extern "C" {

JNIEXPORT jlong JNICALL
Java_cc_bsns_ssh_transport_MoshBridge_nativeMoshOpen(
    JNIEnv* env, jobject thiz, jstring jip, jstring jport, jstring jkey, jint cols, jint rows) {
    (void)thiz;
    const char* ip = env->GetStringUTFChars(jip, nullptr);
    const char* port = env->GetStringUTFChars(jport, nullptr);
    const char* key = env->GetStringUTFChars(jkey, nullptr);
    MoshClient* c = mosh_client_create(ip, port, key, cols, rows);
    env->ReleaseStringUTFChars(jip, ip);
    env->ReleaseStringUTFChars(jport, port);
    env->ReleaseStringUTFChars(jkey, key);
    if (!c) return 0;
    if (mosh_client_last_error(c)) {
        LOG("mosh open failed: %s", mosh_client_last_error(c));
        mosh_client_free(c);
        return 0;
    }
    MoshHandle* h = (MoshHandle*)calloc(1, sizeof(MoshHandle));
    h->client = c;
    h->lastContactMs = nowMonoMs();
    if (pipe(h->wake) == 0) {
        fcntl(h->wake[0], F_SETFL, O_NONBLOCK);
        fcntl(h->wake[1], F_SETFL, O_NONBLOCK);
    } else {
        h->wake[0] = h->wake[1] = -1;
    }
    return (jlong)(intptr_t)h;
}

// poll(mosh-fd + wake-pipe) up to min(maxMs, mosh's own wait time); recv if the
// socket is readable; tick; return any new ANSI frame (or null). Owner thread.
JNIEXPORT jbyteArray JNICALL
Java_cc_bsns_ssh_transport_MoshBridge_nativeMoshService(
    JNIEnv* env, jobject thiz, jlong handle, jint maxMs) {
    (void)thiz;
    MoshHandle* h = (MoshHandle*)(intptr_t)handle;
    if (!h || !h->client) return nullptr;

    // Refresh mosh's frozen clock once per service iteration. Without this the
    // send/ack timers stall after the first packet and local input is never
    // transmitted (server paints once, then keystrokes do nothing).
    mosh_client_freeze_time();

    int waitMs = mosh_client_wait_ms(h->client);
    if (waitMs < 0) waitMs = 1000;
    if (maxMs >= 0 && maxMs < waitMs) waitMs = maxMs;

    int mfd = mosh_client_fd(h->client);
    struct pollfd pfds[2];
    int n = 0;
    if (mfd >= 0) { pfds[n].fd = mfd; pfds[n].events = POLLIN; pfds[n].revents = 0; n++; }
    if (h->wake[0] >= 0) { pfds[n].fd = h->wake[0]; pfds[n].events = POLLIN; pfds[n].revents = 0; n++; }

    int r = poll(pfds, n, waitMs);
    if (r > 0) {
        for (int i = 0; i < n; i++) {
            if (!(pfds[i].revents & POLLIN)) continue;
            if (pfds[i].fd == mfd) {
                mosh_client_recv(h->client);
                h->lastContactMs = nowMonoMs();   // a datagram arrived from the server
            } else {
                char buf[64];
                while (read(h->wake[0], buf, sizeof(buf)) > 0) {}   // drain
            }
        }
    }
    mosh_client_tick(h->client);

    char* ansi = mosh_client_drain_ansi(h->client);
    if (!ansi) return nullptr;
    size_t len = strlen(ansi);
    jbyteArray out = env->NewByteArray((jsize)len);
    if (out) env->SetByteArrayRegion(out, 0, (jsize)len, (const jbyte*)ansi);
    free(ansi);
    return out;
}

// Milliseconds since the last datagram from the server — the liveness signal.
// mosh never self-closes on silence (it roams), so the UI uses this to show a
// session has gone stale rather than a reassuring "connected".
JNIEXPORT jlong JNICALL
Java_cc_bsns_ssh_transport_MoshBridge_nativeMoshMsSinceContact(
    JNIEnv* env, jobject thiz, jlong handle) {
    (void)env; (void)thiz;
    MoshHandle* h = (MoshHandle*)(intptr_t)handle;
    if (!h) return 0;
    return (jlong)(nowMonoMs() - h->lastContactMs);
}

JNIEXPORT void JNICALL
Java_cc_bsns_ssh_transport_MoshBridge_nativeMoshPush(
    JNIEnv* env, jobject thiz, jlong handle, jbyteArray jdata) {
    (void)thiz;
    MoshHandle* h = (MoshHandle*)(intptr_t)handle;
    if (!h || !h->client) return;
    jsize len = env->GetArrayLength(jdata);
    jbyte* d = env->GetByteArrayElements(jdata, nullptr);
    mosh_client_push(h->client, (const char*)d, (int)len);
    env->ReleaseByteArrayElements(jdata, d, JNI_ABORT);
}

JNIEXPORT void JNICALL
Java_cc_bsns_ssh_transport_MoshBridge_nativeMoshResize(
    JNIEnv* env, jobject thiz, jlong handle, jint cols, jint rows) {
    (void)env; (void)thiz;
    MoshHandle* h = (MoshHandle*)(intptr_t)handle;
    if (h && h->client) mosh_client_resize(h->client, cols, rows);
}

// Poke the wake-pipe so a blocked nativeMoshService returns now (any thread).
JNIEXPORT void JNICALL
Java_cc_bsns_ssh_transport_MoshBridge_nativeMoshWake(
    JNIEnv* env, jobject thiz, jlong handle) {
    (void)env; (void)thiz;
    MoshHandle* h = (MoshHandle*)(intptr_t)handle;
    if (h && h->wake[1] >= 0) { char b = 1; ssize_t w = write(h->wake[1], &b, 1); (void)w; }
}

JNIEXPORT jstring JNICALL
Java_cc_bsns_ssh_transport_MoshBridge_nativeMoshLastError(
    JNIEnv* env, jobject thiz, jlong handle) {
    (void)thiz;
    MoshHandle* h = (MoshHandle*)(intptr_t)handle;
    if (!h || !h->client) return nullptr;
    const char* e = mosh_client_last_error(h->client);
    return e ? env->NewStringUTF(e) : nullptr;
}

JNIEXPORT void JNICALL
Java_cc_bsns_ssh_transport_MoshBridge_nativeMoshClose(
    JNIEnv* env, jobject thiz, jlong handle) {
    (void)env; (void)thiz;
    MoshHandle* h = (MoshHandle*)(intptr_t)handle;
    if (!h) return;
    if (h->wake[0] >= 0) close(h->wake[0]);
    if (h->wake[1] >= 0) close(h->wake[1]);
    if (h->client) mosh_client_free(h->client);
    free(h);
}

}  // extern "C"
