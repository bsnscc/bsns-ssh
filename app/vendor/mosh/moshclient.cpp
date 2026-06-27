// C++ implementation of the plain-C mosh client interface (moshclient.h).
// Wraps mosh's Transport<UserStream, Complete> and renders the synced remote
// framebuffer to ANSI via our Display.
#include "moshclient.h"

#include <clocale>
#include <cstdlib>
#include <cstring>
#include <string>

#include "src/util/fatal_assert.h"
#include "src/network/network.h"
#include "src/network/networktransport.h"
#include "src/network/networktransport-impl.h"
#include "src/statesync/user.h"
#include "src/statesync/completeterminal.h"
#include "src/terminal/parseraction.h"
#include "src/terminal/terminaldisplay.h"
#include "src/terminal/terminalframebuffer.h"
#include "src/util/timestamp.h"

typedef Network::Transport<Network::UserStream, Terminal::Complete> ClientTransport;

struct MoshClient {
  Network::UserStream local;
  Terminal::Complete remote;
  Terminal::Display display;
  Terminal::Framebuffer lastFb;   // what we last emitted as ANSI; diff target
  ClientTransport* transport;
  uint64_t lastStateNum;
  bool rendered;
  std::string lastError;

  MoshClient(int cols, int rows)
    : local(), remote(cols, rows), display(false), lastFb(cols, rows),
      transport(nullptr), lastStateNum(0), rendered(false) {}
};

extern "C" {

MoshClient* mosh_client_create(const char* ip, const char* port, const char* key, int cols, int rows) {
  // mosh stores cell contents as wide chars and re-encodes them to UTF-8 with the
  // C library (Cell::print_grapheme → wcrtomb), which is LOCALE-DEPENDENT. Our app
  // process never calls setlocale, so it sits in the default "C" locale and every
  // multibyte glyph re-encodes as U+FFFD (�). Force a UTF-8 ctype locale here so
  // the framebuffer renders real glyphs. (Both iOS and Android go through here.)
  if (!setlocale(LC_CTYPE, "en_US.UTF-8")) {
    setlocale(LC_CTYPE, "UTF-8");
  }
  MoshClient* c = new MoshClient(cols > 0 ? cols : 80, rows > 0 ? rows : 24);
  try {
    c->transport = new ClientTransport(c->local, c->remote, key, ip, port);
  } catch (const Network::NetworkException& e) {
    c->lastError = e.what();
  } catch (const std::exception& e) {
    c->lastError = e.what();
  } catch (...) {
    c->lastError = "mosh transport init failed";
  }
  return c;
}

void mosh_client_free(MoshClient* c) {
  if (!c) return;
  delete c->transport;
  delete c;
}

int mosh_client_fd(MoshClient* c) {
  if (!c || !c->transport) return -1;
  try {
    std::vector<int> fds = c->transport->fds();
    return fds.empty() ? -1 : fds.back();
  } catch (const std::exception& e) {
    c->lastError = e.what();
    return -1;
  } catch (...) {
    c->lastError = "mosh fd lookup failed";
    return -1;
  }
}

int mosh_client_fds(MoshClient* c, int* out, int capacity) {
  if (!c || !c->transport || !out || capacity <= 0) return 0;
  try {
    std::vector<int> fds = c->transport->fds();
    int n = static_cast<int>(fds.size());
    if (n > capacity) n = capacity;
    for (int i = 0; i < n; i++) out[i] = fds[i];
    return n;
  } catch (const std::exception& e) {
    c->lastError = e.what();
    return 0;
  } catch (...) {
    c->lastError = "mosh fd lookup failed";
    return 0;
  }
}

int mosh_client_wait_ms(MoshClient* c) {
  if (!c || !c->transport) return 1000;
  try {
    return c->transport->wait_time();
  } catch (const std::exception& e) {
    c->lastError = e.what();
    return 1000;
  } catch (...) {
    c->lastError = "mosh wait time failed";
    return 1000;
  }
}

void mosh_client_freeze_time(void) {
  freeze_timestamp();
}

int mosh_client_recv(MoshClient* c) {
  if (!c || !c->transport) return 0;
  // recv() returns normally only when a datagram was received AND decrypted into a
  // real peer packet; connection.recv() throws NetworkException on EAGAIN, a
  // stray/ICMP wake on a dead post-hop socket, a failed decrypt, or a duplicate.
  // So the return value distinguishes "the server is actually reaching us" (1)
  // from "the socket was merely readable but nothing valid arrived" (0) — the
  // fork between a dead roamed path and an in-protocol state drop.
  try { c->transport->recv(); return 1; }
  catch (const Network::NetworkException&) { return 0; }
  catch (const std::exception& e) { c->lastError = e.what(); return 0; }
  catch (...) { c->lastError = "mosh recv failed"; return 0; }
}

void mosh_client_tick(MoshClient* c) {
  if (!c || !c->transport) return;
  try { c->transport->tick(); }
  catch (const Network::NetworkException& e) { c->lastError = e.what(); }
  catch (const std::exception& e) { c->lastError = e.what(); }
  catch (...) { c->lastError = "mosh tick failed"; }
}

void mosh_client_hop(MoshClient* c) {
  if (!c || !c->transport) return;
  // Force the connection onto a fresh local socket (mosh roaming), preserving
  // the crypto sequence the server requires. Called on resume-from-background,
  // where iOS has torn down our suspended UDP socket.
  try { c->transport->hop(); }
  catch (const std::exception& e) { c->lastError = e.what(); }
  catch (...) { c->lastError = "mosh hop failed"; }
}

void mosh_client_prime_active_retry(MoshClient* c) {
  if (!c || !c->transport) return;
  try { c->transport->prime_active_retry(); }
  catch (const std::exception& e) { c->lastError = e.what(); }
  catch (...) { c->lastError = "mosh active retry prime failed"; }
}

void mosh_client_force_repaint(MoshClient* c) {
  // Drop the diff baseline so the next drain_ansi emits a FULL repaint (clear +
  // redraw of the entire framebuffer) instead of a delta — recovers a desynced
  // display after resume (wrong row count / stale gap).
  if (c) c->rendered = false;
}

void mosh_client_push(MoshClient* c, const char* bytes, int len) {
  if (!c || !c->transport || !bytes) return;
  try {
    Network::UserStream& s = c->transport->get_current_state();
    for (int i = 0; i < len; i++) {
      s.push_back(Parser::UserByte(static_cast<unsigned char>(bytes[i])));
    }
  } catch (const std::exception& e) {
    c->lastError = e.what();
  } catch (...) {
    c->lastError = "mosh input push failed";
  }
}

void mosh_client_resize(MoshClient* c, int cols, int rows) {
  if (!c || !c->transport) return;
  try {
    c->transport->get_current_state().push_back(Parser::Resize(cols, rows));
  } catch (const std::exception& e) {
    c->lastError = e.what();
  } catch (...) {
    c->lastError = "mosh resize failed";
  }
}

void mosh_client_fb_dims(MoshClient* c, int* cols, int* rows) {
  if (cols) *cols = 0;
  if (rows) *rows = 0;
  if (!c || !c->transport) return;
  try {
    const Terminal::Framebuffer& fb = c->transport->get_latest_remote_state().state.get_fb();
    if (cols) *cols = fb.ds.get_width();
    if (rows) *rows = fb.ds.get_height();
  } catch (...) {}
}

char* mosh_client_drain_ansi(MoshClient* c) {
  if (!c || !c->transport) return nullptr;
  try {
    const uint64_t num = c->transport->get_remote_state_num();
    if (c->rendered && num == c->lastStateNum) return nullptr;
    c->lastStateNum = num;
    // Diff the new remote framebuffer against the one we last emitted so the ANSI
    // carries only the delta (cursor moves, changed cells). The first frame uses
    // initialized=false for a full repaint; after that we diff lastFb -> fb.
    const Terminal::Framebuffer& fb = c->transport->get_latest_remote_state().state.get_fb();
    const std::string ansi = c->display.new_frame(c->rendered, c->lastFb, fb);
    c->lastFb = fb;
    c->rendered = true;
    char* out = static_cast<char*>(malloc(ansi.size() + 1));
    if (!out) return nullptr;
    memcpy(out, ansi.data(), ansi.size());
    out[ansi.size()] = '\0';
    return out;
  } catch (const Network::NetworkException& e) {
    c->lastError = e.what();
    c->rendered = false;
    return nullptr;
  } catch (const std::exception& e) {
    c->lastError = e.what();
    c->rendered = false;
    return nullptr;
  } catch (...) {
    c->lastError = "mosh framebuffer render failed";
    c->rendered = false;
    return nullptr;
  }
}

uint64_t mosh_client_state_num(MoshClient* c) {
  if (!c || !c->transport) return 0;
  try {
    return c->transport->get_remote_state_num();
  } catch (...) {
    return 0;
  }
}

const char* mosh_client_last_error(MoshClient* c) {
  return (c && !c->lastError.empty()) ? c->lastError.c_str() : nullptr;
}

}  // extern "C"
