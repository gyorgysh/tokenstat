// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Muse and both OpenCode launchers use native credentials in an otherwise
//! empty home. Only connection/model metadata crosses from native settings.
//! OpenCode V2 keeps its own credential database and OAuth refresh lifecycle;
//! every invocation creates a new session with only the Team MCP available.

use super::{Path, PathBuf, Program, RunHome, fs, io, json, write_new};
use crate::opencode_cli::Generation;
use serde_json::{Map, Value};
use std::io::Read;

const CONFIG_BYTES: usize = 512 * 1024;
const AUTH_ENV: &[&str] = &[
    "META_API_KEY",
    "MUSE_API_KEY",
    "MUSE_MODEL",
    "MUSE_CUSTOM_HEADERS",
    "TBH_CREDENTIAL_BACKEND",
    "TBH_AUTH_BASE_URL",
    "OPENCODE_API_KEY",
    "OPENAI_API_KEY",
    "OPENAI_BASE_URL",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_BASE_URL",
    "GOOGLE_GENERATIVE_AI_API_KEY",
    "GEMINI_API_KEY",
    "XAI_API_KEY",
    "GROQ_API_KEY",
    "OPENROUTER_API_KEY",
    "OPENROUTER_BASE_URL",
    "DEEPSEEK_API_KEY",
    "MISTRAL_API_KEY",
    "TOGETHER_API_KEY",
    "PERPLEXITY_API_KEY",
    "CEREBRAS_API_KEY",
    "AZURE_API_KEY",
    "AZURE_RESOURCE_NAME",
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
    "AWS_REGION",
    "AWS_DEFAULT_REGION",
    "GOOGLE_APPLICATION_CREDENTIALS",
    "GOOGLE_CLOUD_PROJECT",
    "GOOGLE_CLOUD_LOCATION",
    "DBUS_SESSION_BUS_ADDRESS",
    "XDG_RUNTIME_DIR",
];

pub(super) fn probe_args(backend: &str) -> Vec<String> {
    vec![
        if backend == "muse" { "exec" } else { "run" }.into(),
        "--help".into(),
    ]
}

pub(super) fn validate_help(backend: &str, text: &str) -> bool {
    let flags: &[&str] = match backend {
        "muse" => &[
            "--prompt-file",
            "--preset",
            "--no-session-log",
            "--no-foreign-personal-context",
            "--disable-shell",
            "--disable-write",
            "--disable-web-tools",
            "--disable-reminders",
            "--disable-request-user-input",
            "--approval-mode",
            "--approval-judge",
            "--config",
        ],
        "opencode" | "opencode2" => &["--format", "--model"],
        _ => return false,
    };
    flags.iter().all(|flag| text.contains(flag))
}

pub(super) fn version_supported(backend: &str, executable: &str) -> bool {
    match crate::opencode_cli::require_generation(backend) {
        Ok(Generation::V1) => true,
        Ok(Generation::V2) => {
            let Ok((probe, args)) = super::invocation(executable, &["--version".into()]) else {
                return false;
            };
            let Some(probe) = probe.to_str() else {
                return false;
            };
            let args = args.iter().map(String::as_str).collect::<Vec<_>>();
            crate::agent_models::run_cli_probe(
                probe,
                &args,
                std::time::Duration::from_secs(3),
                4096,
                None,
                &[],
            )
            .filter(|reply| reply.success)
            .is_some_and(|reply| tested_v2_version(&reply.stdout))
        }
        Err(_) => false,
    }
}

// This is the oldest release exercised against the Team plugin/config APIs,
// rather than a claim about when each individual native feature appeared.
fn tested_v2_version(text: &str) -> bool {
    text.split_whitespace()
        .find_map(|word| {
            let word = word.trim_start_matches('v');
            if word.contains('-') {
                return None;
            }
            let parts = word
                .split('+')
                .next()?
                .split('.')
                .map(str::parse::<u32>)
                .collect::<Result<Vec<_>, _>>()
                .ok()?;
            (parts.len() == 3).then(|| (parts[0], parts[1], parts[2]) >= (2, 0, 32))
        })
        .unwrap_or(false)
}

pub(super) fn prepare(
    home: &RunHome,
    program: &mut Program,
    helper: &Path,
    backend: &str,
    native_folder: &Path,
) -> io::Result<()> {
    let generation = if backend == "muse" {
        None
    } else {
        Some(crate::opencode_cli::require_generation(backend).map_err(io::Error::other)?)
    };
    prepare_native(
        home,
        program,
        helper,
        backend,
        generation,
        &super::native_home()?,
        &super::native_env,
        native_folder,
    )
}

fn native_path(value: Option<String>, default: PathBuf, folder: &Path) -> PathBuf {
    let path = value
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or(default);
    if path.is_absolute() {
        path
    } else {
        folder.join(path)
    }
}

fn route(source: &Path, target: &Path) -> io::Result<()> {
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent)?;
    }
    crate::chat_gate::route_team_cli_credential(source, target).map_err(io::Error::other)
}

fn route_muse_credential(source: &Path, target: &Path) -> io::Result<()> {
    // Muse resolves symbolic links before atomically replacing the native
    // target. A hard link would lose that refresh on private-home teardown.
    #[cfg(windows)]
    {
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }
        if source.try_exists()? {
            std::os::windows::fs::symlink_file(source,target).map_err(|_|io::Error::other("The native Muse sign-in needs a symbolic link for this isolated Team run. Enable symbolic links on this computer or use its native API-key sign-in."))?;
        }
        Ok(())
    }
    #[cfg(not(windows))]
    {
        route(source, target)
    }
}

#[allow(clippy::too_many_arguments)]
fn prepare_native(
    home: &RunHome,
    program: &mut Program,
    helper: &Path,
    backend: &str,
    generation: Option<Generation>,
    native_home: &Path,
    env: &dyn Fn(&str) -> Option<String>,
    native_folder: &Path,
) -> io::Result<()> {
    for key in AUTH_ENV {
        if let Some(value) = env(key) {
            program.env.insert((*key).into(), value);
        }
    }
    if let Some(path) = env("GOOGLE_APPLICATION_CREDENTIALS").filter(|path| !path.is_empty()) {
        program.env.insert(
            "GOOGLE_APPLICATION_CREDENTIALS".into(),
            native_path(Some(path), PathBuf::new(), native_folder)
                .display()
                .to_string(),
        );
    }
    let config_home = native_path(
        env("XDG_CONFIG_HOME"),
        native_home.join(".config"),
        native_folder,
    );
    if backend == "muse" {
        let directory = home.file("config/muse");
        fs::create_dir_all(&directory)?;
        route_muse_credential(
            &config_home.join("muse/auth.json"),
            &directory.join("auth.json"),
        )?;
        // MUSE_AUTH_PATH belongs to Muse's shell downloader, not the native
        // model credential store. A custom downloader account must not
        // replace the native file/keychain account selected by Muse itself.
        if let Some(selector) = env("MUSE_AUTH_PATH").filter(|value| !value.is_empty()) {
            let source = native_path(Some(selector), PathBuf::new(), native_folder);
            let target = home.file("muse-launcher-auth.json");
            route_muse_credential(&source, &target)?;
            program
                .env
                .insert("MUSE_AUTH_PATH".into(), target.display().to_string());
        }
        program.env.insert("MUSE_NO_AUTO_UPDATE".into(), "1".into());
        let source = read_json(&config_home.join("muse/settings.json"))?;
        if source
            .as_ref()
            .is_some_and(|source| source.get("schema_version") != Some(&json!(1)))
        {
            return Err(unsupported());
        }
        let source = source.unwrap_or_else(|| json!({}));
        let mut settings = Map::from_iter([("schema_version".into(), json!(1))]);
        for key in [
            "provider",
            "model",
            "reasoning_effort",
            "model_reasoning_efforts",
        ] {
            if let Some(value) = source.get(key) {
                settings.insert(key.into(), value.clone());
            }
        }
        if let Some(transport) = source.get("endpoint_transport") {
            settings.insert(
                "endpoint_transport".into(),
                pick(
                    transport,
                    &[
                        "base_url",
                        "auth",
                        "proxy",
                        "client_cert",
                        "client_key",
                        "ca_bundle",
                        "http_headers",
                        "env_http_headers",
                        "allow_openai",
                    ],
                )?,
            );
        }
        let mut settings = Value::Object(settings);
        // The native Rust HTTP client opens these paths from its working
        // directory. Preserve that source before moving to the private cwd.
        if let Some(transport) = settings
            .get_mut("endpoint_transport")
            .and_then(Value::as_object_mut)
        {
            for key in ["client_cert", "client_key", "ca_bundle"] {
                if let Some(value) = transport.get_mut(key).filter(|value| !value.is_null()) {
                    let path = value.as_str().ok_or_else(unsupported)?;
                    if path.contains("{env:") || path.contains("${") {
                        return Err(unsupported());
                    }
                    if !path.is_empty() {
                        *value = native_path(Some(path.into()), PathBuf::new(), native_folder)
                            .display()
                            .to_string()
                            .into();
                    }
                }
            }
        }
        import_references(&mut settings, program, env)?;
        if let Some(headers) = settings
            .pointer_mut("/endpoint_transport/env_http_headers")
            .and_then(Value::as_object_mut)
        {
            for name in headers.values_mut() {
                *name = alias(name.as_str().ok_or_else(unsupported)?, program, env)?.into();
            }
        }
        program
            .env
            .insert("TOKENSTAT_TEAM_MCP_EMPTY".into(), String::new());
        write_new(
            &directory.join("settings.json"),
            settings.to_string().as_bytes(),
        )?;
        return Ok(());
    }
    let generation = generation.ok_or_else(unsupported)?;
    refuse_managed_config(env)?;
    let data_home = native_path(
        env("XDG_DATA_HOME"),
        native_home.join(".local/share"),
        native_folder,
    );
    let data = PathBuf::from(&home.env["XDG_DATA_HOME"]).join("opencode");
    if generation == Generation::V1 {
        route(
            &data_home.join("opencode/auth.json"),
            &data.join("auth.json"),
        )?;
    }
    let directory = home.file("config/opencode");
    fs::create_dir_all(&directory)?;
    let source_directory = native_path(
        env("OPENCODE_CONFIG_DIR"),
        config_home.join("opencode"),
        native_folder,
    );
    let mut config = json!({});
    for path in [
        source_directory.join("opencode.json"),
        source_directory.join("opencode.jsonc"),
    ] {
        if let Some(value) = read_json(&path)? {
            merge_connection(&mut config, &value, generation)?;
        }
    }
    if let Some(path) = env("OPENCODE_CONFIG").filter(|value| !value.is_empty()) {
        let path = native_path(Some(path), PathBuf::new(), native_folder);
        let value = read_json(&path)?
            .ok_or_else(|| io::Error::other("The native OpenCode configuration is unavailable."))?;
        merge_connection(&mut config, &value, generation)?;
    }
    if let Some(text) = env("OPENCODE_CONFIG_CONTENT").filter(|value| !value.is_empty()) {
        merge_connection(&mut config, &parse_json(&text)?, generation)?;
    }
    import_references(&mut config, program, env)?;
    if generation == Generation::V2 {
        prepare_native_database(program, &data_home.join("opencode"), env)?;
    }
    let plugin = home.file("opencode-team-plugin");
    fs::create_dir_all(&plugin)?;
    let tools = crate::team_sdk::registered_tool_names()
        .into_iter()
        .map(|tool| format!("{}_{tool}", super::SERVER))
        .collect::<Vec<_>>();
    let code = (if generation == Generation::V2 {
        PLUGIN_V2
    } else {
        PLUGIN_V1
    })
    .replace("__TEAM_TOOLS__", &json!(tools).to_string());
    write_new(&plugin.join("index.js"), code.as_bytes())?;
    write_new(
        &plugin.join("package.json"),
        br#"{"name":"tokenstat-team-gate","type":"module","main":"index.js"}"#,
    )?;
    let mut server = super::mcp_server(helper);
    let object = server.as_object_mut().expect("MCP server");
    let args = object.remove("args").expect("MCP arguments");
    object.insert("command".into(), json!([helper, args[0]]));
    object.insert("type".into(), "local".into());
    // OpenCode inherits the environment before applying these overrides.
    let mut environment = object.remove("env").expect("MCP env");
    for key in program.env.keys().filter(|key| {
        !super::SDK_VARS.contains(&key.as_str())
            && ![
                "PATH",
                "HOME",
                "USERPROFILE",
                "XDG_CONFIG_HOME",
                "XDG_DATA_HOME",
                "XDG_CACHE_HOME",
                "TMPDIR",
                "TEMP",
                "TMP",
            ]
            .contains(&key.as_str())
    }) {
        environment
            .as_object_mut()
            .expect("MCP env")
            .insert(key.clone(), "".into());
    }
    for key in AUTH_ENV.iter().copied().chain([
        "OPENCODE_CONFIG_CONTENT",
        "OPENCODE_CONFIG",
        "OPENCODE_CLI_CONFIG_CONTENT",
    ]) {
        environment
            .as_object_mut()
            .expect("MCP env")
            .insert(key.into(), "".into());
    }
    for key in super::SDK_VARS {
        environment
            .as_object_mut()
            .expect("MCP env")
            .insert(key.into(), format!("{{env:{key}}}").into());
    }
    object.insert("environment".into(), environment);
    if generation == Generation::V2 {
        object.insert("codemode".into(), false.into());
        config["mcp"] = json!({"servers":{super::SERVER:server}});
        config["plugins"] = json!([plugin]);
        let mut permissions = vec![json!({"action":"*","resource":"*","effect":"deny"})];
        permissions.extend(
            tools
                .iter()
                .map(|tool| json!({"action":tool,"resource":"*","effect":"allow"})),
        );
        config["permissions"] = permissions.into();
    } else {
        config["mcp"] = json!({super::SERVER:server});
        config["plugin"] = json!([plugin.join("index.js")]);
        let mut permission = Map::from_iter([("*".into(), json!("deny"))]);
        for tool in &tools {
            permission.insert(tool.clone(), "allow".into());
        }
        config["permission"] = permission.into();
    }
    program.env.insert(
        "TOKENSTAT_TEAM_OPENCODE_GENERATION".into(),
        if generation == Generation::V2 {
            "2"
        } else {
            "1"
        }
        .into(),
    );
    program.env.insert(
        "OPENCODE_CONFIG_DIR".into(),
        directory.display().to_string(),
    );
    // Keep bounded connection metadata (which may contain a native API key)
    // in the private 0600 config rather than a large process environment.
    let config_path = home.file("opencode.json");
    write_new(&config_path, config.to_string().as_bytes())?;
    program
        .env
        .insert("OPENCODE_CONFIG".into(), config_path.display().to_string());
    for key in [
        "OPENCODE_CONFIG_PROJECT_DISABLE",
        "OPENCODE_DISABLE_PROJECT_CONFIG",
        "OPENCODE_DISABLE_CLAUDE_CODE",
        "OPENCODE_DISABLE_CLAUDE_CODE_SKILLS",
        "OPENCODE_DISABLE_MODELS_FETCH",
        "OPENCODE_DISABLE_AUTOUPDATE",
        "OPENCODE_DISABLE_FILEWATCHER",
    ] {
        program.env.insert(key.into(), "1".into());
    }
    program.env.insert(
        "XDG_STATE_HOME".into(),
        home.file("state").display().to_string(),
    );
    Ok(())
}

pub(super) fn command(
    _home: &RunHome,
    program: &mut Program,
    helper: &Path,
    backend: &str,
    prompt: &str,
) -> io::Result<Vec<String>> {
    if matches!(backend, "opencode" | "opencode2") {
        refuse_managed_config(&super::native_env)?;
    }
    if let Some(path) = program.env.get("TOKENSTAT_TEAM_OPENCODE_NATIVE_DB") {
        ensure_native_database(Path::new(path))?;
    }
    let mut argv = crate::automations::chat_agent_command_in(
        backend,
        prompt,
        None,
        None,
        0,
        crate::automations::ChatLaunch {
            resume: None,
            bypass: false,
            mode: "execute",
            hook_helper: Some(helper),
            system_append: None,
            agy_customization_dir: None,
            cursor_plugin_dir: None,
            grok_allow_rules: &[],
            attachments: &[],
        },
        Some(&program.folder),
    )
    .map_err(io::Error::other)?;
    let marker = argv
        .iter()
        .rposition(|arg| arg == "--")
        .ok_or_else(|| io::Error::other("Missing guarded CLI prompt."))?;
    if marker + 2 != argv.len() {
        return Err(io::Error::other("Invalid guarded CLI prompt."));
    }
    let prompt = argv.pop().expect("prompt after marker");
    argv.pop();
    // A fixed full user turn, passed via a file/stdin, cannot become argv flags
    // or exceed Windows' argv limit during conflict repair.
    write_new(&program.input, prompt.as_bytes())?;
    if backend == "muse" {
        let mut env = super::SDK_VARS
            .iter()
            .map(|key| ((*key).to_owned(), json!(format!("${{{key}}}"))))
            .collect::<Map<_, _>>();
        for key in super::INFERENCE_ENV
            .iter()
            .copied()
            .chain(AUTH_ENV.iter().copied())
            .chain(
                program
                    .env
                    .keys()
                    .filter(|key| key.starts_with("TOKENSTAT_TEAM_PROVIDER_ENV_"))
                    .map(String::as_str),
            )
        {
            env.insert(key.into(), "${TOKENSTAT_TEAM_MCP_EMPTY}".into());
        }
        let mcp = json!({"command":helper,"args":["team-run-sdk"],"env":env,"mode":"required"});
        argv.extend([
            "--prompt-file".into(),
            program.input.display().to_string(),
            "--preset".into(),
            "empty".into(),
            "--no-session-log".into(),
            "--no-foreign-personal-context".into(),
            "--disable-shell".into(),
            "--disable-write".into(),
            "--disable-web-tools".into(),
            "--disable-reminders".into(),
            "--disable-request-user-input".into(),
            "--approval-mode".into(),
            "never".into(),
            "--approval-judge".into(),
            "off".into(),
            "-c".into(),
            "run.toolset=[]".into(),
            "-c".into(),
            format!("mcpServers.{}={mcp}", super::SERVER),
        ]);
    }
    if let Some(generation) = program.env.get("TOKENSTAT_TEAM_OPENCODE_GENERATION") {
        // Keep the generation whose config and plugin were prepared, also
        // while the native launcher is being upgraded between repair turns.
        argv.retain(|arg| arg != "--standalone");
        if generation == "2" {
            argv.push("--standalone".into());
        }
    }
    Ok(argv)
}

fn read_json(path: &Path) -> io::Result<Option<Value>> {
    let mut options = fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NONBLOCK);
    }
    let mut file = match options.open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    if !file.metadata()?.is_file() {
        return Err(unsupported());
    }
    let mut bytes = Vec::new();
    (&mut file)
        .take((CONFIG_BYTES + 1) as u64)
        .read_to_end(&mut bytes)?;
    if bytes.len() > CONFIG_BYTES {
        return Err(unsupported());
    }
    let text = std::str::from_utf8(&bytes).map_err(|_| unsupported())?;
    parse_json(text).map(Some)
}

fn parse_json(text: &str) -> io::Result<Value> {
    if text.len() > CONFIG_BYTES {
        return Err(unsupported());
    }
    let value: Value = serde_json::from_str(&crate::harness_config::strip_trailing_commas(
        &crate::harness_config::strip_jsonc(text),
    ))
    .map_err(|_| unsupported())?;
    if !value.is_object() {
        return Err(unsupported());
    }
    Ok(value)
}

fn pick(source: &Value, keys: &[&str]) -> io::Result<Value> {
    let source = source.as_object().ok_or_else(unsupported)?;
    Ok(Value::Object(
        source
            .iter()
            .filter(|(key, _)| keys.contains(&key.as_str()))
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect(),
    ))
}

fn merge_connection(target: &mut Value, source: &Value, generation: Generation) -> io::Result<()> {
    for key in ["model", "small_model"] {
        if let Some(value) = source.get(key) {
            if !value.is_string() {
                return Err(unsupported());
            }
            target[key] = value.clone();
        }
    }
    let providers = if generation == Generation::V2 {
        "providers"
    } else {
        "provider"
    };
    if let Some(entries) = source.get(providers) {
        let entries = entries
            .as_object()
            .filter(|entries| entries.len() <= 64)
            .ok_or_else(unsupported)?;
        for (id, entry) in entries {
            if id.len() > 128 {
                return Err(unsupported());
            }
            let mut safe = pick(
                entry,
                &[
                    "name",
                    "env",
                    "package",
                    "npm",
                    "canonical",
                    "settings",
                    "options",
                    "headers",
                    "models",
                ],
            )?;
            let package = if generation == Generation::V2 {
                "package"
            } else {
                "npm"
            };
            if let Some(value) = safe.get(package) {
                let value = value.as_str().ok_or_else(unsupported)?;
                let prefix = if generation == Generation::V2 {
                    "@opencode/ai/providers/"
                } else {
                    "@ai-sdk/"
                };
                let suffix = value
                    .strip_prefix(prefix)
                    .filter(|suffix| {
                        !suffix.is_empty()
                            && suffix
                                .bytes()
                                .all(|byte| byte.is_ascii_lowercase() || byte == b'-')
                    })
                    .ok_or_else(unsupported)?;
                if ![
                    "openai",
                    "openai-compatible",
                    "anthropic",
                    "google",
                    "google-vertex",
                    "azure",
                    "amazon-bedrock",
                    "groq",
                    "mistral",
                    "xai",
                    "deepseek",
                    "togetherai",
                    "perplexity",
                    "cerebras",
                    "cohere",
                ]
                .contains(&suffix)
                {
                    return Err(unsupported());
                }
            }
            for key in ["settings", "options"] {
                if let Some(value) = safe.get(key) {
                    safe[key] = pick(
                        value,
                        &[
                            "baseURL",
                            "apiKey",
                            "headers",
                            "region",
                            "project",
                            "location",
                            "resourceName",
                            "apiVersion",
                            "timeout",
                            "headerTimeout",
                            "chunkTimeout",
                            "encoding",
                        ],
                    )?;
                }
            }
            if let Some(models) = safe.get_mut("models") {
                let entries = models
                    .as_object_mut()
                    .filter(|entries| entries.len() <= 256)
                    .ok_or_else(unsupported)?;
                for model in entries.values_mut() {
                    *model = pick(
                        model,
                        &[
                            "id",
                            "name",
                            "family",
                            "release_date",
                            "attachment",
                            "reasoning",
                            "temperature",
                            "tool_call",
                            "interleaved",
                            "cost",
                            "limit",
                            "modalities",
                            "capabilities",
                        ],
                    )?;
                }
            }
            if target.get(providers).is_none() {
                target[providers] = json!({});
            }
            if let Some(previous) = target[providers].get_mut(id) {
                merge(previous, &safe);
            } else {
                target[providers][id] = safe;
            }
        }
    }
    Ok(())
}

fn merge(target: &mut Value, source: &Value) {
    if let (Some(target), Some(source)) = (target.as_object_mut(), source.as_object()) {
        for (key, value) in source {
            if let Some(previous) = target.get_mut(key) {
                merge(previous, value)
            } else {
                target.insert(key.clone(), value.clone());
            }
        }
    } else {
        *target = source.clone();
    }
}

// Native environment substitutions in connection settings remain native. File
// interpolation is deliberately refused: it could import private instructions
// or other files into request headers/model configuration.
fn import_references(
    value: &mut Value,
    program: &mut Program,
    env: &dyn Fn(&str) -> Option<String>,
) -> io::Result<()> {
    match value {
        Value::String(text) => {
            if text.len() > 32 * 1024 || text.contains("{file:") {
                return Err(unsupported());
            }
            let source = text.clone();
            let mut output = String::new();
            let mut rest = source.as_str();
            while let Some(start) = rest.find("{env:") {
                output.push_str(&rest[..start]);
                rest = &rest[start + 5..];
                let end = rest.find('}').ok_or_else(unsupported)?;
                let name = &rest[..end];
                if name.is_empty()
                    || name.len() > 128
                    || !name
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
                    || name.starts_with("TOKENSTAT_")
                {
                    return Err(unsupported());
                }
                let alias = alias(name, program, env)?;
                output.push_str(&format!("{{env:{alias}}}"));
                rest = &rest[end + 1..];
            }
            output.push_str(rest);
            *text = output;
        }
        Value::Array(values) => {
            if values.len() > 256 {
                return Err(unsupported());
            }
            for value in values {
                import_references(value, program, env)?;
            }
        }
        Value::Object(values) => {
            if values.len() > 256 {
                return Err(unsupported());
            }
            for value in values.values_mut() {
                import_references(value, program, env)?;
            }
        }
        _ => {}
    }
    // Provider env declarations select native sign-in variables; they cannot
    // import guardian capabilities or executable configuration selectors.
    if let Some(names) = value.get_mut("env").and_then(Value::as_array_mut) {
        for name in names {
            let source = name
                .as_str()
                .filter(|name| !name.starts_with("TOKENSTAT_"))
                .ok_or_else(unsupported)?;
            *name = alias(source, program, env)?.into();
        }
    }
    Ok(())
}

fn alias(
    name: &str,
    program: &mut Program,
    env: &dyn Fn(&str) -> Option<String>,
) -> io::Result<String> {
    if name.is_empty()
        || name.len() > 128
        || name.starts_with("TOKENSTAT_")
        || !name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
    {
        return Err(unsupported());
    }
    let index = program
        .env
        .keys()
        .filter(|key| key.starts_with("TOKENSTAT_TEAM_PROVIDER_ENV_"))
        .count();
    if index >= 256 {
        return Err(unsupported());
    }
    let alias = format!("TOKENSTAT_TEAM_PROVIDER_ENV_{index}");
    let value = env(name).unwrap_or_default();
    // OpenCode expands file placeholders after environment placeholders.
    // An opaque key/header value must not introduce a second interpolation.
    if value.len() > 32 * 1024 || value.contains("{file:") || value.contains("{env:") {
        return Err(unsupported());
    }
    program.env.insert(alias.clone(), value);
    Ok(alias)
}

// Native OpenCode currently gives managed machine settings precedence over
// every CLI config override. Refuse those installations rather than allow
// machine plugins/MCP servers or permission overrides into a scoped run.
fn refuse_managed_config(env: &dyn Fn(&str) -> Option<String>) -> io::Result<()> {
    #[cfg(target_os = "macos")]
    let paths = {
        let mut paths = vec![
            PathBuf::from("/Library/Application Support/opencode"),
            PathBuf::from("/Library/Managed Preferences/ai.opencode.managed.plist"),
        ];
        if let Some(user) = env("USER").filter(|user| !user.contains(['/', '\\'])) {
            paths.push(
                PathBuf::from("/Library/Managed Preferences")
                    .join(user)
                    .join("ai.opencode.managed.plist"),
            );
        }
        paths
    };
    #[cfg(target_os = "windows")]
    let paths = vec![
        native_path(
            env("ProgramData"),
            PathBuf::from(r"C:\ProgramData"),
            Path::new(r"C:\"),
        )
        .join("opencode"),
    ];
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    let paths = {
        let _ = env;
        vec![PathBuf::from("/etc/opencode")]
    };
    for path in paths {
        if path.try_exists()? {
            return Err(io::Error::other(
                "Managed OpenCode settings override CLI isolation on this machine. Scoped Team runs require an OpenCode installation without machine-wide plugins or configuration.",
            ));
        }
    }
    Ok(())
}

fn unsupported() -> io::Error {
    io::Error::other(
        "The native CLI connection configuration cannot be safely reused for this Team run. Use a built-in provider package and connection/model settings without executable plugins or file interpolation.",
    )
}

const CREDENTIAL_MIGRATION: &str = "20260805200742_import_legacy_credentials";

fn prepare_native_database(
    program: &mut Program,
    native_data: &Path,
    env: &dyn Fn(&str) -> Option<String>,
) -> io::Result<()> {
    let selector = env("OPENCODE_DB").unwrap_or_else(|| "opencode.db".into());
    if selector == ":memory:" {
        program.env.insert("OPENCODE_DB".into(), selector);
        return Ok(());
    }
    let path = native_path(Some(selector), PathBuf::new(), native_data);
    if !path.try_exists()? {
        // A fresh private DB is fine for an environment/config API key, but
        // must not mark the person's legacy native sign-in migration complete
        // while its source auth.json is hidden by the private XDG home.
        if native_data.join("auth.json").try_exists()? {
            return Err(migration_required());
        }
        return Ok(());
    }
    ensure_native_database(&path)?;
    program
        .env
        .insert("OPENCODE_DB".into(), path.display().to_string());
    program.env.insert(
        "TOKENSTAT_TEAM_OPENCODE_NATIVE_DB".into(),
        path.display().to_string(),
    );
    Ok(())
}

fn migration_required() -> io::Error {
    io::Error::other(
        "Open the native OpenCode CLI once to finish its sign-in database migration, then retry the Team run.",
    )
}

/// Only inspect schema and remote-configuration metadata. Credential values,
/// private conversations and their transcripts are never queried here.
fn ensure_native_database(path: &Path) -> io::Result<()> {
    use rusqlite::{Connection, OpenFlags, OptionalExtension};
    let mut options = fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NONBLOCK);
    }
    let file = options.open(path).map_err(|_| migration_required())?;
    if !file.metadata()?.is_file() {
        return Err(migration_required());
    }
    let connection = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|_| migration_required())?;
    connection
        .busy_timeout(std::time::Duration::from_millis(250))
        .map_err(|_| migration_required())?;
    // An older database must complete its native migration with its original
    // XDG home before we let the native process open it from the private home.
    for (table, columns) in [
        (
            "credential",
            &["id", "integration_id", "value", "active"][..],
        ),
        ("kv", &["key", "value"][..]),
        ("migration", &["id", "time_completed"][..]),
        ("session", &["id"][..]),
    ] {
        let regular: bool = connection
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1)",
                [table],
                |row| row.get(0),
            )
            .map_err(|_| migration_required())?;
        if !regular {
            return Err(migration_required());
        }
        let mut statement = connection
            .prepare("SELECT name,pk FROM pragma_table_info(?1) LIMIT 129")
            .map_err(|_| migration_required())?;
        let actual = statement
            .query_map([table], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
            })
            .map_err(|_| migration_required())?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| migration_required())?;
        if actual.len() > 128
            || columns
                .iter()
                .any(|column| !actual.iter().any(|(actual, _)| actual == column))
            || !actual.iter().any(|(column, primary)| {
                column == if table == "kv" { "key" } else { "id" } && *primary > 0
            })
        {
            return Err(migration_required());
        }
    }
    let migrated:bool=connection.query_row("SELECT EXISTS(SELECT 1 FROM migration WHERE id=?1 AND typeof(time_completed)='integer' AND time_completed>=0)",[CREDENTIAL_MIGRATION],|row|row.get(0)).map_err(|_|migration_required())?;
    if !migrated {
        return Err(migration_required());
    }
    let metadata=connection.query_row("SELECT typeof(value),length(CAST(value AS BLOB)),CASE WHEN length(CAST(value AS BLOB))<=65536 THEN value ELSE NULL END FROM kv WHERE key='wellknown:sources'",[],|row|Ok((row.get::<_,String>(0)?,row.get::<_,i64>(1)?,row.get::<_,Option<String>>(2)?))).optional().map_err(|_|migration_required())?;
    if let Some((kind, length, text)) = metadata {
        let safe = kind == "text"
            && length <= 65536
            && text
                .as_deref()
                .and_then(|text| serde_json::from_str::<Value>(text).ok())
                .is_some_and(|value| value.as_array().is_some_and(Vec::is_empty));
        if !safe {
            return Err(io::Error::other(
                "This OpenCode sign-in loads remote organization configuration from its native database. Scoped Team runs require a native sign-in without remote plugins or instructions.",
            ));
        }
    }
    Ok(())
}

const PLUGIN_V1: &str = r#"const tools=new Set(__TEAM_TOOLS__);
export default async()=>({'tool.execute.before':async(input)=>{if(!tools.has(input.tool))throw Error('Only scoped Team tools are available.');}});
"#;

const PLUGIN_V2: &str = r#"const tools=new Set(__TEAM_TOOLS__);
export default {id:'tokenstat.team',async setup(ctx){
 await ctx.tool.hook('execute.before',event=>{if(!tools.has(event.tool))throw Error('Only scoped Team tools are available.');});
 await ctx.session.hook('prompt',async()=>{
  const until=Date.now()+15000;
  while(Date.now()<until){const result=await ctx.mcp.list();const server=result.data.find(server=>server.name==='tokenstat_team');if(server?.status?.status==='failed')throw Error('Team tools are unavailable.');
   if(server?.status?.status==='connected'&&(await ctx.tool.list()).some(tool=>tool.name==='team_context'||tool.name==='tokenstat_team_team_context'))return;
   await new Promise(resolve=>setTimeout(resolve,20));}
  throw Error('Team tools did not become ready.');
 });
}};
"#;

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    #[test]
    fn opencode_v2_requires_the_tested_native_plugin_protocol_version() {
        for version in ["opencode v2.0.32", "2.1.4", "v2.0.32+local", "3.0.0"] {
            assert!(tested_v2_version(version));
        }
        for version in ["2.0.31", "1.9.0", "2.0.32-beta.1", "unknown", "2.0"] {
            assert!(!tested_v2_version(version));
        }
    }

    fn fixture(
        backend: &str,
        generation: Option<Generation>,
    ) -> (tempfile::TempDir, RunHome, Program) {
        fixture_with_muse_override(backend, generation, false)
    }

    fn fixture_with_muse_override(
        backend: &str,
        generation: Option<Generation>,
        wrapper_override: bool,
    ) -> (tempfile::TempDir, RunHome, Program) {
        let root = tempfile::tempdir().unwrap();
        let checkout = root.path().join("checkout");
        fs::create_dir(&checkout).unwrap();
        let native = root.path().join("native");
        for directory in [".config/muse", ".config/opencode", ".local/share/opencode"] {
            fs::create_dir_all(native.join(directory)).unwrap();
        }
        #[cfg(not(windows))]
        fs::write(
            native.join(".config/muse/auth.json"),
            "opaque fictional Muse login",
        )
        .unwrap();
        fs::write(
            native.join(".local/share/opencode/auth.json"),
            "opaque fictional OpenCode login",
        )
        .unwrap();
        if generation == Some(Generation::V2) {
            initialized_database(&native.join(".local/share/opencode/opencode.db"));
        }
        fs::write(native.join(".config/muse/settings.json"),json!({
            "schema_version":1,"model":"fixture-model","endpoint_transport":{"base_url":"https://gateway.invalid","auth":"bearer"},
            "hooks":[{"command":"never run"}],"run":{"system_prompt":"never import"},"mcpServers":{"personal":{"command":"never run"}},
        }).to_string()).unwrap();
        let providers = if generation == Some(Generation::V1) {
            "provider"
        } else {
            "providers"
        };
        let mut config = json!({"model":"fixture/model","plugins":["never-run"],"instructions":["private-notes.md"],"mcp":{"personal":{"command":["never-run"]}}});
        config[providers] = json!({"fixture":{"name":"Fixture","env":["FIXTURE_API_KEY"],"settings":{"baseURL":"https://gateway.invalid/v1","headers":{"x-test":"{env:NODE_OPTIONS}"}},"models":{"model":{"name":"Fixture Model","instructions":"private notes must not import"}}}});
        fs::write(
            native.join(".config/opencode/opencode.jsonc"),
            format!("// Native connection only\n{config}"),
        )
        .unwrap();
        let mut program = Program {
            executable: root.path().join("fake-cli"),
            args: vec![],
            env: BTreeMap::from([("PATH".into(), "/usr/bin:/bin".into())]),
            folder: checkout.clone(),
            input: PathBuf::new(),
            output: PathBuf::new(),
            errors: PathBuf::new(),
        };
        let home = super::super::super::run_home::prepare(
            &root.path().join("scratch"),
            &checkout,
            &program,
        )
        .unwrap();
        program.env = home.env.clone();
        program.env.insert(
            "TOKENSTAT_TEAM_CLI_EXECUTABLE".into(),
            program.executable.display().to_string(),
        );
        let mut environment = BTreeMap::from([
            ("FIXTURE_API_KEY", "fictional-custom-key".to_string()),
            (
                "NODE_OPTIONS",
                "--require=/private/never-run.js".to_string(),
            ),
            ("META_API_KEY", "fictional-meta-key".to_string()),
        ]);
        if wrapper_override {
            fs::write(
                native.join("launcher-auth.json"),
                "opaque different Muse downloader account",
            )
            .unwrap();
            environment.insert("MUSE_AUTH_PATH", "../native/launcher-auth.json".into());
            environment.insert("TBH_CREDENTIAL_BACKEND", "file".into());
        }
        prepare_native(
            &home,
            &mut program,
            &root.path().join("helper with spaces"),
            backend,
            generation,
            &native,
            &|key| environment.get(key).cloned(),
            &checkout,
        )
        .unwrap();
        program.folder = home.file("home");
        super::super::rebuild(
            &home,
            &mut program,
            &root.path().join("helper with spaces"),
            backend,
            0,
            super::super::LANE_PROMPT,
        )
        .unwrap();
        (root, home, program)
    }

    #[test]
    fn native_connections_are_preserved_but_personal_tools_and_settings_are_excluded() {
        for (backend, generation) in [
            ("muse", None),
            ("opencode", Some(Generation::V1)),
            ("opencode2", Some(Generation::V2)),
        ] {
            let (_root, home, program) = fixture(backend, generation);
            assert_eq!(program.folder, home.file("home"));
            assert!(!program.env.contains_key("TOKENSTAT_CHAT_SOCKET"));
            assert!(!program.env.contains_key("NODE_OPTIONS"));
            let path = if backend == "muse" {
                home.file("config/muse/settings.json")
            } else {
                home.file("opencode.json")
            };
            let config: Value = serde_json::from_slice(&fs::read(path).unwrap()).unwrap();
            let serialized = config.to_string();
            assert!(!serialized.contains("never run"));
            assert!(!serialized.contains("private-notes"));
            assert!(!serialized.contains("personal"));
            assert!(serialized.contains("https://gateway.invalid"));
            if backend == "muse" {
                assert_eq!(config["schema_version"], 1);
                assert_eq!(config["model"], "fixture-model");
                #[cfg(not(windows))]
                assert_eq!(
                    fs::read_to_string(home.file("config/muse/auth.json")).unwrap(),
                    "opaque fictional Muse login"
                );
                #[cfg(windows)]
                assert!(!home.file("config/muse/auth.json").exists());
                assert!(
                    program
                        .args
                        .windows(2)
                        .any(|pair| pair == ["--preset", "empty"])
                );
                assert!(program.args.iter().any(|arg| arg == "run.toolset=[]"));
            } else {
                assert_eq!(config["model"], "fixture/model");
                let alias = PathBuf::from(&home.env["XDG_DATA_HOME"]).join("opencode/auth.json");
                if generation == Some(Generation::V2) {
                    assert!(!alias.exists());
                    assert!(
                        PathBuf::from(&program.env["OPENCODE_DB"]).ends_with(
                            Path::new("native").join(".local/share/opencode/opencode.db")
                        )
                    );
                } else {
                    assert_eq!(
                        fs::read_to_string(alias).unwrap(),
                        "opaque fictional OpenCode login"
                    );
                }
                let server = if generation == Some(Generation::V2) {
                    &config["mcp"]["servers"][super::super::SERVER]
                } else {
                    &config["mcp"][super::super::SERVER]
                };
                assert_eq!(server["environment"]["META_API_KEY"], "");
                if generation == Some(Generation::V2) {
                    assert_eq!(server["environment"]["OPENCODE_DB"], "");
                    assert_eq!(
                        server["environment"]["TOKENSTAT_TEAM_OPENCODE_NATIVE_DB"],
                        ""
                    );
                }
                for (key, value) in program
                    .env
                    .iter()
                    .filter(|(key, _)| key.starts_with("TOKENSTAT_TEAM_PROVIDER_ENV_"))
                {
                    assert!(!value.is_empty());
                    assert_eq!(server["environment"][key], "");
                }
                assert_eq!(
                    program.args.iter().any(|arg| arg == "--standalone"),
                    generation == Some(Generation::V2)
                );
                let plugin =
                    fs::read_to_string(home.file("opencode-team-plugin/index.js")).unwrap();
                for tool in crate::team_sdk::registered_tool_names() {
                    assert!(plugin.contains(&format!("tokenstat_team_{tool}")));
                }
                assert!(!plugin.contains("__TEAM_TOOLS__"));
                if generation == Some(Generation::V2) {
                    assert_eq!(server["codemode"], false);
                    assert_eq!(
                        config["permissions"][0],
                        json!({"action":"*","resource":"*","effect":"deny"})
                    );
                    assert_eq!(
                        config["permissions"].as_array().unwrap().len(),
                        crate::team_sdk::registered_tool_names().len() + 1
                    );
                }
            }
            assert!(
                !program
                    .args
                    .iter()
                    .any(|arg| arg == "--yolo" || arg == "--auto")
            );
        }
    }

    #[test]
    #[cfg(not(windows))]
    fn muse_download_account_does_not_replace_the_native_file_or_keychain_choice() {
        let (_root, home, program) = fixture_with_muse_override("muse", None, true);
        assert_eq!(program.env["TBH_CREDENTIAL_BACKEND"], "file");
        assert_eq!(
            fs::read_to_string(home.file("config/muse/auth.json")).unwrap(),
            "opaque fictional Muse login"
        );
        assert_eq!(
            PathBuf::from(&program.env["MUSE_AUTH_PATH"]),
            home.file("muse-launcher-auth.json")
        );
        assert_eq!(
            fs::read_to_string(&program.env["MUSE_AUTH_PATH"]).unwrap(),
            "opaque different Muse downloader account"
        );
        let mcp = program
            .args
            .iter()
            .find_map(|arg| arg.strip_prefix("mcpServers.tokenstat_team="))
            .unwrap();
        let mcp: Value = serde_json::from_str(mcp).unwrap();
        assert_eq!(
            mcp["env"]["TBH_CREDENTIAL_BACKEND"],
            "${TOKENSTAT_TEAM_MCP_EMPTY}"
        );
        assert_eq!(mcp["env"]["MUSE_AUTH_PATH"], "${TOKENSTAT_TEAM_MCP_EMPTY}");
    }

    #[test]
    #[cfg(windows)]
    fn muse_file_credentials_require_a_symbolic_link_or_explicitly_refuse_without_copying() {
        let root = tempfile::tempdir().unwrap();
        let source = root.path().join("original-auth.json");
        let target = root.path().join("private/auth.json");
        fs::write(&source, "opaque fictional Muse login").unwrap();
        match route_muse_credential(&source, &target) {
            Ok(()) => {
                assert!(
                    fs::symlink_metadata(&target)
                        .unwrap()
                        .file_type()
                        .is_symlink()
                );
                assert_eq!(
                    fs::read_to_string(&target).unwrap(),
                    "opaque fictional Muse login"
                );
            }
            Err(error) => {
                assert!(error.to_string().contains("symbolic link"));
                assert!(!target.exists());
            }
        }
    }

    #[test]
    fn connection_env_references_cannot_override_process_isolation() {
        let root = tempfile::tempdir().unwrap();
        let mut program = Program {
            executable: root.path().join("cli"),
            args: vec![],
            env: BTreeMap::from([("HOME".into(), "/isolated/home".into())]),
            folder: root.path().into(),
            input: PathBuf::new(),
            output: PathBuf::new(),
            errors: PathBuf::new(),
        };
        let mut value = json!({"headers":{"a":"prefix {env:NODE_OPTIONS} {env:HOME}"},"env":["OPENCODE_CONFIG_CONTENT"]});
        import_references(&mut value, &mut program, &|key| {
            Some(format!("native-{key}"))
        })
        .unwrap();
        assert_eq!(program.env["HOME"], "/isolated/home");
        assert!(!program.env.contains_key("NODE_OPTIONS"));
        assert!(!program.env.contains_key("OPENCODE_CONFIG_CONTENT"));
        assert!(value.to_string().contains("TOKENSTAT_TEAM_PROVIDER_ENV_"));
        for source in [
            "{env:TOKENSTAT_TEAM_SDK_TOKEN}",
            "{file:/personal/private.md}",
        ] {
            assert!(import_references(&mut json!(source), &mut program, &|_| None).is_err());
        }
        for injected in [
            "{file:/personal/private.md}",
            "{env:TOKENSTAT_TEAM_SDK_TOKEN}",
        ] {
            assert!(
                import_references(&mut json!("{env:NATIVE_API_KEY}"), &mut program, &|_| Some(
                    injected.into()
                ))
                .is_err()
            );
        }
    }

    #[test]
    fn unsupported_provider_code_and_malformed_or_oversized_settings_fail_closed() {
        for package in [
            "file:///personal/plugin.js",
            "@malicious/provider",
            "@opencode/ai/providers/../../plugin",
        ] {
            assert!(
                merge_connection(
                    &mut json!({}),
                    &json!({"providers":{"x":{"package":package}}}),
                    Generation::V2
                )
                .is_err()
            );
        }
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("settings.json");
        for bytes in [b"{invalid".to_vec(), vec![b' '; CONFIG_BYTES + 1]] {
            fs::write(&path, bytes).unwrap();
            assert!(read_json(&path).is_err());
        }
        assert!(read_json(root.path()).is_err());
        #[cfg(unix)]
        {
            use std::ffi::CString;
            use std::os::unix::ffi::OsStrExt;
            let fifo = root.path().join("fifo");
            let name = CString::new(fifo.as_os_str().as_bytes()).unwrap();
            assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
            assert!(read_json(&fifo).is_err());
        }
    }

    #[test]
    fn full_repair_prompts_use_private_input_for_all_three_launchers() {
        let failure = format!(
            "Fix every conflict, including @/private/never-read and /skill:\n{}End.",
            "目录/長い名前/file.rs\n".repeat(5000)
        );
        for (backend, generation) in [
            ("muse", None),
            ("opencode", Some(Generation::V1)),
            ("opencode2", Some(Generation::V2)),
        ] {
            let (root, home, mut program) = fixture(backend, generation);
            super::super::follow_up(
                &home,
                &mut program,
                &root.path().join("helper with spaces"),
                backend,
                1,
                &failure,
            )
            .unwrap();
            let input = fs::read_to_string(&program.input).unwrap();
            assert_eq!(super::super::decoded_repair_failure(&input), failure);
            assert!(input.contains("team_context"));
            assert!(!input.contains("@/private"));
            assert!(
                program
                    .args
                    .iter()
                    .map(|arg| arg.encode_utf16().count() + 1)
                    .sum::<usize>()
                    < 32767
            );
            assert!(!program.args.iter().any(|arg| arg.contains("目录")));
            if backend == "muse" {
                assert!(
                    program
                        .args
                        .windows(2)
                        .any(|pair| pair[0] == "--prompt-file"
                            && pair[1] == program.input.display().to_string())
                );
                assert!(
                    !program
                        .args
                        .iter()
                        .any(|arg| arg.contains("fictional-meta-key"))
                );
                let mcp = program
                    .args
                    .iter()
                    .find_map(|arg| arg.strip_prefix("mcpServers.tokenstat_team="))
                    .unwrap();
                let mcp: Value = serde_json::from_str(mcp).unwrap();
                assert_eq!(mcp["env"]["META_API_KEY"], "${TOKENSTAT_TEAM_MCP_EMPTY}");
                assert_eq!(
                    mcp["env"]["TOKENSTAT_TEAM_SDK_TOKEN"],
                    "${TOKENSTAT_TEAM_SDK_TOKEN}"
                );
            }
        }
    }

    fn initialized_database(path: &Path) -> rusqlite::Connection {
        let connection = rusqlite::Connection::open(path).unwrap();
        connection.execute_batch("CREATE TABLE credential(id TEXT PRIMARY KEY,integration_id TEXT,value TEXT,active INTEGER);CREATE TABLE kv(key TEXT PRIMARY KEY,value TEXT);CREATE TABLE migration(id TEXT PRIMARY KEY,time_completed INTEGER);CREATE TABLE session(id TEXT PRIMARY KEY,private_content BLOB);INSERT INTO credential VALUES('fictional','fixture','opaque credential value that is not JSON',1);INSERT INTO session VALUES('personal',X'FF00');").unwrap();
        connection
            .execute("INSERT INTO migration VALUES(?1,1)", [CREDENTIAL_MIGRATION])
            .unwrap();
        connection
    }

    #[test]
    fn native_database_guard_requires_complete_migration_and_never_reads_credentials_or_history() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("native.db");
        let connection = initialized_database(&path);
        ensure_native_database(&path).unwrap();
        connection.execute("DELETE FROM migration", []).unwrap();
        assert!(ensure_native_database(&path).is_err());
        connection
            .execute("INSERT INTO migration VALUES(?1,1)", [CREDENTIAL_MIGRATION])
            .unwrap();
        connection.execute("DROP TABLE credential", []).unwrap();
        assert!(ensure_native_database(&path).is_err());
        assert!(ensure_native_database(root.path()).is_err());
        #[cfg(unix)]
        {
            use std::{ffi::CString, os::unix::ffi::OsStrExt};
            let fifo = root.path().join("fifo");
            let name = CString::new(fifo.as_os_str().as_bytes()).unwrap();
            assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
            assert!(ensure_native_database(&fifo).is_err());
        }
    }

    #[test]
    fn remote_native_configuration_is_bounded_checked_in_wal_and_rejected_at_repair_birth() {
        let (root, home, mut program) = fixture("opencode2", Some(Generation::V2));
        let path = PathBuf::from(&program.env["OPENCODE_DB"]);
        let connection = rusqlite::Connection::open(&path).unwrap();
        connection
            .pragma_update(None, "journal_mode", "WAL")
            .unwrap();
        connection
            .execute("INSERT INTO kv VALUES('wellknown:sources','[]')", [])
            .unwrap();
        ensure_native_database(&path).unwrap();
        for text in [
            "not JSON".to_owned(),
            "{}".to_owned(),
            "[\"https://organization.invalid\"]".to_owned(),
            " ".repeat(65537),
        ] {
            connection
                .execute(
                    "UPDATE kv SET value=?1 WHERE key='wellknown:sources'",
                    [text],
                )
                .unwrap();
            assert!(ensure_native_database(&path).is_err());
            assert!(
                super::super::follow_up(
                    &home,
                    &mut program,
                    &root.path().join("helper"),
                    "opencode2",
                    1,
                    "fix conflict"
                )
                .is_err()
            );
        }
        assert!(!home.file("input-1").exists());
        connection
            .execute("UPDATE kv SET value='[]' WHERE key='wellknown:sources'", [])
            .unwrap();
        super::super::follow_up(
            &home,
            &mut program,
            &root.path().join("helper"),
            "opencode2",
            1,
            "fix conflict",
        )
        .unwrap();
        assert!(home.file("input-1").exists());
    }

    #[test]
    fn native_database_selection_uses_original_data_and_refuses_unmigrated_legacy_sign_in() {
        let root = tempfile::tempdir().unwrap();
        let native = root.path().join("native");
        fs::create_dir(&native).unwrap();
        let mut program = Program {
            executable: root.path().join("cli"),
            args: vec![],
            env: BTreeMap::new(),
            folder: root.path().into(),
            input: PathBuf::new(),
            output: PathBuf::new(),
            errors: PathBuf::new(),
        };
        prepare_native_database(&mut program, &native, &|_| None).unwrap();
        assert!(!program.env.contains_key("OPENCODE_DB"));
        fs::write(native.join("auth.json"), "opaque native legacy credentials").unwrap();
        assert!(prepare_native_database(&mut program, &native, &|_| None).is_err());
        initialized_database(&native.join("custom.db"));
        prepare_native_database(&mut program, &native, &|key| {
            (key == "OPENCODE_DB").then(|| "custom.db".into())
        })
        .unwrap();
        assert_eq!(
            PathBuf::from(&program.env["OPENCODE_DB"]),
            native.join("custom.db")
        );
        program.env.clear();
        prepare_native_database(&mut program, &native, &|key| {
            (key == "OPENCODE_DB").then(|| ":memory:".into())
        })
        .unwrap();
        assert_eq!(program.env["OPENCODE_DB"], ":memory:");
        assert!(
            !program
                .env
                .contains_key("TOKENSTAT_TEAM_OPENCODE_NATIVE_DB")
        );
    }
}
