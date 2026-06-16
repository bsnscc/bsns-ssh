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
  std::vector<int> fds = c->transport->fds();
  return fds.empty() ? -1 : fds.front();
}

int mosh_client_wait_ms(MoshClient* c) {
  if (!c || !c->transport) return 1000;
  return c->transport->wait_time();
}

void mosh_client_freeze_time(void) {
  freeze_timestamp();
}

void mosh_client_recv(MoshClient* c) {
  if (!c || !c->transport) return;
  try { c->transport->recv(); }
  catch (const Network::NetworkException&) { /* drop bad/duplicate datagrams */ }
  catch (...) {}
}

void mosh_client_tick(MoshClient* c) {
  if (!c || !c->transport) return;
  try { c->transport->tick(); }
  catch (const Network::NetworkException& e) { c->lastError = e.what(); }
  catch (...) {}
}

void mosh_client_push(MoshClient* c, const char* bytes, int len) {
  if (!c || !c->transport || !bytes) return;
  Network::UserStream& s = c->transport->get_current_state();
  for (int i = 0; i < len; i++) {
    s.push_back(Parser::UserByte(static_cast<unsigned char>(bytes[i])));
  }
}

void mosh_client_resize(MoshClient* c, int cols, int rows) {
  if (!c || !c->transport) return;
  c->transport->get_current_state().push_back(Parser::Resize(cols, rows));
}

char* mosh_client_drain_ansi(MoshClient* c) {
  if (!c || !c->transport) return nullptr;
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
}

const char* mosh_client_last_error(MoshClient* c) {
  return (c && !c->lastError.empty()) ? c->lastError.c_str() : nullptr;
}

}  // extern "C"
