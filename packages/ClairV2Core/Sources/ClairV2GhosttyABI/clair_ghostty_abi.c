#include "include/clair_ghostty_abi.h"

int clair_ghostty_abi_is_vendored(void) {
#if defined(CLAIR_GHOSTTY_VENDORED)
  // Referencing the probe pointers here (rather than leaving them as
  // unused file-scope statics) both silences unused-variable warnings and
  // gives the ABI check one real use site: if any upstream symbol failed
  // to resolve to a non-null function pointer, this vendored build is not
  // actually usable and callers should not trust `clair_ghostty_abi_is_vendored`.
  return clair_ghostty_probe_init != 0 && clair_ghostty_probe_info != 0 &&
         clair_ghostty_probe_config_new != 0 &&
         clair_ghostty_probe_config_free != 0;
#else
  return 0;
#endif
}
