#include "TerminalVTerm.h"

#include <string.h>

#include <vterm.h>

#define CLAIR_VTERM_SCROLLBACK_LIMIT 4000

typedef struct {
  int columns;
  ClairVTermCell *cells;
} ClairVTermScrollbackLine;

struct ClairVTerm {
  VTerm *vterm;
  VTermScreen *screen;
  int rows;
  int columns;
  int cursor_row;
  int cursor_column;
  bool cursor_visible;
  ClairVTermScrollbackLine scrollback[CLAIR_VTERM_SCROLLBACK_LIMIT];
  size_t scrollback_start;
  size_t scrollback_count;
};

static void clair_vterm_copy_cell(
  ClairVTerm *terminal,
  const VTermScreenCell *source,
  ClairVTermCell *cell
) {
  memset(cell, 0, sizeof(*cell));
  cell->codepoint = source->chars[0];
  cell->width = source->width > 0 ? (uint8_t)source->width : 0;
  cell->attributes =
    (source->attrs.bold ? 1U << 0 : 0U) | (source->attrs.underline ? 1U << 1 : 0U)
    | (source->attrs.italic ? 1U << 2 : 0U) | (source->attrs.reverse ? 1U << 3 : 0U)
    | (source->attrs.strike ? 1U << 4 : 0U) | (source->attrs.conceal ? 1U << 5 : 0U);

  VTermColor foreground = source->fg;
  VTermColor background = source->bg;
  cell->uses_default_foreground = VTERM_COLOR_IS_DEFAULT_FG(&foreground);
  cell->uses_default_background = VTERM_COLOR_IS_DEFAULT_BG(&background);
  vterm_screen_convert_color_to_rgb(terminal->screen, &foreground);
  vterm_screen_convert_color_to_rgb(terminal->screen, &background);
  cell->foreground_red = foreground.rgb.red;
  cell->foreground_green = foreground.rgb.green;
  cell->foreground_blue = foreground.rgb.blue;
  cell->background_red = background.rgb.red;
  cell->background_green = background.rgb.green;
  cell->background_blue = background.rgb.blue;
}

static void clair_vterm_clear_scrollback(ClairVTerm *terminal) {
  for (size_t index = 0; index < terminal->scrollback_count; index++) {
    size_t line_index = (terminal->scrollback_start + index) % CLAIR_VTERM_SCROLLBACK_LIMIT;
    free(terminal->scrollback[line_index].cells);
    terminal->scrollback[line_index] = (ClairVTermScrollbackLine){0};
  }
  terminal->scrollback_start = 0;
  terminal->scrollback_count = 0;
}

static int clair_vterm_scrollback_pushline(int columns, const VTermScreenCell *cells, void *user) {
  ClairVTerm *terminal = user;
  if (columns <= 0 || cells == NULL) {
    return 1;
  }

  size_t line_index;
  if (terminal->scrollback_count == CLAIR_VTERM_SCROLLBACK_LIMIT) {
    line_index = terminal->scrollback_start;
    free(terminal->scrollback[line_index].cells);
    terminal->scrollback_start = (terminal->scrollback_start + 1) % CLAIR_VTERM_SCROLLBACK_LIMIT;
  } else {
    line_index =
      (terminal->scrollback_start + terminal->scrollback_count) % CLAIR_VTERM_SCROLLBACK_LIMIT;
    terminal->scrollback_count++;
  }

  ClairVTermCell *line = calloc((size_t)columns, sizeof(*line));
  if (line == NULL) {
    return 1;
  }
  for (int column = 0; column < columns; column++) {
    clair_vterm_copy_cell(terminal, cells + column, line + column);
  }
  terminal->scrollback[line_index] = (ClairVTermScrollbackLine){
    .columns = columns,
    .cells = line,
  };
  return 1;
}

static int clair_vterm_scrollback_clear(void *user) {
  clair_vterm_clear_scrollback(user);
  return 1;
}

static int clair_vterm_damage(VTermRect rect, void *user) {
  (void)rect;
  (void)user;
  return 1;
}

static int clair_vterm_move_cursor(
  VTermPos position,
  VTermPos old_position,
  int visible,
  void *user
) {
  (void)old_position;
  ClairVTerm *terminal = user;
  terminal->cursor_row = position.row;
  terminal->cursor_column = position.col;
  terminal->cursor_visible = visible != 0;
  return 1;
}

static int clair_vterm_set_property(VTermProp property, VTermValue *value, void *user) {
  ClairVTerm *terminal = user;
  if (property == VTERM_PROP_CURSORVISIBLE) {
    terminal->cursor_visible = value->boolean != 0;
  }
  return 1;
}

static int clair_vterm_resize_callback(int rows, int columns, void *user) {
  ClairVTerm *terminal = user;
  terminal->rows = rows;
  terminal->columns = columns;
  return 1;
}

static VTermScreenCallbacks clair_vterm_callbacks = {
  .damage = clair_vterm_damage,
  .movecursor = clair_vterm_move_cursor,
  .settermprop = clair_vterm_set_property,
  .resize = clair_vterm_resize_callback,
  .sb_pushline = clair_vterm_scrollback_pushline,
  .sb_clear = clair_vterm_scrollback_clear,
};

ClairVTerm *clair_vterm_create(int rows, int columns) {
  if (rows <= 0 || columns <= 0) {
    return NULL;
  }

  ClairVTerm *terminal = calloc(1, sizeof(*terminal));
  if (terminal == NULL) {
    return NULL;
  }

  terminal->vterm = vterm_new(rows, columns);
  if (terminal->vterm == NULL) {
    free(terminal);
    return NULL;
  }

  terminal->rows = rows;
  terminal->columns = columns;
  terminal->cursor_visible = true;
  vterm_set_utf8(terminal->vterm, 1);
  terminal->screen = vterm_obtain_screen(terminal->vterm);
  vterm_screen_set_callbacks(terminal->screen, &clair_vterm_callbacks, terminal);
  vterm_screen_enable_altscreen(terminal->screen, 1);
  vterm_screen_set_damage_merge(terminal->screen, VTERM_DAMAGE_SCREEN);
  vterm_screen_reset(terminal->screen, 1);
  return terminal;
}

void clair_vterm_destroy(ClairVTerm *terminal) {
  if (terminal == NULL) {
    return;
  }
  clair_vterm_clear_scrollback(terminal);
  vterm_free(terminal->vterm);
  free(terminal);
}

void clair_vterm_reset(ClairVTerm *terminal) {
  if (terminal == NULL) {
    return;
  }
  clair_vterm_clear_scrollback(terminal);
  vterm_screen_reset(terminal->screen, 1);
  vterm_screen_flush_damage(terminal->screen);
}

void clair_vterm_feed(ClairVTerm *terminal, const uint8_t *bytes, size_t length) {
  if (terminal == NULL || bytes == NULL || length == 0) {
    return;
  }
  vterm_input_write(terminal->vterm, (const char *)bytes, length);
  vterm_screen_flush_damage(terminal->screen);
}

void clair_vterm_resize(ClairVTerm *terminal, int rows, int columns) {
  if (terminal == NULL || rows <= 0 || columns <= 0) {
    return;
  }
  vterm_set_size(terminal->vterm, rows, columns);
  terminal->rows = rows;
  terminal->columns = columns;
  vterm_screen_flush_damage(terminal->screen);
}

int clair_vterm_rows(const ClairVTerm *terminal) {
  return terminal == NULL ? 0 : terminal->rows;
}

int clair_vterm_columns(const ClairVTerm *terminal) {
  return terminal == NULL ? 0 : terminal->columns;
}

int clair_vterm_scrollback_rows(const ClairVTerm *terminal) {
  return terminal == NULL ? 0 : (int)terminal->scrollback_count;
}

bool clair_vterm_cell_at(
  const ClairVTerm *terminal,
  int row,
  int column,
  ClairVTermCell *cell
) {
  if (
    terminal == NULL || cell == NULL || row < 0 || row >= terminal->rows || column < 0
    || column >= terminal->columns
  ) {
    return false;
  }

  VTermScreenCell source;
  memset(&source, 0, sizeof(source));
  if (!vterm_screen_get_cell(terminal->screen, (VTermPos){.row = row, .col = column}, &source)) {
    return false;
  }

  clair_vterm_copy_cell((ClairVTerm *)terminal, &source, cell);
  return true;
}

bool clair_vterm_scrollback_cell_at(
  const ClairVTerm *terminal,
  int row,
  int column,
  ClairVTermCell *cell
) {
  if (
    terminal == NULL || cell == NULL || row < 0 || row >= (int)terminal->scrollback_count
    || column < 0
  ) {
    return false;
  }
  size_t line_index =
    (terminal->scrollback_start + (size_t)row) % CLAIR_VTERM_SCROLLBACK_LIMIT;
  ClairVTermScrollbackLine line = terminal->scrollback[line_index];
  if (column >= line.columns || line.cells == NULL) {
    return false;
  }
  *cell = line.cells[column];
  return true;
}

void clair_vterm_cursor(
  const ClairVTerm *terminal,
  int *row,
  int *column,
  bool *visible
) {
  if (row != NULL) {
    *row = terminal == NULL ? 0 : terminal->cursor_row;
  }
  if (column != NULL) {
    *column = terminal == NULL ? 0 : terminal->cursor_column;
  }
  if (visible != NULL) {
    *visible = terminal != NULL && terminal->cursor_visible;
  }
}
