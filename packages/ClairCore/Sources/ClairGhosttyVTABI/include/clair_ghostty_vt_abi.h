#ifndef CLAIR_GHOSTTY_VT_ABI_H
#define CLAIR_GHOSTTY_VT_ABI_H

// Pinned C ABI subset for libghostty-vt (see Config/ghostty-pin.json's
// `libghostty_vt` block). This is a *different* upstream build artifact
// than `ClairGhosttyABI`'s `ghostty.h`/`GhosttyKit.xcframework`: T05
// (2026-09-18) confirmed upstream removed the full embedder/app target's
// iOS support before this pin was cut, but kept a separate "VT parsing
// only" library (`-Demit-lib-vt=true`, no GPU surface, no windowing) that
// still targets iOS. Clair uses it to parse the raw PTY byte stream
// `ClairTerminal`/`ClairTerminalStream` (T04) already provides and
// render the result with its own iOS `UIView` (`ClairTerminalView`),
// instead of linking libghostty's GPU embedder (which does not build for
// iOS at this pin and, even where it does build, has no API to read cell
// grid contents back out for a renderer Clair does not own -- T08's
// `ghostty_surface_read_text` subset is the closest it gets, and that
// stays macOS-only per that task's scope).
//
// Like `ClairGhosttyABI`: when `CLAIR_GHOSTTY_VT_VENDORED` is defined
// (set by Package.swift only when both the pinned commit's real
// `ghostty/vt.h` headers AND a built `GhosttyVT.xcframework` have been
// materialized into `packages/ClairCore/Vendor/ghostty/` by
// `scripts/ghostty.sh vendor-vt`), this header additionally includes
// the real upstream headers and statically asserts that this subset still
// matches them: struct layout via `_Static_assert(sizeof/offsetof, ...)`,
// enum values by direct comparison, and function presence/signature by
// assigning the real symbol to a function pointer of the exact expected
// type. When not defined, only the value types below are visible and no
// function symbol is declared, so nothing can accidentally link against a
// library that was never vendored.
//
// This subset intentionally does not mirror `screen.h`'s `GhosttyCell`/
// `GhosttyRow` packed-cell decode API: `ghostty_terminal_selection_format_
// alloc` (fed a `ghostty_terminal_select_all()` snapshot for "whole
// screen", or a caller-built two-endpoint selection for touch selection)
// already returns plain UTF-8 text, which is exactly the "array of visible
// line strings" shape `ClairTerminalView`'s CoreText renderer wants
// (same shape E06/E08's `EditorLineRenderer` consumes) -- reading and
// decoding the packed 64-bit cell format ourselves would duplicate work
// libghostty-vt already does correctly, for a benefit (per-cell color/
// attribute rendering) this task's minimal-UI scope does not need.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle. Owned by the C library; Clair never dereferences it, only
// passes it back to the matching free/consuming function.
typedef void *clair_ghostty_vt_terminal_t;

// Mirrors `GhosttyResult`. Negative values are error codes; only the
// subset this task's functions can actually return is used on the Swift
// side, but all values are mirrored so an upstream renumbering is caught
// by the enum-value static asserts below rather than silently
// misinterpreted.
typedef enum {
  CLAIR_GHOSTTY_VT_SUCCESS = 0,
  CLAIR_GHOSTTY_VT_OUT_OF_MEMORY = -1,
  CLAIR_GHOSTTY_VT_INVALID_VALUE = -2,
  CLAIR_GHOSTTY_VT_OUT_OF_SPACE = -3,
  CLAIR_GHOSTTY_VT_NO_VALUE = -4,
  CLAIR_GHOSTTY_VT_IO_ERROR = -5,
  CLAIR_GHOSTTY_VT_LIMIT_EXCEEDED = -6,
} clair_ghostty_vt_result_e;

// Mirrors `GhosttyPointTag`. Only ACTIVE/VIEWPORT are used today (touch
// selection resolves against the visible viewport); SCREEN/HISTORY are
// mirrored for completeness since they are part of the same upstream enum
// and this task's static asserts check the whole thing.
typedef enum {
  CLAIR_GHOSTTY_VT_POINT_TAG_ACTIVE = 0,
  CLAIR_GHOSTTY_VT_POINT_TAG_VIEWPORT = 1,
  CLAIR_GHOSTTY_VT_POINT_TAG_SCREEN = 2,
  CLAIR_GHOSTTY_VT_POINT_TAG_HISTORY = 3,
} clair_ghostty_vt_point_tag_e;

// Mirrors `GhosttyPointCoordinate`.
typedef struct {
  uint16_t x;
  uint32_t y;
} clair_ghostty_vt_point_coordinate_s;

// Mirrors `GhosttyPointValue`. The `_padding` member exists solely so this
// union has the same size as upstream's (which reserves room for a future
// non-coordinate variant); Clair never reads or writes it directly.
typedef union {
  clair_ghostty_vt_point_coordinate_s coordinate;
  uint64_t _padding[2];
} clair_ghostty_vt_point_value_u;

// Mirrors `GhosttyPoint`.
typedef struct {
  clair_ghostty_vt_point_tag_e tag;
  clair_ghostty_vt_point_value_u value;
} clair_ghostty_vt_point_s;

// Mirrors `GhosttyGridRef`. `node` is an opaque upstream-owned pointer;
// Clair only ever round-trips it (grid_ref -> selection -> format), never
// dereferences it directly. Untracked: only valid until the next mutating
// terminal call, exactly like `ghostty_surface_read_text`'s selection
// argument in the macOS ABI (`ClairGhosttyABI`'s `clair_ghostty_text_s`
// doc comment) -- same "read and use immediately" rule.
typedef struct {
  size_t size;
  void *node;
  uint16_t x;
  uint16_t y;
} clair_ghostty_vt_grid_ref_s;

// Mirrors `GhosttySelection`. `rectangle` is always false for the linear
// (non-block) touch selection this task implements.
typedef struct {
  size_t size;
  clair_ghostty_vt_grid_ref_s start;
  clair_ghostty_vt_grid_ref_s end;
  bool rectangle;
} clair_ghostty_vt_selection_s;

// Mirrors `GhosttyTerminalScrollViewportTag`.
typedef enum {
  CLAIR_GHOSTTY_VT_SCROLL_TOP = 0,
  CLAIR_GHOSTTY_VT_SCROLL_BOTTOM = 1,
  CLAIR_GHOSTTY_VT_SCROLL_DELTA = 2,
  CLAIR_GHOSTTY_VT_SCROLL_ROW = 3,
} clair_ghostty_vt_scroll_tag_e;

// Mirrors `GhosttyTerminalScrollViewportValue`.
typedef union {
  intptr_t delta;
  size_t row;
  uint64_t _padding[2];
} clair_ghostty_vt_scroll_value_u;

// Mirrors `GhosttyTerminalScrollViewport`.
typedef struct {
  clair_ghostty_vt_scroll_tag_e tag;
  clair_ghostty_vt_scroll_value_u value;
} clair_ghostty_vt_scroll_s;

#if defined(CLAIR_GHOSTTY_VT_VENDORED)

#include <ghostty/vt.h>

// --- Struct/enum layout invariants ----------------------------------------
_Static_assert(sizeof(clair_ghostty_vt_terminal_t) == sizeof(GhosttyTerminal),
               "GhosttyTerminal representation changed upstream");

_Static_assert((int)CLAIR_GHOSTTY_VT_SUCCESS == (int)GHOSTTY_SUCCESS, "GHOSTTY_SUCCESS changed upstream");
_Static_assert((int)CLAIR_GHOSTTY_VT_OUT_OF_MEMORY == (int)GHOSTTY_OUT_OF_MEMORY,
               "GHOSTTY_OUT_OF_MEMORY changed upstream");
_Static_assert((int)CLAIR_GHOSTTY_VT_INVALID_VALUE == (int)GHOSTTY_INVALID_VALUE,
               "GHOSTTY_INVALID_VALUE changed upstream");
_Static_assert((int)CLAIR_GHOSTTY_VT_OUT_OF_SPACE == (int)GHOSTTY_OUT_OF_SPACE,
               "GHOSTTY_OUT_OF_SPACE changed upstream");
_Static_assert((int)CLAIR_GHOSTTY_VT_NO_VALUE == (int)GHOSTTY_NO_VALUE, "GHOSTTY_NO_VALUE changed upstream");
_Static_assert((int)CLAIR_GHOSTTY_VT_IO_ERROR == (int)GHOSTTY_IO_ERROR, "GHOSTTY_IO_ERROR changed upstream");
_Static_assert((int)CLAIR_GHOSTTY_VT_LIMIT_EXCEEDED == (int)GHOSTTY_LIMIT_EXCEEDED,
               "GHOSTTY_LIMIT_EXCEEDED changed upstream");

_Static_assert((int)CLAIR_GHOSTTY_VT_POINT_TAG_ACTIVE == (int)GHOSTTY_POINT_TAG_ACTIVE,
               "GHOSTTY_POINT_TAG_ACTIVE changed upstream");
_Static_assert((int)CLAIR_GHOSTTY_VT_POINT_TAG_VIEWPORT == (int)GHOSTTY_POINT_TAG_VIEWPORT,
               "GHOSTTY_POINT_TAG_VIEWPORT changed upstream");
_Static_assert((int)CLAIR_GHOSTTY_VT_POINT_TAG_SCREEN == (int)GHOSTTY_POINT_TAG_SCREEN,
               "GHOSTTY_POINT_TAG_SCREEN changed upstream");
_Static_assert((int)CLAIR_GHOSTTY_VT_POINT_TAG_HISTORY == (int)GHOSTTY_POINT_TAG_HISTORY,
               "GHOSTTY_POINT_TAG_HISTORY changed upstream");

_Static_assert(sizeof(clair_ghostty_vt_point_coordinate_s) == sizeof(GhosttyPointCoordinate),
               "GhosttyPointCoordinate size changed upstream");
_Static_assert(offsetof(clair_ghostty_vt_point_coordinate_s, x) ==
                   offsetof(GhosttyPointCoordinate, x),
               "GhosttyPointCoordinate.x offset changed upstream");
_Static_assert(offsetof(clair_ghostty_vt_point_coordinate_s, y) ==
                   offsetof(GhosttyPointCoordinate, y),
               "GhosttyPointCoordinate.y offset changed upstream");

_Static_assert(sizeof(clair_ghostty_vt_point_value_u) == sizeof(GhosttyPointValue),
               "GhosttyPointValue size changed upstream");
_Static_assert(sizeof(clair_ghostty_vt_point_s) == sizeof(GhosttyPoint),
               "GhosttyPoint size changed upstream");
_Static_assert(offsetof(clair_ghostty_vt_point_s, tag) == offsetof(GhosttyPoint, tag),
               "GhosttyPoint.tag offset changed upstream");
_Static_assert(offsetof(clair_ghostty_vt_point_s, value) == offsetof(GhosttyPoint, value),
               "GhosttyPoint.value offset changed upstream");

_Static_assert(sizeof(clair_ghostty_vt_grid_ref_s) == sizeof(GhosttyGridRef),
               "GhosttyGridRef size changed upstream");
_Static_assert(offsetof(clair_ghostty_vt_grid_ref_s, size) == offsetof(GhosttyGridRef, size),
               "GhosttyGridRef.size offset changed upstream");
_Static_assert(offsetof(clair_ghostty_vt_grid_ref_s, node) == offsetof(GhosttyGridRef, node),
               "GhosttyGridRef.node offset changed upstream");
_Static_assert(offsetof(clair_ghostty_vt_grid_ref_s, x) == offsetof(GhosttyGridRef, x),
               "GhosttyGridRef.x offset changed upstream");
_Static_assert(offsetof(clair_ghostty_vt_grid_ref_s, y) == offsetof(GhosttyGridRef, y),
               "GhosttyGridRef.y offset changed upstream");

_Static_assert(sizeof(clair_ghostty_vt_selection_s) == sizeof(GhosttySelection),
               "GhosttySelection size changed upstream");
_Static_assert(offsetof(clair_ghostty_vt_selection_s, size) == offsetof(GhosttySelection, size),
               "GhosttySelection.size offset changed upstream");
_Static_assert(offsetof(clair_ghostty_vt_selection_s, start) == offsetof(GhosttySelection, start),
               "GhosttySelection.start offset changed upstream");
_Static_assert(offsetof(clair_ghostty_vt_selection_s, end) == offsetof(GhosttySelection, end),
               "GhosttySelection.end offset changed upstream");
_Static_assert(offsetof(clair_ghostty_vt_selection_s, rectangle) ==
                   offsetof(GhosttySelection, rectangle),
               "GhosttySelection.rectangle offset changed upstream");

_Static_assert((int)CLAIR_GHOSTTY_VT_SCROLL_TOP == (int)GHOSTTY_SCROLL_VIEWPORT_TOP,
               "GHOSTTY_SCROLL_VIEWPORT_TOP changed upstream");
_Static_assert((int)CLAIR_GHOSTTY_VT_SCROLL_BOTTOM == (int)GHOSTTY_SCROLL_VIEWPORT_BOTTOM,
               "GHOSTTY_SCROLL_VIEWPORT_BOTTOM changed upstream");
_Static_assert((int)CLAIR_GHOSTTY_VT_SCROLL_DELTA == (int)GHOSTTY_SCROLL_VIEWPORT_DELTA,
               "GHOSTTY_SCROLL_VIEWPORT_DELTA changed upstream");
_Static_assert((int)CLAIR_GHOSTTY_VT_SCROLL_ROW == (int)GHOSTTY_SCROLL_VIEWPORT_ROW,
               "GHOSTTY_SCROLL_VIEWPORT_ROW changed upstream");
_Static_assert(sizeof(clair_ghostty_vt_scroll_value_u) == sizeof(GhosttyTerminalScrollViewportValue),
               "GhosttyTerminalScrollViewportValue size changed upstream");
_Static_assert(sizeof(clair_ghostty_vt_scroll_s) == sizeof(GhosttyTerminalScrollViewport),
               "GhosttyTerminalScrollViewport size changed upstream");
_Static_assert(offsetof(clair_ghostty_vt_scroll_s, tag) ==
                   offsetof(GhosttyTerminalScrollViewport, tag),
               "GhosttyTerminalScrollViewport.tag offset changed upstream");
_Static_assert(offsetof(clair_ghostty_vt_scroll_s, value) ==
                   offsetof(GhosttyTerminalScrollViewport, value),
               "GhosttyTerminalScrollViewport.value offset changed upstream");

// The specific `GhosttyTerminalData`/`GhosttyFormatterFormat` enumerators
// this subset reads, checked by value (not mirrored as a full enum type):
// `ghostty_terminal_get`'s `data` argument and
// `GhosttyTerminalSelectionFormatOptions.emit` are passed as plain `int`s
// by `clair_ghostty_vt_abi.c`, which is compiled against the real header
// and can reference the real enumerators by name directly -- only their
// numeric values need to stay stable for this header's callers, who never
// see the enum type itself.
_Static_assert(GHOSTTY_TERMINAL_DATA_CURSOR_X == 3, "GHOSTTY_TERMINAL_DATA_CURSOR_X changed upstream");
_Static_assert(GHOSTTY_TERMINAL_DATA_CURSOR_Y == 4, "GHOSTTY_TERMINAL_DATA_CURSOR_Y changed upstream");
_Static_assert(GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE == 7,
               "GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE changed upstream");
_Static_assert(GHOSTTY_TERMINAL_DATA_TOTAL_ROWS == 14,
               "GHOSTTY_TERMINAL_DATA_TOTAL_ROWS changed upstream");
_Static_assert(GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS == 15,
               "GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS changed upstream");
_Static_assert(GHOSTTY_FORMATTER_FORMAT_PLAIN == 0, "GHOSTTY_FORMATTER_FORMAT_PLAIN changed upstream");

// --- Function presence/signature invariants -------------------------------
// Same reasoning as `ClairGhosttyABI`: assigning the real upstream symbol
// to a function pointer of the exact expected type fails to compile (not
// link, not run) if upstream removes, renames, or changes the signature of
// a function this subset depends on.
static GhosttyResult (*const clair_ghostty_vt_probe_terminal_new)(
    const GhosttyAllocator *, GhosttyTerminal *, uint16_t, uint16_t) = ghostty_terminal_new;
static void (*const clair_ghostty_vt_probe_terminal_free)(GhosttyTerminal) = ghostty_terminal_free;
static GhosttyResult (*const clair_ghostty_vt_probe_terminal_resize)(
    GhosttyTerminal, uint16_t, uint16_t, uint32_t, uint32_t) = ghostty_terminal_resize;
static void (*const clair_ghostty_vt_probe_terminal_vt_write)(
    GhosttyTerminal, const uint8_t *, size_t) = ghostty_terminal_vt_write;
static GhosttyResult (*const clair_ghostty_vt_probe_terminal_get)(
    GhosttyTerminal, GhosttyTerminalData, void *) = ghostty_terminal_get;
static GhosttyResult (*const clair_ghostty_vt_probe_terminal_grid_ref)(
    GhosttyTerminal, GhosttyPoint, GhosttyGridRef *) = ghostty_terminal_grid_ref;
static GhosttyResult (*const clair_ghostty_vt_probe_terminal_select_all)(
    GhosttyTerminal, GhosttySelection *) = ghostty_terminal_select_all;
static GhosttyResult (*const clair_ghostty_vt_probe_terminal_selection_format_alloc)(
    GhosttyTerminal, const GhosttyAllocator *, GhosttyTerminalSelectionFormatOptions, uint8_t **,
    size_t *) = ghostty_terminal_selection_format_alloc;
static void (*const clair_ghostty_vt_probe_terminal_scroll_viewport)(
    GhosttyTerminal, GhosttyTerminalScrollViewport) = ghostty_terminal_scroll_viewport;
static void (*const clair_ghostty_vt_probe_free)(const GhosttyAllocator *, uint8_t *, size_t) =
    ghostty_free;

// Real functions (defined in clair_ghostty_vt_abi.c), not macros -- Swift's
// Clang importer does not import function-like macros that expand to a call
// expression (`ClairGhosttyABI`'s header comment explains the same
// constraint in more detail; T01 hit it, T08 fixed it there).
clair_ghostty_vt_result_e clair_ghostty_vt_terminal_new(
    clair_ghostty_vt_terminal_t *out_terminal, uint16_t cols, uint16_t rows);
void clair_ghostty_vt_terminal_free(clair_ghostty_vt_terminal_t terminal);
clair_ghostty_vt_result_e clair_ghostty_vt_terminal_resize(
    clair_ghostty_vt_terminal_t terminal, uint16_t cols, uint16_t rows, uint32_t cell_width_px,
    uint32_t cell_height_px);
void clair_ghostty_vt_terminal_write(
    clair_ghostty_vt_terminal_t terminal, const uint8_t *data, size_t len);
clair_ghostty_vt_result_e clair_ghostty_vt_cursor_x(
    clair_ghostty_vt_terminal_t terminal, uint16_t *out);
clair_ghostty_vt_result_e clair_ghostty_vt_cursor_y(
    clair_ghostty_vt_terminal_t terminal, uint16_t *out);
clair_ghostty_vt_result_e clair_ghostty_vt_cursor_visible(
    clair_ghostty_vt_terminal_t terminal, bool *out);
clair_ghostty_vt_result_e clair_ghostty_vt_total_rows(
    clair_ghostty_vt_terminal_t terminal, size_t *out);
clair_ghostty_vt_result_e clair_ghostty_vt_scrollback_rows(
    clair_ghostty_vt_terminal_t terminal, size_t *out);
clair_ghostty_vt_result_e clair_ghostty_vt_grid_ref(
    clair_ghostty_vt_terminal_t terminal, clair_ghostty_vt_point_s point,
    clair_ghostty_vt_grid_ref_s *out_ref);
clair_ghostty_vt_result_e clair_ghostty_vt_select_all(
    clair_ghostty_vt_terminal_t terminal, clair_ghostty_vt_selection_s *out_selection);
// Formats `selection` (whole-screen when built from
// `clair_ghostty_vt_select_all`, or an explicit two-endpoint range for
// touch selection/copy) as plain UTF-8 text. The caller must free
// `*out_ptr` with `clair_ghostty_vt_free` exactly once when `*out_len > 0`.
clair_ghostty_vt_result_e clair_ghostty_vt_format_selection_alloc(
    clair_ghostty_vt_terminal_t terminal, const clair_ghostty_vt_selection_s *selection,
    bool unwrap, bool trim, uint8_t **out_ptr, size_t *out_len);
void clair_ghostty_vt_free(uint8_t *ptr, size_t len);
void clair_ghostty_vt_scroll_viewport(
    clair_ghostty_vt_terminal_t terminal, clair_ghostty_vt_scroll_s behavior);

#endif  // CLAIR_GHOSTTY_VT_VENDORED

// Returns 1 when compiled against the real vendored library (functions
// above are safe to call), 0 in "not linked" mode. Mirrors
// `clair_ghostty_abi_is_vendored` (`ClairGhosttyABI`) exactly.
int clair_ghostty_vt_abi_is_vendored(void);

#ifdef __cplusplus
}
#endif

#endif  // CLAIR_GHOSTTY_VT_ABI_H
