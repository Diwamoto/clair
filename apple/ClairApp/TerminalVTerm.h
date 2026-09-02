#ifndef CLAIR_TERMINAL_VTERM_H
#define CLAIR_TERMINAL_VTERM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct ClairVTerm ClairVTerm;

typedef struct {
  uint32_t codepoint;
  uint16_t attributes;
  uint8_t width;
  uint8_t foreground_red;
  uint8_t foreground_green;
  uint8_t foreground_blue;
  uint8_t background_red;
  uint8_t background_green;
  uint8_t background_blue;
  bool uses_default_foreground;
  bool uses_default_background;
} ClairVTermCell;

ClairVTerm *clair_vterm_create(int rows, int columns);
void clair_vterm_destroy(ClairVTerm *terminal);
void clair_vterm_feed(ClairVTerm *terminal, const uint8_t *bytes, size_t length);
void clair_vterm_reset(ClairVTerm *terminal);
void clair_vterm_resize(ClairVTerm *terminal, int rows, int columns);
int clair_vterm_rows(const ClairVTerm *terminal);
int clair_vterm_columns(const ClairVTerm *terminal);
int clair_vterm_scrollback_rows(const ClairVTerm *terminal);
bool clair_vterm_cell_at(
  const ClairVTerm *terminal,
  int row,
  int column,
  ClairVTermCell *cell
);
bool clair_vterm_scrollback_cell_at(
  const ClairVTerm *terminal,
  int row,
  int column,
  ClairVTermCell *cell
);
void clair_vterm_cursor(
  const ClairVTerm *terminal,
  int *row,
  int *column,
  bool *visible
);

#endif  // CLAIR_TERMINAL_VTERM_H
