#include "include/clair_ghostty_vt_abi.h"

#if defined(CLAIR_GHOSTTY_VT_VENDORED)
#include <string.h>

clair_ghostty_vt_result_e clair_ghostty_vt_terminal_new(
    clair_ghostty_vt_terminal_t *out_terminal, uint16_t cols, uint16_t rows) {
  GhosttyTerminal terminal = NULL;
  GhosttyResult result = ghostty_terminal_new(NULL, &terminal, cols, rows);
  if (out_terminal) {
    *out_terminal = (clair_ghostty_vt_terminal_t)terminal;
  }
  return (clair_ghostty_vt_result_e)result;
}

void clair_ghostty_vt_terminal_free(clair_ghostty_vt_terminal_t terminal) {
  ghostty_terminal_free((GhosttyTerminal)terminal);
}

clair_ghostty_vt_result_e clair_ghostty_vt_terminal_resize(
    clair_ghostty_vt_terminal_t terminal, uint16_t cols, uint16_t rows, uint32_t cell_width_px,
    uint32_t cell_height_px) {
  return (clair_ghostty_vt_result_e)ghostty_terminal_resize(
      (GhosttyTerminal)terminal, cols, rows, cell_width_px, cell_height_px);
}

void clair_ghostty_vt_terminal_write(
    clair_ghostty_vt_terminal_t terminal, const uint8_t *data, size_t len) {
  ghostty_terminal_vt_write((GhosttyTerminal)terminal, data, len);
}

clair_ghostty_vt_result_e clair_ghostty_vt_cursor_x(
    clair_ghostty_vt_terminal_t terminal, uint16_t *out) {
  return (clair_ghostty_vt_result_e)ghostty_terminal_get(
      (GhosttyTerminal)terminal, GHOSTTY_TERMINAL_DATA_CURSOR_X, out);
}

clair_ghostty_vt_result_e clair_ghostty_vt_cursor_y(
    clair_ghostty_vt_terminal_t terminal, uint16_t *out) {
  return (clair_ghostty_vt_result_e)ghostty_terminal_get(
      (GhosttyTerminal)terminal, GHOSTTY_TERMINAL_DATA_CURSOR_Y, out);
}

clair_ghostty_vt_result_e clair_ghostty_vt_cursor_visible(
    clair_ghostty_vt_terminal_t terminal, bool *out) {
  return (clair_ghostty_vt_result_e)ghostty_terminal_get(
      (GhosttyTerminal)terminal, GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE, out);
}

clair_ghostty_vt_result_e clair_ghostty_vt_total_rows(
    clair_ghostty_vt_terminal_t terminal, size_t *out) {
  return (clair_ghostty_vt_result_e)ghostty_terminal_get(
      (GhosttyTerminal)terminal, GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, out);
}

clair_ghostty_vt_result_e clair_ghostty_vt_scrollback_rows(
    clair_ghostty_vt_terminal_t terminal, size_t *out) {
  return (clair_ghostty_vt_result_e)ghostty_terminal_get(
      (GhosttyTerminal)terminal, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, out);
}

clair_ghostty_vt_result_e clair_ghostty_vt_grid_ref(
    clair_ghostty_vt_terminal_t terminal, clair_ghostty_vt_point_s point,
    clair_ghostty_vt_grid_ref_s *out_ref) {
  GhosttyPoint real_point;
  memcpy(&real_point, &point, sizeof(real_point));
  GhosttyGridRef real_ref;
  memset(&real_ref, 0, sizeof(real_ref));
  GhosttyResult result =
      ghostty_terminal_grid_ref((GhosttyTerminal)terminal, real_point, &real_ref);
  if (result == GHOSTTY_SUCCESS && out_ref) {
    memcpy(out_ref, &real_ref, sizeof(*out_ref));
  }
  return (clair_ghostty_vt_result_e)result;
}

clair_ghostty_vt_result_e clair_ghostty_vt_select_all(
    clair_ghostty_vt_terminal_t terminal, clair_ghostty_vt_selection_s *out_selection) {
  GhosttySelection real_selection = GHOSTTY_INIT_SIZED(GhosttySelection);
  GhosttyResult result = ghostty_terminal_select_all((GhosttyTerminal)terminal, &real_selection);
  if (result == GHOSTTY_SUCCESS && out_selection) {
    memcpy(out_selection, &real_selection, sizeof(*out_selection));
  }
  return (clair_ghostty_vt_result_e)result;
}

clair_ghostty_vt_result_e clair_ghostty_vt_format_selection_alloc(
    clair_ghostty_vt_terminal_t terminal, const clair_ghostty_vt_selection_s *selection,
    bool unwrap, bool trim, uint8_t **out_ptr, size_t *out_len) {
  GhosttySelection real_selection;
  memcpy(&real_selection, selection, sizeof(real_selection));
  GhosttyTerminalSelectionFormatOptions options =
      GHOSTTY_INIT_SIZED(GhosttyTerminalSelectionFormatOptions);
  options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
  options.unwrap = unwrap;
  options.trim = trim;
  options.selection = &real_selection;
  return (clair_ghostty_vt_result_e)ghostty_terminal_selection_format_alloc(
      (GhosttyTerminal)terminal, NULL, options, out_ptr, out_len);
}

void clair_ghostty_vt_free(uint8_t *ptr, size_t len) { ghostty_free(NULL, ptr, len); }

void clair_ghostty_vt_scroll_viewport(
    clair_ghostty_vt_terminal_t terminal, clair_ghostty_vt_scroll_s behavior) {
  GhosttyTerminalScrollViewport real_behavior;
  memcpy(&real_behavior, &behavior, sizeof(real_behavior));
  ghostty_terminal_scroll_viewport((GhosttyTerminal)terminal, real_behavior);
}
#endif  // CLAIR_GHOSTTY_VT_VENDORED

int clair_ghostty_vt_abi_is_vendored(void) {
#if defined(CLAIR_GHOSTTY_VT_VENDORED)
  // Referencing the probe pointers here (rather than leaving them as unused
  // file-scope statics) both silences unused-variable warnings and gives
  // the ABI check one real use site, same as `clair_ghostty_abi_is_vendored`
  // (`ClairGhosttyABI`).
  return clair_ghostty_vt_probe_terminal_new != 0 && clair_ghostty_vt_probe_terminal_free != 0 &&
         clair_ghostty_vt_probe_terminal_resize != 0 &&
         clair_ghostty_vt_probe_terminal_vt_write != 0 &&
         clair_ghostty_vt_probe_terminal_get != 0 &&
         clair_ghostty_vt_probe_terminal_grid_ref != 0 &&
         clair_ghostty_vt_probe_terminal_select_all != 0 &&
         clair_ghostty_vt_probe_terminal_selection_format_alloc != 0 &&
         clair_ghostty_vt_probe_terminal_scroll_viewport != 0 && clair_ghostty_vt_probe_free != 0;
#else
  return 0;
#endif
}
