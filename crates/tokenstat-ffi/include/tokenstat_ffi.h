/*
 * tokenstat C ABI.
 *
 * Hand maintained rather than generated: the surface is two functions and is
 * not expected to grow, because everything else travels as JSON inside them.
 * If this file and `src/abi.rs` ever disagree, `abi.rs` is correct.
 *
 * Licensed GPL-3.0. See LICENSE at the repository root.
 */

#ifndef TOKENSTAT_FFI_H
#define TOKENSTAT_FFI_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Invoke one bridge method.
 *
 * `method` is a bare name such as "info", "totals", "report", "blocks",
 * "scan", or "open". `params_json` is a JSON object, or NULL / "" for none.
 *
 * Returns a NUL-terminated UTF-8 JSON envelope, never NULL:
 *
 *     {"ok": true,  "result": ...}
 *     {"ok": false, "error": {"code": "...", "message": "..."}}
 *
 * The caller owns the result and must release it with
 * tokenstat_ffi_string_free. Calls are serialized internally and are safe from
 * any thread, but "scan" holds that lock for its whole duration, so do not
 * call it from a thread that is drawing.
 */
char *tokenstat_ffi_call(const char *method, const char *params_json);

/*
 * Release a string returned by tokenstat_ffi_call. NULL is accepted and
 * ignored. Passing any other pointer, or the same pointer twice, is undefined.
 */
void tokenstat_ffi_string_free(char *s);

#ifdef __cplusplus
}
#endif

#endif /* TOKENSTAT_FFI_H */
