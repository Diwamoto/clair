#ifndef CLAIR_GHOSTTY_ABI_H
#define CLAIR_GHOSTTY_ABI_H

// Pinned C ABI subset for libghostty (see Config/ghostty-pin.json).
//
// libghostty's embedder C API (`ghostty.h`) is explicitly pre-1.0 and
// undocumented upstream: "The only consumer of this API is the macOS app...
// most functions are undocumented". Clair depends on a small, explicitly
// reviewed subset of it — not "whatever ghostty.h currently exports". This
// header re-declares that subset under a `clair_` prefix so the compiled
// dependency surface is visible in one place.
//
// When `CLAIR_GHOSTTY_VENDORED` is defined (set by Package.swift only when
// both the pinned commit's real `ghostty.h` AND a built
// `GhosttyKit.xcframework` have been materialized into
// `packages/ClairV2Core/Vendor/ghostty/` by `scripts/v2-ghostty.sh vendor`),
// this header additionally includes the real upstream header and statically
// asserts that this subset still matches it: struct layout via
// `_Static_assert(sizeof/offsetof, ...)`, and function presence/signature by
// assigning the real symbol to a function pointer of the exact expected
// type. An upstream rename, removal, or signature change of anything in
// this subset is then a compile error here, not undefined behavior at
// runtime.
//
// When `CLAIR_GHOSTTY_VENDORED` is not defined, only the value types below
// are visible; no function symbol is declared, so nothing can accidentally
// link against a library that was never vendored. `ClairV2Ghostty` (the
// Swift boundary) never calls into this header outside a matching
// `#if CLAIR_GHOSTTY_VENDORED` guard.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CLAIR_GHOSTTY_SUCCESS 0

// Opaque handles. Owned by the C library; Clair never dereferences them,
// only passes them back to the matching free/consuming function inside the
// same scope that allocated them.
typedef void *clair_ghostty_config_t;
typedef void *clair_ghostty_app_t;
typedef void *clair_ghostty_surface_t;

typedef enum {
  CLAIR_GHOSTTY_BUILD_MODE_DEBUG = 0,
  CLAIR_GHOSTTY_BUILD_MODE_RELEASE_SAFE = 1,
  CLAIR_GHOSTTY_BUILD_MODE_RELEASE_FAST = 2,
  CLAIR_GHOSTTY_BUILD_MODE_RELEASE_SMALL = 3,
} clair_ghostty_build_mode_e;

typedef struct {
  clair_ghostty_build_mode_e build_mode;
  const char *version;
  uintptr_t version_len;
} clair_ghostty_info_s;

// --- ghostty_surface_* subset (T08) ---------------------------------------
//
// T01 pinned only init/info/config: enough to prove the library links and
// initializes, but not the "embedder" entry points a real pixel surface
// needs. T03 discovered that gap while trying to connect a real macOS
// Ghostty surface. This subset is the minimal set T08 verified end-to-end
// against the real, vendored library on this machine: create a real
// `ghostty_app_t` + `ghostty_surface_t` backed by a real `NSView`, let
// libghostty spawn and run its own child process for that surface (the
// surface's PTY is owned by libghostty itself, not by Clair — there is no
// upstream entry point to inject externally-produced PTY bytes into a
// surface that did not spawn its own child; embedding means configuring
// what libghostty runs, not writing to its PTY from outside), and read the
// resulting rendered screen content back out with `ghostty_surface_read_text`.
//
// Two upstream types are intentionally NOT mirrored here even though one of
// them crosses this ABI by value: `ghostty_target_s` and `ghostty_action_s`
// (the two arguments of the app's `action_cb` runtime callback). They are a
// large tagged union of every action variant the full macOS app handles
// (window management, IPC, config reload, ...); Clair's action callback is
// a fail-safe no-op that always reports "not handled" and never inspects
// the payload. Mirroring their full internal layout field-by-field buys no
// safety today and would need re-deriving on every upstream action addition
// for a payload nothing here reads. When vendored, the callback typedef
// below references the *real* upstream types directly (via `#include
// <ghostty.h>`), so a real signature change to either type is still a
// compile error here, not silent runtime drift; it only skips the
// additional sizeof/offsetof assertions this file uses for structs Clair
// actually reads fields from.
typedef enum {
  CLAIR_GHOSTTY_PLATFORM_INVALID = 0,
  CLAIR_GHOSTTY_PLATFORM_MACOS = 1,
  CLAIR_GHOSTTY_PLATFORM_IOS = 2,
} clair_ghostty_platform_e;

typedef struct {
  void *nsview;
} clair_ghostty_platform_macos_s;

typedef struct {
  void *uiview;
} clair_ghostty_platform_ios_s;

typedef union {
  clair_ghostty_platform_macos_s macos;
  clair_ghostty_platform_ios_s ios;
} clair_ghostty_platform_u;

typedef enum {
  CLAIR_GHOSTTY_SURFACE_CONTEXT_WINDOW = 0,
  CLAIR_GHOSTTY_SURFACE_CONTEXT_TAB = 1,
  CLAIR_GHOSTTY_SURFACE_CONTEXT_SPLIT = 2,
} clair_ghostty_surface_context_e;

typedef struct {
  const char *key;
  const char *value;
} clair_ghostty_env_var_s;

// Mirrors `ghostty_surface_config_s`. Passed by value into
// `ghostty_surface_new`, so field order/type/count must match exactly; the
// `_Static_assert`s below (vendored builds only) enforce that.
typedef struct {
  clair_ghostty_platform_e platform_tag;
  clair_ghostty_platform_u platform;
  void *userdata;
  double scale_factor;
  float font_size;
  const char *working_directory;
  const char *command;
  clair_ghostty_env_var_s *env_vars;
  size_t env_var_count;
  const char *initial_input;
  bool wait_after_command;
  clair_ghostty_surface_context_e context;
} clair_ghostty_surface_config_s;

// Mirrors `ghostty_surface_size_s`. This is the "cell grid" dimension
// readback this task's smoke test asserts on: rows/columns plus the pixel
// geometry a real renderer derived them from.
typedef struct {
  uint16_t columns;
  uint16_t rows;
  uint32_t width_px;
  uint32_t height_px;
  uint32_t cell_width_px;
  uint32_t cell_height_px;
} clair_ghostty_surface_size_s;

typedef enum {
  CLAIR_GHOSTTY_POINT_ACTIVE = 0,
  CLAIR_GHOSTTY_POINT_VIEWPORT = 1,
  CLAIR_GHOSTTY_POINT_SCREEN = 2,
  CLAIR_GHOSTTY_POINT_SURFACE = 3,
} clair_ghostty_point_tag_e;

typedef enum {
  CLAIR_GHOSTTY_POINT_COORD_EXACT = 0,
  CLAIR_GHOSTTY_POINT_COORD_TOP_LEFT = 1,
  CLAIR_GHOSTTY_POINT_COORD_BOTTOM_RIGHT = 2,
} clair_ghostty_point_coord_e;

typedef struct {
  clair_ghostty_point_tag_e tag;
  clair_ghostty_point_coord_e coord;
  uint32_t x;
  uint32_t y;
} clair_ghostty_point_s;

// A screen-relative or cursor-relative ("active") span. `CLAIR_GHOSTTY_
// POINT_ACTIVE` addresses text relative to the cursor position; this is the
// closest verifiable equivalent the internal embedder ABI exposes to a
// direct "read cursor row/column" call (no such direct query exists in this
// header's upstream source — see the invariants doc for this task).
typedef struct {
  clair_ghostty_point_s top_left;
  clair_ghostty_point_s bottom_right;
  bool rectangle;
} clair_ghostty_selection_s;

// Mirrors `ghostty_text_s`: a borrowed, non-null-terminated read of
// rendered screen text. Must be released with
// `clair_ghostty_surface_free_text` exactly once.
typedef struct {
  double tl_px_x;
  double tl_px_y;
  uint32_t offset_start;
  uint32_t offset_len;
  const char *text;
  uintptr_t text_len;
} clair_ghostty_text_s;

typedef enum {
  CLAIR_GHOSTTY_CLIPBOARD_STANDARD = 0,
  CLAIR_GHOSTTY_CLIPBOARD_SELECTION = 1,
  CLAIR_GHOSTTY_CLIPBOARD_PRIMARY = 2,
} clair_ghostty_clipboard_e;

typedef enum {
  CLAIR_GHOSTTY_CLIPBOARD_READ_STARTED = 0,
  CLAIR_GHOSTTY_CLIPBOARD_READ_UNAVAILABLE = 1,
  CLAIR_GHOSTTY_CLIPBOARD_READ_UNSUPPORTED = 2,
} clair_ghostty_clipboard_read_result_e;

typedef enum {
  CLAIR_GHOSTTY_CLIPBOARD_REQUEST_PASTE = 0,
  CLAIR_GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ = 1,
  CLAIR_GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE = 2,
  CLAIR_GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ = 3,
  CLAIR_GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE = 4,
  CLAIR_GHOSTTY_CLIPBOARD_REQUEST_LIST = 5,
} clair_ghostty_clipboard_request_e;

typedef struct {
  const char *mime;
  const char *data;
  size_t len;
} clair_ghostty_clipboard_content_s;

typedef struct {
  const clair_ghostty_clipboard_content_s *contents;
  size_t contents_len;
  const char *const *available;
  size_t available_len;
  const char *name;
  bool can_remember;
} clair_ghostty_clipboard_confirm_s;

#if defined(CLAIR_GHOSTTY_VENDORED)

#include <ghostty.h>

// --- Struct layout invariants --------------------------------------------
_Static_assert(sizeof(clair_ghostty_build_mode_e) == sizeof(ghostty_build_mode_e),
               "ghostty_build_mode_e size changed upstream");
_Static_assert(sizeof(clair_ghostty_config_t) == sizeof(ghostty_config_t),
               "ghostty_config_t representation changed upstream");
_Static_assert(sizeof(clair_ghostty_info_s) == sizeof(ghostty_info_s),
               "ghostty_info_s size changed upstream");
_Static_assert(offsetof(clair_ghostty_info_s, build_mode) ==
                   offsetof(ghostty_info_s, build_mode),
               "ghostty_info_s.build_mode offset changed upstream");
_Static_assert(offsetof(clair_ghostty_info_s, version) ==
                   offsetof(ghostty_info_s, version),
               "ghostty_info_s.version offset changed upstream");
_Static_assert(offsetof(clair_ghostty_info_s, version_len) ==
                   offsetof(ghostty_info_s, version_len),
               "ghostty_info_s.version_len offset changed upstream");

_Static_assert(sizeof(clair_ghostty_app_t) == sizeof(ghostty_app_t),
               "ghostty_app_t representation changed upstream");
_Static_assert(sizeof(clair_ghostty_surface_t) == sizeof(ghostty_surface_t),
               "ghostty_surface_t representation changed upstream");

#define CLAIR_GHOSTTY_ASSERT_FIELD(clair_type, upstream_type, field)         \
  _Static_assert(offsetof(clair_type, field) == offsetof(upstream_type, field), \
                 #upstream_type "." #field " offset changed upstream")

_Static_assert(sizeof(clair_ghostty_surface_config_s) == sizeof(ghostty_surface_config_s),
               "ghostty_surface_config_s size changed upstream");
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_surface_config_s, ghostty_surface_config_s, platform_tag);
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_surface_config_s, ghostty_surface_config_s, platform);
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_surface_config_s, ghostty_surface_config_s, userdata);
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_surface_config_s, ghostty_surface_config_s, scale_factor);
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_surface_config_s, ghostty_surface_config_s, font_size);
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_surface_config_s, ghostty_surface_config_s, working_directory);
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_surface_config_s, ghostty_surface_config_s, command);
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_surface_config_s, ghostty_surface_config_s, env_vars);
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_surface_config_s, ghostty_surface_config_s, env_var_count);
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_surface_config_s, ghostty_surface_config_s, initial_input);
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_surface_config_s, ghostty_surface_config_s, wait_after_command);
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_surface_config_s, ghostty_surface_config_s, context);

_Static_assert(sizeof(clair_ghostty_surface_size_s) == sizeof(ghostty_surface_size_s),
               "ghostty_surface_size_s size changed upstream");
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_surface_size_s, ghostty_surface_size_s, columns);
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_surface_size_s, ghostty_surface_size_s, rows);
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_surface_size_s, ghostty_surface_size_s, width_px);
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_surface_size_s, ghostty_surface_size_s, height_px);
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_surface_size_s, ghostty_surface_size_s, cell_width_px);
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_surface_size_s, ghostty_surface_size_s, cell_height_px);

_Static_assert(sizeof(clair_ghostty_point_s) == sizeof(ghostty_point_s),
               "ghostty_point_s size changed upstream");
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_point_s, ghostty_point_s, tag);
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_point_s, ghostty_point_s, coord);
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_point_s, ghostty_point_s, x);
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_point_s, ghostty_point_s, y);

_Static_assert(sizeof(clair_ghostty_selection_s) == sizeof(ghostty_selection_s),
               "ghostty_selection_s size changed upstream");
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_selection_s, ghostty_selection_s, top_left);
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_selection_s, ghostty_selection_s, bottom_right);
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_selection_s, ghostty_selection_s, rectangle);

_Static_assert(sizeof(clair_ghostty_text_s) == sizeof(ghostty_text_s),
               "ghostty_text_s size changed upstream");
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_text_s, ghostty_text_s, tl_px_x);
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_text_s, ghostty_text_s, tl_px_y);
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_text_s, ghostty_text_s, offset_start);
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_text_s, ghostty_text_s, offset_len);
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_text_s, ghostty_text_s, text);
CLAIR_GHOSTTY_ASSERT_FIELD(clair_ghostty_text_s, ghostty_text_s, text_len);

_Static_assert(sizeof(clair_ghostty_clipboard_content_s) == sizeof(ghostty_clipboard_content_s),
               "ghostty_clipboard_content_s size changed upstream");
_Static_assert(sizeof(clair_ghostty_clipboard_confirm_s) == sizeof(ghostty_clipboard_confirm_s),
               "ghostty_clipboard_confirm_s size changed upstream");

#undef CLAIR_GHOSTTY_ASSERT_FIELD

// --- Function presence/signature invariants ------------------------------
// Assigning the real upstream symbol to a function pointer variable of the
// exact expected type fails to compile (not link, not run) if upstream
// removes, renames, or changes the signature of a function this subset
// depends on. `static` + "used" via the exported wrapper below keeps these
// from being optimized away as dead globals ahead of the check running.
static int (*const clair_ghostty_probe_init)(uintptr_t, char **) = ghostty_init;
static ghostty_info_s (*const clair_ghostty_probe_info)(void) = ghostty_info;
static ghostty_config_t (*const clair_ghostty_probe_config_new)(void) =
    ghostty_config_new;
static void (*const clair_ghostty_probe_config_free)(ghostty_config_t) =
    ghostty_config_free;
static ghostty_app_t (*const clair_ghostty_probe_app_new)(
    const ghostty_runtime_config_s *, ghostty_config_t) = ghostty_app_new;
static void (*const clair_ghostty_probe_app_free)(ghostty_app_t) = ghostty_app_free;
static void (*const clair_ghostty_probe_app_tick)(ghostty_app_t) = ghostty_app_tick;
static ghostty_surface_config_s (*const clair_ghostty_probe_surface_config_new)(void) =
    ghostty_surface_config_new;
static ghostty_surface_t (*const clair_ghostty_probe_surface_new)(
    ghostty_app_t, const ghostty_surface_config_s *) = ghostty_surface_new;
static void (*const clair_ghostty_probe_surface_free)(ghostty_surface_t) =
    ghostty_surface_free;
static void (*const clair_ghostty_probe_surface_set_size)(ghostty_surface_t, uint32_t, uint32_t) =
    ghostty_surface_set_size;
static ghostty_surface_size_s (*const clair_ghostty_probe_surface_size)(ghostty_surface_t) =
    ghostty_surface_size;
static bool (*const clair_ghostty_probe_surface_read_text)(
    ghostty_surface_t, ghostty_selection_s, ghostty_text_s *) = ghostty_surface_read_text;
static void (*const clair_ghostty_probe_surface_free_text)(ghostty_surface_t, ghostty_text_s *) =
    ghostty_surface_free_text;

// These are real functions (defined in clair_ghostty_abi.c), not macros:
// Swift's Clang importer does not import function-like macros that expand
// to a call expression (only a small set of literal-constant macro forms),
// so `#define clair_ghostty_init(argc, argv) ghostty_init((argc), (argv))`
// silently is *not visible from Swift at all* — `swift build` fails with
// "cannot find 'clair_ghostty_init' in scope" the moment something is
// actually vendored and this file is compiled against the real header.
// T01 never caught this because nothing had ever been vendored in that
// environment; T08 hit it immediately on first real vendor + `swift
// build` and converts all four to real functions here.
int clair_ghostty_init(uintptr_t argc, char **argv);
clair_ghostty_info_s clair_ghostty_info(void);
clair_ghostty_config_t clair_ghostty_config_new(void);
void clair_ghostty_config_free(clair_ghostty_config_t config);

// clair_ghostty_app_new/surface_new/surface_config_new are real functions
// (not macros) defined in clair_ghostty_abi.c: they own the conversion
// between this file's mirrored, layout-asserted value types and the real
// upstream ones (`memcpy`, safe because of the assertions above), and they
// own the runtime callback table (wakeup/clipboard/action callbacks), which
// this subset deliberately keeps as internal, always-safe no-ops rather
// than exposing libghostty's full callback surface across the Swift
// boundary. See clair_ghostty_abi.c for the callback bodies.
clair_ghostty_app_t clair_ghostty_app_new(clair_ghostty_config_t config);
void clair_ghostty_app_free(clair_ghostty_app_t app);
void clair_ghostty_app_tick(clair_ghostty_app_t app);
clair_ghostty_surface_config_s clair_ghostty_surface_config_new(void);
clair_ghostty_surface_t clair_ghostty_surface_new(
    clair_ghostty_app_t app, const clair_ghostty_surface_config_s *config);
void clair_ghostty_surface_free(clair_ghostty_surface_t surface);
void clair_ghostty_surface_set_size(
    clair_ghostty_surface_t surface, uint32_t width_px, uint32_t height_px);
clair_ghostty_surface_size_s clair_ghostty_surface_size(clair_ghostty_surface_t surface);
bool clair_ghostty_surface_read_text(
    clair_ghostty_surface_t surface, clair_ghostty_selection_s selection,
    clair_ghostty_text_s *out_text);
void clair_ghostty_surface_free_text(
    clair_ghostty_surface_t surface, clair_ghostty_text_s *text);

#endif // CLAIR_GHOSTTY_VENDORED

// Returns 1 when compiled against the real vendored library (functions
// above are safe to call), 0 in "not linked" mode. Swift reads this instead
// of duplicating the `CLAIR_GHOSTTY_VENDORED` compile condition, so there is
// exactly one place that decides the answer.
int clair_ghostty_abi_is_vendored(void);

#ifdef __cplusplus
}
#endif

#endif // CLAIR_GHOSTTY_ABI_H
