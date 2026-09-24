#include "include/clair_ghostty_abi.h"

#if defined(CLAIR_GHOSTTY_VENDORED)
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// T01's init/info/config subset was originally exposed to Swift as
// function-like macros (`#define clair_ghostty_init(argc, argv)
// ghostty_init((argc), (argv))`). Swift's Clang importer does not import
// function-like macros that expand to a call expression, so those macros
// were never actually reachable from `GhosttyRuntime.swift` — this was
// only discovered now, by T08, because T01's environment never vendored
// the real library and so never ran `swift build` against it. Real
// functions instead, matching the rest of this file's `ghostty_surface_*`
// wrappers.
int clair_ghostty_init(uintptr_t argc, char **argv) {
  return ghostty_init(argc, argv);
}

clair_ghostty_info_s clair_ghostty_info(void) {
  ghostty_info_s real = ghostty_info();
  clair_ghostty_info_s out;
  memcpy(&out, &real, sizeof(out));
  return out;
}

clair_ghostty_config_t clair_ghostty_config_new(void) {
  return (clair_ghostty_config_t)ghostty_config_new();
}

void clair_ghostty_config_free(clair_ghostty_config_t config) {
  ghostty_config_free((ghostty_config_t)config);
}

void clair_ghostty_config_load_file(clair_ghostty_config_t config, const char *path) {
  ghostty_config_load_file((ghostty_config_t)config, path);
}

void clair_ghostty_config_finalize(clair_ghostty_config_t config) {
  ghostty_config_finalize((ghostty_config_t)config);
}

uint32_t clair_ghostty_config_diagnostics_count(clair_ghostty_config_t config) {
  return ghostty_config_diagnostics_count((ghostty_config_t)config);
}

// --- Runtime callback table (T08) -----------------------------------------
//
// libghostty's app requires real, non-null callbacks for wakeup, clipboard
// read/confirm/write, and action delivery (see `ghostty_runtime_config_s`).
// This subset does not expose any of them to Swift: Clair's minimal
// surface-embedding smoke test does not need libghostty to read or write
// the system clipboard, nor to hand back arbitrary app actions, so every
// callback here is a fixed, always-safe no-op/deny. A future task that
// needs real clipboard or action integration extends this table (and adds
// its own layout assertions for whatever payload it actually reads) rather
// than punching a hole through it.
static void clair_ghostty_wakeup_cb(void *userdata) {
  (void)userdata;
}

static ghostty_clipboard_read_result_e clair_ghostty_read_clipboard_cb(
    void *userdata, ghostty_clipboard_e clipboard, void *state,
    const char *const *mime_types, size_t mime_types_len, bool required) {
  (void)userdata;
  (void)clipboard;
  (void)state;
  (void)mime_types;
  (void)mime_types_len;
  (void)required;
  return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE;
}

static void clair_ghostty_confirm_read_clipboard_cb(
    void *userdata, const ghostty_clipboard_confirm_s *confirm, void *state,
    ghostty_clipboard_request_e request_type) {
  (void)userdata;
  (void)confirm;
  (void)state;
  (void)request_type;
}

static void clair_ghostty_write_clipboard_cb(
    void *userdata, ghostty_clipboard_e clipboard,
    const ghostty_clipboard_content_s *content, size_t content_len, bool confirmed) {
  (void)userdata;
  (void)clipboard;
  (void)content;
  (void)content_len;
  (void)confirmed;
}

// V08: the only actions read are RING_BELL, DESKTOP_NOTIFICATION and
// SHOW_CHILD_EXITED, and only their facts (a bell count, the exit code) are kept, in a per-app record that
// Swift drains after `tick()` (`clair_ghostty_app_take_events`). No payload
// other than `child_exited.exit_code` is decoded; every action is still
// reported "not handled" so libghostty's default behavior is unchanged.
typedef struct {
  uint32_t bells;
  int64_t exit_code;  // -1 = the child has not exited
  bool title_changed;
  char title[256];  // the window title, shown in the Mac sidebar the way Ghostty shows it in its tab
} clair_ghostty_app_events_record;

static bool clair_ghostty_action_cb(
    ghostty_app_t app, ghostty_target_s target, ghostty_action_s action) {
  (void)target;
  clair_ghostty_app_events_record *rec = ghostty_app_userdata(app);
  if (!rec) return false;
  // Agents (Claude Code, Codex) ask for attention with OSC 9/777 rather than BEL.
  // It counts as a bell: its title/body are agent text (may quote code), so they
  // are never decoded and cannot reach a macOS banner or a future mobile push.
  if (action.tag == GHOSTTY_ACTION_RING_BELL || action.tag == GHOSTTY_ACTION_DESKTOP_NOTIFICATION)
    rec->bells++;
  else if (action.tag == GHOSTTY_ACTION_SET_TITLE) {
    const char *t = action.action.set_title.title;
    snprintf(rec->title, sizeof(rec->title), "%s", t ? t : "");
    rec->title_changed = true;
  } else if (action.tag == GHOSTTY_ACTION_SHOW_CHILD_EXITED)
    rec->exit_code = (int64_t)action.action.child_exited.exit_code;
  return false;
}

clair_ghostty_app_t clair_ghostty_app_new(clair_ghostty_config_t config) {
  ghostty_runtime_config_s runtime_config;
  memset(&runtime_config, 0, sizeof(runtime_config));
  clair_ghostty_app_events_record *rec = calloc(1, sizeof(*rec));
  if (!rec) return NULL;
  rec->exit_code = -1;
  runtime_config.userdata = rec;
  runtime_config.supports_selection_clipboard = false;
  runtime_config.wakeup_cb = clair_ghostty_wakeup_cb;
  runtime_config.action_cb = clair_ghostty_action_cb;
  runtime_config.read_clipboard_cb = clair_ghostty_read_clipboard_cb;
  runtime_config.confirm_read_clipboard_cb = clair_ghostty_confirm_read_clipboard_cb;
  runtime_config.write_clipboard_cb = clair_ghostty_write_clipboard_cb;
  runtime_config.close_surface_cb = NULL;
  ghostty_app_t app = ghostty_app_new(&runtime_config, (ghostty_config_t)config);
  if (!app) free(rec);
  return (clair_ghostty_app_t)app;
}

void clair_ghostty_app_take_events(clair_ghostty_app_t app, clair_ghostty_app_events_s *out) {
  clair_ghostty_app_events_record *rec = ghostty_app_userdata((ghostty_app_t)app);
  out->bells = rec ? rec->bells : 0;
  out->exit_code = rec ? rec->exit_code : -1;
  out->title_changed = rec && rec->title_changed;
  if (rec) memcpy(out->title, rec->title, sizeof(out->title));
  if (rec) { rec->bells = 0; rec->title_changed = false; }  // bells/title drained; the exit code is sticky
}

void clair_ghostty_app_free(clair_ghostty_app_t app) {
  void *rec = ghostty_app_userdata((ghostty_app_t)app);
  ghostty_app_free((ghostty_app_t)app);
  free(rec);
}

void clair_ghostty_app_tick(clair_ghostty_app_t app) {
  ghostty_app_tick((ghostty_app_t)app);
}

clair_ghostty_surface_config_s clair_ghostty_surface_config_new(void) {
  ghostty_surface_config_s real = ghostty_surface_config_new();
  clair_ghostty_surface_config_s out;
  // Safe because of the sizeof/offsetof assertions above: both structs have
  // identical layout, only the (Clair-prefixed) nominal type differs.
  memcpy(&out, &real, sizeof(out));
  return out;
}

clair_ghostty_surface_t clair_ghostty_surface_new(
    clair_ghostty_app_t app, const clair_ghostty_surface_config_s *config) {
  ghostty_surface_config_s real;
  memcpy(&real, config, sizeof(real));
  return (clair_ghostty_surface_t)ghostty_surface_new((ghostty_app_t)app, &real);
}

void clair_ghostty_surface_free(clair_ghostty_surface_t surface) {
  ghostty_surface_free((ghostty_surface_t)surface);
}

void clair_ghostty_surface_set_size(
    clair_ghostty_surface_t surface, uint32_t width_px, uint32_t height_px) {
  ghostty_surface_set_size((ghostty_surface_t)surface, width_px, height_px);
}

clair_ghostty_surface_size_s clair_ghostty_surface_size(clair_ghostty_surface_t surface) {
  ghostty_surface_size_s real = ghostty_surface_size((ghostty_surface_t)surface);
  clair_ghostty_surface_size_s out;
  memcpy(&out, &real, sizeof(out));
  return out;
}

bool clair_ghostty_surface_read_text(
    clair_ghostty_surface_t surface, clair_ghostty_selection_s selection,
    clair_ghostty_text_s *out_text) {
  ghostty_selection_s real_selection;
  memcpy(&real_selection, &selection, sizeof(real_selection));
  ghostty_text_s real_text;
  memset(&real_text, 0, sizeof(real_text));
  bool ok = ghostty_surface_read_text(
      (ghostty_surface_t)surface, real_selection, &real_text);
  if (ok && out_text) {
    memcpy(out_text, &real_text, sizeof(*out_text));
  }
  return ok;
}

void clair_ghostty_surface_free_text(
    clair_ghostty_surface_t surface, clair_ghostty_text_s *text) {
  ghostty_text_s real_text;
  memcpy(&real_text, text, sizeof(real_text));
  ghostty_surface_free_text((ghostty_surface_t)surface, &real_text);
  memcpy(text, &real_text, sizeof(*text));
}

bool clair_ghostty_surface_key(
    clair_ghostty_surface_t surface, clair_ghostty_input_key_s event) {
  ghostty_input_key_s real_event;
  memcpy(&real_event, &event, sizeof(real_event));
  return ghostty_surface_key((ghostty_surface_t)surface, real_event);
}

void clair_ghostty_surface_text(
    clair_ghostty_surface_t surface, const char *text, uintptr_t text_len) {
  ghostty_surface_text((ghostty_surface_t)surface, text, text_len);
}

void clair_ghostty_surface_preedit(
    clair_ghostty_surface_t surface, const char *text, uintptr_t text_len) {
  ghostty_surface_preedit((ghostty_surface_t)surface, text, text_len);
}

void clair_ghostty_surface_ime_point(
    clair_ghostty_surface_t surface, double *x, double *y, double *width, double *height) {
  ghostty_surface_ime_point((ghostty_surface_t)surface, x, y, width, height);
}

bool clair_ghostty_surface_mouse_button(
    clair_ghostty_surface_t surface, clair_ghostty_mouse_state_e state,
    clair_ghostty_mouse_button_e button, clair_ghostty_input_mods_e mods) {
  return ghostty_surface_mouse_button(
      (ghostty_surface_t)surface, (ghostty_input_mouse_state_e)state,
      (ghostty_input_mouse_button_e)button, (ghostty_input_mods_e)mods);
}

void clair_ghostty_surface_mouse_pos(
    clair_ghostty_surface_t surface, double x, double y, clair_ghostty_input_mods_e mods) {
  ghostty_surface_mouse_pos((ghostty_surface_t)surface, x, y, (ghostty_input_mods_e)mods);
}

void clair_ghostty_surface_mouse_scroll(
    clair_ghostty_surface_t surface, double x, double y, clair_ghostty_scroll_mods_t mods) {
  ghostty_surface_mouse_scroll((ghostty_surface_t)surface, x, y, (ghostty_input_scroll_mods_t)mods);
}

void clair_ghostty_surface_set_focus(clair_ghostty_surface_t surface, bool focused) {
  ghostty_surface_set_focus((ghostty_surface_t)surface, focused);
}

void clair_ghostty_surface_set_content_scale(
    clair_ghostty_surface_t surface, double x_scale, double y_scale) {
  ghostty_surface_set_content_scale((ghostty_surface_t)surface, x_scale, y_scale);
}

bool clair_ghostty_surface_has_selection(clair_ghostty_surface_t surface) {
  return ghostty_surface_has_selection((ghostty_surface_t)surface);
}

bool clair_ghostty_surface_read_selection(
    clair_ghostty_surface_t surface, clair_ghostty_text_s *out_text) {
  ghostty_text_s real_text;
  memset(&real_text, 0, sizeof(real_text));
  bool ok = ghostty_surface_read_selection((ghostty_surface_t)surface, &real_text);
  if (ok && out_text) {
    memcpy(out_text, &real_text, sizeof(*out_text));
  }
  return ok;
}
#endif // CLAIR_GHOSTTY_VENDORED

int clair_ghostty_abi_is_vendored(void) {
#if defined(CLAIR_GHOSTTY_VENDORED)
  // Referencing the probe pointers here (rather than leaving them as
  // unused file-scope statics) both silences unused-variable warnings and
  // gives the ABI check one real use site: if any upstream symbol failed
  // to resolve to a non-null function pointer, this vendored build is not
  // actually usable and callers should not trust `clair_ghostty_abi_is_vendored`.
  return clair_ghostty_probe_init != 0 && clair_ghostty_probe_info != 0 &&
         clair_ghostty_probe_config_new != 0 &&
         clair_ghostty_probe_config_free != 0 &&
         clair_ghostty_probe_config_load_file != 0 &&
         clair_ghostty_probe_config_finalize != 0 &&
         clair_ghostty_probe_config_diagnostics_count != 0 &&
         clair_ghostty_probe_app_new != 0 && clair_ghostty_probe_app_free != 0 &&
         clair_ghostty_probe_app_tick != 0 &&
         clair_ghostty_probe_surface_config_new != 0 &&
         clair_ghostty_probe_surface_new != 0 &&
         clair_ghostty_probe_surface_free != 0 &&
         clair_ghostty_probe_surface_set_size != 0 &&
         clair_ghostty_probe_surface_size != 0 &&
         clair_ghostty_probe_surface_read_text != 0 &&
         clair_ghostty_probe_surface_free_text != 0 &&
         clair_ghostty_probe_surface_key != 0 && clair_ghostty_probe_surface_text != 0 &&
         clair_ghostty_probe_surface_mouse_button != 0 &&
         clair_ghostty_probe_surface_mouse_pos != 0 &&
         clair_ghostty_probe_surface_mouse_scroll != 0 &&
         clair_ghostty_probe_surface_set_focus != 0 &&
         clair_ghostty_probe_surface_set_content_scale != 0 &&
         clair_ghostty_probe_surface_has_selection != 0 &&
         clair_ghostty_probe_surface_read_selection != 0;
#else
  return 0;
#endif
}
