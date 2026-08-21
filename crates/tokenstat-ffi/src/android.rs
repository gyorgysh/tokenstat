// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted.

//! Android's deliberately tiny JNI face.

use jni::JNIEnv;
use jni::objects::{JClass, JString};
use jni::sys::jstring;

use crate::api;

fn java_string(env: &mut JNIEnv<'_>, value: JString<'_>) -> Result<String, String> {
    env.get_string(&value)
        .map(|s| s.into())
        .map_err(|e| e.to_string())
}

fn response(env: &JNIEnv<'_>, value: impl AsRef<str>) -> jstring {
    env.new_string(value.as_ref())
        .map(|s| s.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_ai_tokenstat_tokenstat_core_NativeBridge_nativeInit(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    data_dir: JString<'_>,
    cache_dir: JString<'_>,
    device_name: JString<'_>,
) -> jstring {
    let result = (|| {
        let data = java_string(&mut env, data_dir)?;
        let cache = java_string(&mut env, cache_dir)?;
        let name = java_string(&mut env, device_name)?;
        tokenstat_paths::configure_mobile(data, cache)?;
        tokenstat_identity::set_machine_label(&name).map_err(|e| e.to_string())?;
        Ok::<_, String>(serde_json::json!({"ok": true, "result": {}}).to_string())
    })()
    .unwrap_or_else(|message| {
        serde_json::json!({
            "ok": false,
            "error": {"code": "android_init", "message": message}
        })
        .to_string()
    });
    response(&env, result)
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_ai_tokenstat_tokenstat_core_NativeBridge_nativeCall(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    method: JString<'_>,
    params: JString<'_>,
) -> jstring {
    let result = match (java_string(&mut env, method), java_string(&mut env, params)) {
        (Ok(method), Ok(params)) => api::call(&method, &params),
        (Err(message), _) | (_, Err(message)) => serde_json::json!({
            "ok": false,
            "error": {"code": "jni_string", "message": message}
        })
        .to_string(),
    };
    response(&env, result)
}
