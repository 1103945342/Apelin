// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OwnGoal Studio
//
// The substrate-compatible hooking interface Luros's tweak templates call.
// Written for Luros from the published function signatures; no header is
// copied from Cydia Substrate, ElleKit or any other implementation.
//
// At run time these symbols come from whatever the bootstrap installs as the
// `mobilesubstrate` virtual package (ElleKit on current rootless and roothide
// bootstraps). The link stubs beside this header, support/lib/<bootstrap>/
// libsubstrate.tbd, name the install path that package provides.
//
// Only the four functions below are the declared compatible set. A template
// that needs more adds them here and to both stubs in the same change.
#pragma once

#include <objc/runtime.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LUROS_SUBSTRATE_EXPORT extern __attribute__((visibility("default")))

/// An image handle returned by MSGetImageByName.
typedef const void *MSImageRef;

/// Replaces the instance method `message` on `_class` with `hook`. When `old`
/// is not NULL it receives the implementation that was in place, to call
/// from the hook. An inherited method is overridden on `_class` only.
LUROS_SUBSTRATE_EXPORT void MSHookMessageEx(Class _class, SEL message, IMP hook, IMP *old);

/// Redirects the function at `symbol` to `replace`. When `result` is not NULL
/// it receives a callable trampoline to the original function.
LUROS_SUBSTRATE_EXPORT void MSHookFunction(void *symbol, void *replace, void **result);

/// Returns the already-loaded image whose path is `file`, or NULL.
LUROS_SUBSTRATE_EXPORT MSImageRef MSGetImageByName(const char *file);

/// Returns the address of the symbol `name` (with its leading underscore) in
/// `image`, or in every loaded image when `image` is NULL; NULL when absent.
LUROS_SUBSTRATE_EXPORT void *MSFindSymbol(MSImageRef image, const char *name);

#undef LUROS_SUBSTRATE_EXPORT

#ifdef __cplusplus
}
#endif
