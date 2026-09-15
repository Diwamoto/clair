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

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CLAIR_GHOSTTY_SUCCESS 0

// Opaque handle. Owned by the C library; Clair never dereferences it, only
// passes it back to the matching free function inside the same scope that
// allocated it.
typedef void *clair_ghostty_config_t;

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

#define clair_ghostty_init(argc, argv) ghostty_init((argc), (argv))
#define clair_ghostty_info() ghostty_info()
#define clair_ghostty_config_new() ghostty_config_new()
#define clair_ghostty_config_free(config) ghostty_config_free((config))

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
