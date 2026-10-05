// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Per-conversation speed selection, independent of the CLI's saved defaults.

use serde_json::{Value, json};

pub(crate) fn models(backend: &str) -> Option<&'static [&'static str]> {
    match backend {
        // Codex decides availability for the selected model/account.
        "codex" => Some(&[]),
        "claude" => Some(&[
            "opus",
            "claude-opus-5-5",
            "claude-opus-5",
            "claude-opus-4-8",
        ]),
        _ => None,
    }
}

pub(crate) fn available(backend: &str, model: Option<&str>) -> bool {
    let Some(models) = models(backend) else {
        return false;
    };
    if models.is_empty() {
        return true;
    }
    let Some(model) = model else { return false };
    models.iter().any(|prefix| {
        model == *prefix
            || model.strip_prefix(prefix).is_some_and(|suffix| {
                suffix.starts_with('[')
                    || suffix.strip_prefix('-').is_some_and(|date| {
                        date.len() == 8 && date.bytes().all(|byte| byte.is_ascii_digit())
                    })
            })
    })
}

pub(crate) fn apply(
    backend: &str,
    model: Option<&str>,
    fast: bool,
    argv: &mut Vec<String>,
) -> Result<(), String> {
    if fast && !available(backend, model) {
        return Err("Fast mode requires a supported Codex model or Claude Opus model.".into());
    }
    match backend {
        "codex" => {
            // Global options stay before `exec`, including resumed turns.
            let tier = if fast { "priority" } else { "default" };
            argv.splice(1..1, ["-c".into(), format!("service_tier=\"{tier}\"")]);
            if fast {
                argv.splice(1..1, ["-c".into(), "features.fast_mode=true".into()]);
            }
        }
        "claude" => {
            // Merge into the existing hook settings, so speed never drops
            // approval or edit-observation hooks. Explicit false also wins
            // over a fastMode preference saved in the user's Claude settings.
            if let Some(at) = argv.iter().position(|arg| arg == "--settings") {
                let raw = argv.get_mut(at + 1).ok_or("missing Claude settings")?;
                let mut settings: Value =
                    serde_json::from_str(raw).map_err(|error| error.to_string())?;
                let object = settings.as_object_mut().ok_or("invalid Claude settings")?;
                object.insert("fastMode".into(), json!(fast));
                *raw = settings.to_string();
            } else {
                argv.splice(
                    1..1,
                    ["--settings".into(), json!({"fastMode": fast}).to_string()],
                );
            }
        }
        _ => {}
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fast_mode_does_not_offer_unsupported_claude_models() {
        for model in [
            "opus",
            "opus[1m]",
            "claude-opus-5-5",
            "claude-opus-5",
            "claude-opus-4-8-20260525",
        ] {
            assert!(available("claude", Some(model)), "{model}");
        }
        for model in [
            None,
            Some("sonnet"),
            Some("haiku"),
            Some("claude-opus-4-7"),
            Some("claude-opus-4-6"),
            Some("claude-opus-5-9"),
        ] {
            assert!(!available("claude", model));
        }
        assert!(available("codex", None));
        assert!(!available("grok", None));
    }

    #[test]
    fn claude_fast_mode_preserves_hooks_and_explicitly_disables_saved_fast_mode() {
        let hooks = json!({"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"hook"}]}]}});
        let mut argv = vec![
            "claude".into(),
            "--settings".into(),
            hooks.to_string(),
            "-p".into(),
            "prompt".into(),
        ];
        for fast in [true, false] {
            apply("claude", Some("opus"), fast, &mut argv).unwrap();
            let settings: Value = serde_json::from_str(&argv[2]).unwrap();
            assert_eq!(settings["hooks"], hooks["hooks"]);
            assert_eq!(settings["fastMode"], fast);
            assert_eq!(argv.iter().filter(|arg| *arg == "--settings").count(), 1);
        }
    }

    #[test]
    fn fast_mode_settings_cover_bypass_and_codex_resume_without_changing_prompt() {
        let mut claude = vec!["claude".into(), "-p".into(), "prompt".into()];
        apply("claude", Some("opus"), true, &mut claude).unwrap();
        assert_eq!(
            claude,
            [
                "claude",
                "--settings",
                "{\"fastMode\":true}",
                "-p",
                "prompt"
            ]
        );
        for fast in [true, false] {
            let mut codex = vec![
                "codex".into(),
                "exec".into(),
                "resume".into(),
                "session".into(),
                "--".into(),
                "prompt".into(),
            ];
            apply("codex", None, fast, &mut codex).unwrap();
            let tier = if fast {
                "service_tier=\"priority\""
            } else {
                "service_tier=\"default\""
            };
            assert!(
                codex.iter().position(|arg| arg == tier).unwrap()
                    < codex.iter().position(|arg| arg == "exec").unwrap()
            );
            assert_eq!(
                &codex[codex.len() - 5..],
                ["exec", "resume", "session", "--", "prompt"]
            );
        }
    }
}
