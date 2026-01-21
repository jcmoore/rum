/*
 * rum_pglite_compat.c
 *
 * Compatibility layer for RUM extension when building for PGlite/Emscripten.
 *
 * The trace_sort symbol is declared as extern PGDLLIMPORT in rumsort.c but
 * is not exported by the PGlite WASM main module. We provide a local
 * definition here to satisfy the linker.
 */

#include "postgres.h"

#ifdef TRACE_SORT
/*
 * Provide a local definition of trace_sort when building for WASM.
 * This variable controls debug output for sorting operations.
 * We default it to false since we don't need sort tracing in WASM.
 */
bool trace_sort = false;
#endif
