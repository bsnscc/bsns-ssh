// Our replacement for mosh's terminfo/curses-based Terminal::Display. mosh syncs
// terminal *state* (a Framebuffer); this turns the current framebuffer into ANSI
// escape sequences we can feed straight to SwiftTerm — no terminfo, so it builds
// cleanly for iOS. v1 does a full repaint per frame (correct; optimize to diffs
// later). Copied to mosh-src/src/terminal/terminaldisplay.cc by fetch-mosh.sh.
#include <string>
#include "src/terminal/terminaldisplay.h"
#include "src/terminal/terminalframebuffer.h"

using namespace Terminal;

Display::Display( bool )
  : has_ech( true ), has_bce( true ), has_title( false ), smcup( nullptr ), rmcup( nullptr )
{}

std::string Display::open() const { return std::string(); }
std::string Display::close() const { return "\033[0m\033[?25h"; }

std::string Display::new_frame( bool /*initialized*/, const Framebuffer& /*last*/, const Framebuffer& f ) const
{
  std::string out;
  out.reserve( 8192 );
  out += "\033[?25l";       // hide cursor while repainting
  out += "\033[H\033[2J";   // home + clear screen
  out += "\033[0m";

  const int height = f.ds.get_height();
  const int width = f.ds.get_width();
  std::string last_sgr;

  for ( int y = 0; y < height; y++ ) {
    out += "\033[" + std::to_string( y + 1 ) + ";1H";
    for ( int x = 0; x < width; x++ ) {
      const Cell* cell = f.get_cell( y, x );
      if ( cell == nullptr ) { out += ' '; continue; }

      const std::string sgr = cell->get_renditions().sgr();
      if ( sgr != last_sgr ) { out += sgr; last_sgr = sgr; }

      if ( cell->empty() ) {
        out += ' ';
      } else {
        cell->print_grapheme( out );
      }
      const int cw = static_cast<int>( cell->get_width() );
      if ( cw > 1 ) { x += cw - 1; }   // skip the trailing column of a wide glyph
    }
  }

  out += "\033[0m";
  out += "\033[" + std::to_string( f.ds.get_cursor_row() + 1 ) + ";"
       + std::to_string( f.ds.get_cursor_col() + 1 ) + "H";
  out += "\033[?25h";   // show cursor again
  return out;
}

// put_row()/can_use_erase() are private and unused by this renderer, so they are
// left undefined — never odr-used, so linking doesn't need them.
