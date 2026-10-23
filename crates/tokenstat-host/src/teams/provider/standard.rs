// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Native CLI adapters whose existing chat gate is a lifecycle hook. The
//! private settings expose only the guardian's MCP, never the personal host.

use super::{Path, PathBuf, Program, RunHome, fs, io, json, write_new};

const GROK_AUTH: &[&str] = &[
    "XAI_API_KEY",
    "GROK_CODE_XAI_API_KEY",
    "XAI_API_BASE_URL",
    "GROK_XAI_API_BASE_URL",
    "GROK_CLI_BASE_URL",
    "GROK_CLI_CHAT_PROXY_BASE_URL",
    "GROK_MODELS_BASE_URL",
    "GROK_MODELS_LIST_URL",
    "GROK_CODE_BACKEND_URL",
    "GROK_OIDC_ISSUER",
    "GROK_OIDC_CLIENT_ID",
    "GROK_AUTH",
    "GROK_DEPLOYMENT_KEY",
];
const CURSOR_AUTH: &[&str] = &[
    "CURSOR_API_KEY",
    "CURSOR_AUTH_TOKEN",
    "CURSOR_API_ENDPOINT",
    "CURSOR_AGENT_ENDPOINT",
    "AGENT_CLI_CREDENTIAL_STORE",
];
const AGY_AUTH: &[&str] = &[
    "AGY_ADC_AUTH",
    "GEMINI_API_KEY",
    "GOOGLE_GEMINI_BASE_URL",
    "GOOGLE_APPLICATION_CREDENTIALS",
    "GOOGLE_CLOUD_QUOTA_PROJECT",
    "GOOGLE_CLOUD_LOCATION",
];
const KEYRING_ENV: &[&str] = &["DBUS_SESSION_BUS_ADDRESS", "XDG_RUNTIME_DIR"];

pub(super) fn validate_help(backend: &str, text: &str) -> bool {
    let flags: &[&str] = match backend {
        "grok" => &[
            "--prompt-file",
            "--tools",
            "--disallowed-tools",
            "--deny",
            "--no-subagents",
            "--verbatim",
        ],
        "cursor" => &[
            "--plugin-dir",
            "--approve-mcps",
            "--force",
            "--output-format",
        ],
        "agy" => &[
            "--input-format",
            "stream-json",
            "--add-dir",
            "--disable-slash-commands",
        ],
        _ => return false,
    };
    flags.iter().all(|flag| text.contains(flag))
}

pub(super) fn agy_version_supported(text: &str) -> bool {
    text.split_whitespace()
        .find_map(|word| {
            let parts = word
                .trim_start_matches('v')
                .split('.')
                .map(str::parse::<u32>)
                .collect::<Result<Vec<_>, _>>()
                .ok()?;
            (parts.len() == 3).then(|| (parts[0], parts[1], parts[2]) >= (1, 3, 3))
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
    if backend == "grok" {
        refuse_grok_machine_settings(&grok_machine_settings(&home.file("home")))?;
    }
    prepare_native(
        home,
        program,
        helper,
        backend,
        &super::native_home()?,
        &super::native_env,
        native_folder,
    )
}

fn grok_machine_settings(cli_home: &Path) -> [PathBuf; 2] {
    // Native Grok documents these exact system layers. A rooted Windows path
    // uses the CLI cwd's drive, so anchor that drive rather than the daemon's.
    #[cfg(windows)]
    let directory = cli_home
        .ancestors()
        .last()
        .unwrap_or(cli_home)
        .join("etc/grok");
    #[cfg(not(windows))]
    let directory = {
        let _ = cli_home;
        PathBuf::from("/etc/grok")
    };
    [
        directory.join("managed_config.toml"),
        directory.join("requirements.toml"),
    ]
}

fn refuse_grok_machine_settings(paths: &[PathBuf]) -> io::Result<()> {
    for path in paths {
        match fs::symlink_metadata(path) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(_) => {
                return Err(io::Error::other(
                    "Grok machine-wide startup settings could not be checked for this isolated Team run.",
                ));
            }
            Ok(_) => {
                return Err(io::Error::other(
                    "Grok machine-wide startup settings can load plugins or hooks before Team tool guards. This configuration cannot be isolated for a Team run.",
                ));
            }
        }
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn prepare_native(
    home: &RunHome,
    program: &mut Program,
    helper: &Path,
    backend: &str,
    native_home: &Path,
    env: &dyn Fn(&str) -> Option<String>,
    native_folder: &Path,
) -> io::Result<()> {
    let auth = match backend {
        "grok" => GROK_AUTH,
        "cursor" => CURSOR_AUTH,
        "agy" => AGY_AUTH,
        _ => return Err(io::Error::other("Unsupported Team CLI.")),
    };
    for key in auth.iter().chain(KEYRING_ENV) {
        if let Some(value) = env(key) {
            program.env.insert((*key).into(), value);
        }
    }
    match backend {
        "grok" => {
            let directory = home.file("config/grok");
            fs::create_dir_all(directory.join("hooks"))?;
            let source =
                native_directory(env("GROK_HOME"), &native_home.join(".grok"), native_folder);
            let auth_path = native_directory(
                env("GROK_AUTH_PATH"),
                &source.join("auth.json"),
                native_folder,
            );
            // Native AuthManager independently selects this path for its
            // existing login/refresh. Keep the real store, not a disposable
            // credential alias whose atomic publication could detach it.
            program
                .env
                .insert("GROK_AUTH_PATH".into(), auth_path.display().to_string());
            program
                .env
                .insert("GROK_HOME".into(), directory.display().to_string());
            for key in [
                "GROK_MEMORY",
                "GROK_GOAL",
                "GROK_AGENT_DASHBOARD",
                "GROK_AUTO_UPDATE",
                "GROK_CLAUDE_SKILLS_ENABLED",
                "GROK_CLAUDE_RULES_ENABLED",
                "GROK_CLAUDE_AGENTS_ENABLED",
                "GROK_CLAUDE_MCPS_ENABLED",
                "GROK_CLAUDE_HOOKS_ENABLED",
                "GROK_CURSOR_SKILLS_ENABLED",
                "GROK_CURSOR_RULES_ENABLED",
                "GROK_CURSOR_AGENTS_ENABLED",
                "GROK_CURSOR_MCPS_ENABLED",
                "GROK_CURSOR_HOOKS_ENABLED",
                "GROK_CODEX_SKILLS_ENABLED",
                "GROK_CODEX_RULES_ENABLED",
                "GROK_CODEX_AGENTS_ENABLED",
                "GROK_CODEX_MCPS_ENABLED",
                "GROK_CODEX_HOOKS_ENABLED",
            ] {
                program.env.insert(key.into(), "0".into());
            }
            program
                .env
                .insert("GROK_DISABLE_AUTOUPDATER".into(), "1".into());
            write_new(
                &directory.join("hooks/tokenstat.json"),
                crate::chat_gate::team_hooks_document(helper, backend)
                    .to_string()
                    .as_bytes(),
            )?;
            let server = super::mcp_server(helper);
            let mut config = toml_edit::DocumentMut::new();
            config["mcp_servers"][super::SERVER]["command"] =
                toml_edit::value(helper.to_string_lossy().as_ref());
            let mut args = toml_edit::Array::new();
            args.push("team-run-sdk");
            config["mcp_servers"][super::SERVER]["args"] = toml_edit::value(args);
            for (key, value) in server["env"].as_object().expect("MCP environment") {
                config["mcp_servers"][super::SERVER]["env"][key] =
                    toml_edit::value(value.as_str().expect("environment string"));
            }
            // Grok expands whole-value references, without writing run tokens.
            for key in super::SDK_VARS {
                config["mcp_servers"][super::SERVER]["env"][key] =
                    toml_edit::value(format!("${{{key}}}"));
            }
            config["session"]["load_envrc"] = toml_edit::value(false);
            config["cli"]["use_leader"] = toml_edit::value(false);
            write_new(
                &directory.join("config.toml"),
                config.to_string().as_bytes(),
            )?;
        }
        "cursor" => {
            let directory = home.file("home/.cursor");
            fs::create_dir_all(&directory)?;
            let source = tokenstat_sync::discover::cursor_auth_file(native_home, &|key| {
                env(key).map(PathBuf::from)
            });
            let source = if source.is_absolute() {
                source
            } else {
                native_folder.join(source)
            };
            let target = tokenstat_sync::discover::cursor_auth_file(&home.file("home"), &|key| {
                program.env.get(key).map(PathBuf::from)
            });
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent)?;
            }
            route(&source, &target)?;
            program
                .env
                .insert("CURSOR_CONFIG_DIR".into(), directory.display().to_string());
            program
                .env
                .insert("CURSOR_DATA_DIR".into(), directory.display().to_string());
            let mut server = super::mcp_server(helper);
            server["type"] = "stdio".into();
            for key in super::SDK_VARS {
                server["env"][key] = format!("${{env:{key}}}").into();
            }
            write_new(
                &directory.join("mcp.json"),
                json!({"mcpServers":{super::SERVER:server}})
                    .to_string()
                    .as_bytes(),
            )?;
            let plugin = home.file("cursor-plugin");
            fs::create_dir_all(plugin.join(".cursor-plugin"))?;
            fs::create_dir_all(plugin.join("hooks"))?;
            write_new(
                &plugin.join(".cursor-plugin/plugin.json"),
                json!({"name":"tokenstat-team","version":env!("CARGO_PKG_VERSION")})
                    .to_string()
                    .as_bytes(),
            )?;
            let hook = team_pre_hook(helper, backend);
            let mcp_command = hook["command"]
                .as_str()
                .ok_or_else(|| io::Error::other("Missing Team tool gate."))?
                .strip_suffix(" pre")
                .ok_or_else(|| io::Error::other("Invalid Team tool gate."))?
                .to_owned()
                + " mcp";
            write_new(
                &plugin.join("hooks/hooks.json"),
                json!({"version":1,"hooks":{
                    "preToolUse":[{"command":hook["command"],"timeout":300,"failClosed":true}],
                    "beforeMCPExecution":[{"command":mcp_command,"timeout":300,"failClosed":true}]
                }})
                .to_string()
                .as_bytes(),
            )?;
        }
        "agy" => {
            let gemini = home.file("home/.gemini");
            let agents = home.file("home/.agents");
            fs::create_dir_all(gemini.join("config"))?;
            fs::create_dir_all(gemini.join("antigravity-cli"))?;
            fs::create_dir_all(&agents)?;
            program.env.insert(
                "ANTIGRAVITY_GEMINI_DIR".into(),
                gemini.display().to_string(),
            );
            write_new(
                &gemini.join("config/mcp_config.json"),
                json!({"mcpServers":{super::SERVER:super::mcp_server(helper)}})
                    .to_string()
                    .as_bytes(),
            )?;
            let hooks = crate::chat_gate::team_hooks_document(helper, backend);
            write_new(
                &agents.join("hooks.json"),
                json!({"tokenstat":hooks["hooks"]}).to_string().as_bytes(),
            )?;
            let native_gemini = native_directory(
                env("ANTIGRAVITY_GEMINI_DIR"),
                &native_home.join(".gemini"),
                native_folder,
            );
            let settings = agy_auth_settings(&native_gemini.join("antigravity-cli/settings.json"))?;
            write_new(
                &gemini.join("antigravity-cli/settings.json"),
                settings.to_string().as_bytes(),
            )?;
            let explicit_adc =
                env("GOOGLE_APPLICATION_CREDENTIALS").filter(|path| !path.is_empty());
            if explicit_adc.is_some()
                || program
                    .env
                    .get("AGY_ADC_AUTH")
                    .is_some_and(|value| go_true(value))
            {
                let source = native_directory(
                    explicit_adc,
                    &native_home.join(".config/gcloud/application_default_credentials.json"),
                    native_folder,
                );
                // Native ADC accepts a credential-file selector; it does not
                // need the person's gcloud settings or executable callbacks.
                program.env.insert(
                    "GOOGLE_APPLICATION_CREDENTIALS".into(),
                    source.display().to_string(),
                );
            }
        }
        _ => unreachable!(),
    }
    Ok(())
}

fn go_true(value: &str) -> bool {
    matches!(value, "1" | "t" | "T" | "TRUE" | "true" | "True")
}

fn agy_auth_settings(path: &Path) -> io::Result<serde_json::Value> {
    use std::io::Read;
    let mut options = fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NONBLOCK);
    }
    let file = match options.open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(json!({})),
        Err(_) => {
            return Err(io::Error::other(
                "The native Antigravity sign-in selection could not be read.",
            ));
        }
    };
    if !file.metadata()?.is_file() {
        return Err(io::Error::other(
            "The native Antigravity sign-in selection is not a file.",
        ));
    }
    let mut bytes = Vec::new();
    file.take(256 * 1024 + 1).read_to_end(&mut bytes)?;
    if bytes.len() > 256 * 1024 {
        return Err(io::Error::other(
            "The native Antigravity sign-in selection is too large.",
        ));
    }
    #[derive(serde::Deserialize)]
    struct Selection {
        #[serde(rename = "modelProvider")]
        model_provider: Option<String>,
    }
    let selection: Selection = serde_json::from_slice(&bytes)
        .map_err(|_| io::Error::other("The native Antigravity sign-in selection is invalid."))?;
    match selection.model_provider.as_deref() {
        None | Some("") => Ok(json!({})),
        Some("gemini") => Ok(json!({"modelProvider":"gemini"})),
        _ => Err(io::Error::other(
            "This native Antigravity model provider cannot be reused in an isolated Team run.",
        )),
    }
}

fn native_directory(value: Option<String>, default: &Path, folder: &Path) -> PathBuf {
    let path = value
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| default.into());
    if path.is_absolute() {
        path
    } else {
        folder.join(path)
    }
}

fn route(source: &Path, target: &Path) -> io::Result<()> {
    crate::chat_gate::route_team_cli_credential(source, target).map_err(io::Error::other)
}

fn team_pre_hook(helper: &Path, backend: &str) -> serde_json::Value {
    crate::chat_gate::team_hooks_document(helper, backend)["hooks"]["PreToolUse"][0]["hooks"][0]
        .clone()
}

pub(super) fn command(
    home: &RunHome,
    program: &mut Program,
    helper: &Path,
    backend: &str,
    prompt: &str,
) -> io::Result<Vec<String>> {
    // Grok exposes MCP through search/use gateways rather than direct model
    // functions. Give it the scoped schemas so search_tool can stay denied;
    // the guardian authorizes only use_tool's exact qualified MCP target.
    let prompt = if backend == "grok" {
        format!(
            "Grok MCP transport: call use_tool with tool_name tokenstat_team__<tool> and an inline tool_input object using these schemas. Do not call search_tool or use file/tool_input_file arguments. File tools are available only when this run has a lane. Scoped schemas: {}\n\n{prompt}",
            json!(crate::team_sdk::registered_tool_schemas())
        )
    } else {
        prompt.to_owned()
    };
    let plugin = home.file("cursor-plugin");
    let customization = home.file("home");
    let mut argv = crate::automations::chat_agent_command_in(
        backend,
        &prompt,
        None,
        None,
        0,
        crate::automations::ChatLaunch {
            resume: None,
            bypass: false,
            mode: "execute",
            hook_helper: Some(helper),
            system_append: None,
            agy_customization_dir: (backend == "agy").then_some(customization.as_path()),
            cursor_plugin_dir: (backend == "cursor").then_some(plugin.as_path()),
            grok_allow_rules: &[],
            attachments: &[],
        },
        Some(&program.folder),
    )
    .map_err(io::Error::other)?;
    let marker = match backend {
        "grok" => "-p",
        "agy" => "--print",
        "cursor" => "--",
        _ => return Err(io::Error::other("Unsupported Team CLI.")),
    };
    let at = argv
        .iter()
        .rposition(|arg| arg == marker)
        .and_then(|at| at.checked_add(1))
        .ok_or_else(|| io::Error::other("Missing guarded CLI prompt."))?;
    let prompt = argv
        .get(at)
        .cloned()
        .ok_or_else(|| io::Error::other("Missing guarded CLI prompt."))?;
    match backend {
        "grok" => {
            argv[at - 1] = "--prompt-file".into();
            argv[at] = program.input.display().to_string();
            // Empty or unknown Grok allowlists fall back to every builtin.
            // Select one real builtin, then exclude it: only MCP transport
            // gateways remain. Read-deny also blocks use_tool's file-argument
            // forms before native code opens a file, ahead of the MCP hook.
            argv.extend([
                "--tools".into(),
                "read_file".into(),
                "--disallowed-tools".into(),
                "read_file".into(),
                "--deny".into(),
                "Read".into(),
                "--deny".into(),
                "Bash".into(),
                "--no-subagents".into(),
                "--disable-web-search".into(),
                "--verbatim".into(),
                "--no-leader".into(),
            ]);
            write_new(&program.input, prompt.as_bytes())?;
        }
        "cursor" => {
            argv.remove(at);
            argv.splice(1..1, ["--approve-mcps".into()]);
            write_new(&program.input, prompt.as_bytes())?;
        }
        "agy" => {
            // Agy's stream input runs one user message per line. Keep the
            // mandatory --print value empty and carry the complete turn as
            // NDJSON, including Unicode and conflict lists of any argv size.
            argv[at] = "".into();
            argv.extend([
                "--input-format".into(),
                "stream-json".into(),
                "--disable-slash-commands".into(),
            ]);
            write_new(
                &program.input,
                format!(
                    "{}\n",
                    json!({"event":"user","message":{"content":[{"type":"text","text":prompt}]}})
                )
                .as_bytes(),
            )?;
        }
        _ => unreachable!(),
    }
    Ok(argv)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    #[test]
    fn grok_machine_startup_settings_fail_closed_without_reading_their_contents() {
        let root = tempfile::tempdir().unwrap();
        let paths = [
            root.path().join("managed_config.toml"),
            root.path().join("requirements.toml"),
        ];
        assert!(refuse_grok_machine_settings(&paths).is_ok());
        fs::write(&paths[1], "not TOML: metadata alone must refuse").unwrap();
        assert!(refuse_grok_machine_settings(&paths).is_err());
        fs::remove_file(&paths[1]).unwrap();
        fs::create_dir(&paths[0]).unwrap();
        assert!(refuse_grok_machine_settings(&paths).is_err());
        fs::remove_dir(&paths[0]).unwrap();
        let file = root.path().join("not-a-directory");
        fs::write(&file, "").unwrap();
        assert!(refuse_grok_machine_settings(&[file.join("settings.toml")]).is_err());
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(root.path().join("missing"), &paths[0]).unwrap();
            assert!(refuse_grok_machine_settings(&paths).is_err());
        }
    }

    fn fixture(
        backend: &str,
        environment: BTreeMap<String, String>,
    ) -> (tempfile::TempDir, RunHome, Program) {
        let root = tempfile::tempdir().unwrap();
        let checkout = root.path().join("checkout");
        fs::create_dir(&checkout).unwrap();
        let lane = root.path().join("lane");
        fs::create_dir(&lane).unwrap();
        let native = root.path().join("native");
        fs::create_dir(&native).unwrap();
        for directory in [
            ".grok",
            ".cursor",
            ".config/cursor",
            ".gemini/antigravity-cli",
        ] {
            fs::create_dir_all(native.join(directory)).unwrap();
        }
        fs::write(native.join(".grok/auth.json"), "fictional-grok-sign-in").unwrap();
        let cursor = tokenstat_sync::discover::cursor_auth_file(&native, &|_| None);
        fs::create_dir_all(cursor.parent().unwrap()).unwrap();
        fs::write(cursor, "fictional-cursor-sign-in").unwrap();
        fs::write(
            native.join(".grok/config.toml"),
            "personal settings must not load",
        )
        .unwrap();
        fs::write(
            native.join(".cursor/mcp.json"),
            "personal MCP must not load",
        )
        .unwrap();
        fs::write(native.join(".gemini/antigravity-cli/settings.json"),r#"{"modelProvider":"","statusLine":{"command":"must never run"},"model":"personal-model"}"#).unwrap();
        let mut program = Program {
            executable: root.path().join(format!("fake-{backend}")),
            args: vec![],
            env: BTreeMap::from([("PATH".into(), "/usr/bin:/bin".into())]),
            folder: lane.clone(),
            input: PathBuf::new(),
            output: PathBuf::new(),
            errors: PathBuf::new(),
        };
        let home =
            super::super::super::run_home::prepare(&root.path().join("scratch"), &lane, &program)
                .unwrap();
        program.env = home.env.clone();
        program.env.insert(
            "TOKENSTAT_TEAM_CLI_EXECUTABLE".into(),
            program.executable.display().to_string(),
        );
        prepare_native(
            &home,
            &mut program,
            &root.path().join("helper with spaces"),
            backend,
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
    fn native_auth_is_routed_without_personal_configuration_or_management_socket() {
        let env = BTreeMap::from([
            ("XAI_API_KEY".into(), "fictional-xai-key".into()),
            (
                "GROK_XAI_API_BASE_URL".into(),
                "https://xai-gateway.invalid/v1".into(),
            ),
            ("CURSOR_AUTH_TOKEN".into(), "fictional-cursor-token".into()),
            (
                "CURSOR_API_ENDPOINT".into(),
                "https://cursor-gateway.invalid".into(),
            ),
            ("GEMINI_API_KEY".into(), "fictional-gemini-key".into()),
            (
                "GOOGLE_GEMINI_BASE_URL".into(),
                "https://gemini-gateway.invalid".into(),
            ),
            ("AGY_ADC_AUTH".into(), "TRUE".into()),
            (
                "DBUS_SESSION_BUS_ADDRESS".into(),
                "unix:path=/fictional-keyring".into(),
            ),
        ]);
        for backend in ["grok", "cursor", "agy"] {
            let (_root, home, program) = fixture(backend, env.clone());
            let expected = match backend {
                "grok" => GROK_AUTH,
                "cursor" => CURSOR_AUTH,
                _ => AGY_AUTH,
            };
            for key in expected {
                if let Some(value) = env.get(*key) {
                    assert_eq!(program.env.get(*key), Some(value));
                }
            }
            assert_eq!(
                program.env["DBUS_SESSION_BUS_ADDRESS"],
                "unix:path=/fictional-keyring"
            );
            assert!(!program.env.contains_key("TOKENSTAT_CHAT_SOCKET"));
            assert!(!program.env.contains_key("TOKENSTAT_CHAT_TURN_FILE"));
            assert_eq!(program.folder, home.file("home"));
            let config = match backend {
                "grok" => {
                    assert_eq!(
                        fs::read_to_string(&program.env["GROK_AUTH_PATH"]).unwrap(),
                        "fictional-grok-sign-in"
                    );
                    assert!(!home.file("config/grok/auth.json").exists());
                    assert!(
                        fs::read_to_string(home.file("config/grok/hooks/tokenstat.json"))
                            .unwrap()
                            .contains("team-hook grok pre")
                    );
                    assert!(
                        program
                            .args
                            .windows(2)
                            .any(|pair| pair == ["--tools", "read_file"])
                    );
                    assert!(
                        program
                            .args
                            .windows(2)
                            .any(|pair| pair == ["--disallowed-tools", "read_file"])
                    );
                    assert!(program.args.iter().any(|arg| arg == "--no-leader"));
                    let text = fs::read_to_string(home.file("config/grok/config.toml")).unwrap();
                    let _: toml_edit::DocumentMut = text.parse().unwrap();
                    text
                }
                "cursor" => {
                    let auth =
                        tokenstat_sync::discover::cursor_auth_file(&home.file("home"), &|key| {
                            program.env.get(key).map(PathBuf::from)
                        });
                    assert_eq!(
                        fs::read_to_string(auth).unwrap(),
                        "fictional-cursor-sign-in"
                    );
                    let hooks: serde_json::Value = serde_json::from_slice(
                        &fs::read(home.file("cursor-plugin/hooks/hooks.json")).unwrap(),
                    )
                    .unwrap();
                    for phase in ["preToolUse", "beforeMCPExecution"] {
                        assert_eq!(hooks["hooks"][phase][0]["failClosed"], true);
                    }
                    assert!(hooks.to_string().contains("team-hook cursor mcp"));
                    fs::read_to_string(home.file("home/.cursor/mcp.json")).unwrap()
                }
                _ => {
                    let settings =
                        fs::read_to_string(home.file("home/.gemini/antigravity-cli/settings.json"))
                            .unwrap();
                    // A Gemini key in the shell must not switch an OAuth CLI.
                    assert_eq!(settings, "{}");
                    assert!(
                        program.env["GOOGLE_APPLICATION_CREDENTIALS"].ends_with(
                            "native/.config/gcloud/application_default_credentials.json"
                        )
                    );
                    assert!(
                        fs::read_to_string(home.file("home/.agents/hooks.json"))
                            .unwrap()
                            .contains("team-hook agy pre")
                    );
                    fs::read_to_string(home.file("home/.gemini/config/mcp_config.json")).unwrap()
                }
            };
            assert!(!config.contains("personal"));
            for secret in [
                "fictional-xai-key",
                "fictional-cursor-token",
                "fictional-gemini-key",
                "unix:path=/fictional-keyring",
            ] {
                assert!(!config.contains(secret));
            }
            assert!(
                !program
                    .args
                    .iter()
                    .any(|arg| arg == "--resume" || arg == "--conversation")
            );
        }
    }

    #[test]
    fn agy_preserves_only_the_native_provider_selector_and_adc_boolean_semantics() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("settings.json");
        fs::write(&path,r#"{"modelProvider":"gemini","statusLine":{"command":"secret-hook"},"hooks":{},"customModelsConfig":{}}"#).unwrap();
        assert_eq!(
            agy_auth_settings(&path).unwrap(),
            json!({"modelProvider":"gemini"})
        );
        fs::write(&path, "corrupt").unwrap();
        assert!(agy_auth_settings(&path).is_err());
        fs::write(&path, r#"{"modelProvider":"unrecognized"}"#).unwrap();
        assert!(agy_auth_settings(&path).is_err());
        for value in ["1", "t", "T", "TRUE", "true", "True"] {
            assert!(go_true(value));
        }
        for value in ["0", "f", "FALSE", "false", ""] {
            assert!(!go_true(value));
        }
        assert!(agy_version_supported("1.3.3"));
        assert!(!agy_version_supported("1.3.2"));
    }

    #[test]
    fn native_relative_selectors_keep_the_publishers_checkout_base() {
        let environment = BTreeMap::from([
            ("GROK_HOME".into(), "../native/.grok".into()),
            ("ANTIGRAVITY_GEMINI_DIR".into(), "../native/.gemini".into()),
            (
                "GOOGLE_APPLICATION_CREDENTIALS".into(),
                "./login/adc.json".into(),
            ),
        ]);
        let (_root, home, program) = fixture("grok", environment.clone());
        assert_eq!(
            fs::read_to_string(&program.env["GROK_AUTH_PATH"]).unwrap(),
            "fictional-grok-sign-in"
        );
        assert!(!home.file("config/grok/auth.json").exists());
        let (root, _home, program) = fixture("agy", environment);
        assert_eq!(
            Path::new(&program.env["GOOGLE_APPLICATION_CREDENTIALS"]),
            root.path().join("checkout/login/adc.json")
        );
        assert_eq!(
            Path::new(&program.env["GOOGLE_APPLICATION_CREDENTIALS"])
                .parent()
                .unwrap()
                .parent()
                .unwrap(),
            root.path().join("checkout")
        );
    }

    #[cfg(unix)]
    #[test]
    fn fake_native_clis_read_complete_initial_and_large_unicode_repair_prompts() {
        use std::os::unix::fs::PermissionsExt;
        let repair = "目录/長い名前/file.rs\n".repeat(5000) + "End of conflict list.";
        for backend in ["grok", "cursor", "agy"] {
            let (root, home, mut program) = fixture(backend, BTreeMap::new());
            fs::write(&program.executable,"#!/bin/sh\nwhile [ $# -gt 0 ]; do\n if [ \"$1\" = --prompt-file ]; then shift; cat \"$1\"; exit; fi\n shift\ndone\ncat\n").unwrap();
            fs::set_permissions(&program.executable, fs::Permissions::from_mode(0o700)).unwrap();
            for attempt in 0..=1 {
                if attempt > 0 {
                    super::super::follow_up(
                        &home,
                        &mut program,
                        &root.path().join("helper with spaces"),
                        backend,
                        attempt,
                        &repair,
                    )
                    .unwrap();
                }
                let output = std::process::Command::new(&program.executable)
                    .args(&program.args)
                    .env_clear()
                    .envs(&program.env)
                    .current_dir(&program.folder)
                    .stdin(std::process::Stdio::from(
                        fs::File::open(&program.input).unwrap(),
                    ))
                    .output()
                    .unwrap();
                assert!(output.status.success());
                let text = String::from_utf8(output.stdout).unwrap();
                let actual = if backend == "agy" {
                    let value: serde_json::Value = serde_json::from_str(&text).unwrap();
                    assert_eq!(value["event"], "user");
                    value["message"]["content"][0]["text"]
                        .as_str()
                        .unwrap()
                        .to_string()
                } else {
                    text
                };
                assert!(actual.contains("team_context"));
                if attempt > 0 {
                    assert_eq!(super::super::decoded_repair_failure(&actual), repair);
                }
                assert!(
                    program
                        .args
                        .iter()
                        .map(|arg| arg.encode_utf16().count() + 1)
                        .sum::<usize>()
                        < 32767
                );
                assert!(!program.args.iter().any(|arg| arg.contains("目录")));
            }
        }
    }
}
