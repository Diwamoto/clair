#ifndef CLAIR_CORE_H
#define CLAIR_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Returns the stable bootstrap smoke value `0x434C4149` (`CLAI`).
uint32_t clair_core_smoke(void);

#ifdef __cplusplus
}
#endif

#endif  // CLAIR_CORE_H
