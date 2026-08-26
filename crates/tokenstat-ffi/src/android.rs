// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted.

//! Android's deliberately tiny JNI face.

use jni::EnvUnowned;
use jni::errors::{Error, ThrowRuntimeExAndDefault};
use jni::objects::{JClass, JString};
use jni::sys::jstring;

use crate::api;

fn response(env: &mut jni::Env<'_>, value: impl AsRef<str>) -> Result<jstring, Error> {
    Ok(env.new_string(value.as_ref())?.into_raw())
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_ai_tokenstat_tokenstat_core_NativeBridge_nativeInit<'caller>(
    mut unowned_env: EnvUnowned<'caller>,
    _class: JClass<'caller>,
    data_dir: JString<'caller>,
    cache_dir: JString<'caller>,
    device_name: JString<'caller>,
) -> jstring {
    unowned_env
        .with_env(|env| {
            let result = (|| {
                tokenstat_paths::configure_mobile(data_dir.to_string(), cache_dir.to_string())?;
                tokenstat_identity::set_machine_label(&device_name.to_string())
                    .map_err(|e| e.to_string())?;
                Ok::<_, String>(serde_json::json!({"ok": true, "result": {}}).to_string())
            })()
            .unwrap_or_else(|message| {
                serde_json::json!({
                    "ok": false,
                    "error": {"code": "android_init", "message": message}
                })
                .to_string()
            });
            response(env, result)
        })
        .resolve::<ThrowRuntimeExAndDefault>()
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_ai_tokenstat_tokenstat_core_NativeBridge_nativeCall<'caller>(
    mut unowned_env: EnvUnowned<'caller>,
    _class: JClass<'caller>,
    method: JString<'caller>,
    params: JString<'caller>,
) -> jstring {
    unowned_env
        .with_env(|env| {
            let result = api::call(&method.to_string(), &params.to_string());
            response(env, result)
        })
        .resolve::<ThrowRuntimeExAndDefault>()
}
