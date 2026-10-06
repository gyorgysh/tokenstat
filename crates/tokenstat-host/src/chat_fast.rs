// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Per-conversation speed selection, independent of the CLI's saved defaults.

use serde_json::{Value, json};

pub(crate) fn models(backend: &str) -> Option<Vec<String>> {
    let fixed: &[&str] = match backend {
        // Codex decides availability for the selected model/account.
        "codex" => &[],
        "claude" => &[
            "opus",
            "claude-opus-5-5",
            "claude-opus-5",
            "claude-opus-4-8",
        ],
        "grok" => return grok_models(&crate::agent_models::for_backend("grok", &[])),
        _ => return None,
    };
    Some(fixed.iter().map(|model| (*model).into()).collect())
}

/// Grok Build exposes speed as separate model IDs, not a service-tier flag.
/// Only offer pairs the installed CLI actually lists for this account.
fn grok_models(catalog: &[String]) -> Option<Vec<String>> {
    let mut models: Vec<String> = catalog
        .iter()
        .filter(|model| catalog.contains(&format!("{model}-build-fast")))
        .cloned()
        .collect();
    if models.is_empty() {
        return None;
    }
    // An empty entry explicitly supports the CLI's Default selection; an
    // empty list still means provider-controlled availability for Codex.
    if catalog.first().is_some_and(|model| models.contains(model)) {
        models.push(String::new());
    }
    Some(models)
}

pub(crate) fn available(backend: &str, model: Option<&str>) -> bool {
    let Some(models) = models(backend) else {
        return false;
    };
    if backend == "grok" {
        return models
            .iter()
            .any(|supported| supported == model.unwrap_or(""));
    }
    if models.is_empty() {
        return true;
    }
    let Some(model) = model else { return false };
    // Claude accepts the context suffix on full snapshot IDs as well as
    // aliases. Strip it before checking the optional snapshot date.
    let model = model.strip_suffix("[1m]").unwrap_or(model);
    models.iter().any(|prefix| {
        model == prefix
            || model.strip_prefix(prefix.as_str()).is_some_and(|suffix| {
                suffix.strip_prefix('-').is_some_and(|date| {
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
        return Err("Fast mode requires a supported model listed by this agent. Refresh the model list and select a supported model.".into());
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
        "grok" if fast => {
            apply_grok(model, &crate::agent_models::for_backend("grok", &[]), argv)?;
        }
        _ => {}
    }
    Ok(())
}

fn apply_grok(
    model: Option<&str>,
    catalog: &[String],
    argv: &mut Vec<String>,
) -> Result<(), String> {
    let explicit = model.is_some();
    let model = model
        .or_else(|| catalog.first().map(String::as_str))
        .ok_or("Refresh Grok's model list before enabling fast mode.")?;
    let fast = format!("{model}-build-fast");
    if !catalog.iter().any(|id| id == model) || !catalog.contains(&fast) {
        return Err("This Grok model has no available fast variant. Refresh the model list and select a supported model.".into());
    }
    if explicit {
        let at = argv
            .windows(2)
            .position(|pair| pair[0] == "--model" && pair[1] == model)
            .ok_or("missing Grok model")?;
        argv[at + 1] = fast;
    } else {
        argv.splice(1..1, ["--model".into(), fast]);
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
            "claude-opus-5-5[1m]",
            "claude-opus-5",
            "claude-opus-4-8-20260525",
            "claude-opus-4-8-20260525[1m]",
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
            Some("claude-opus-5-9[1m]"),
            Some("claude-opus-4-7-20260416[1m]"),
            Some("opus[bogus]"),
        ] {
            assert!(!available("claude", model));
        }
        assert!(available("codex", None));
        assert!(!available("grok", Some("grok-code-fast-1")));
    }

    #[test]
    fn grok_fast_mode_uses_only_listed_pairs_and_preserves_resume_and_prompt() {
        let catalog = ["grok-4.7", "grok-4.7-build-fast", "grok-4.6"].map(String::from);
        assert_eq!(
            grok_models(&catalog),
            Some(vec!["grok-4.7".into(), String::new()])
        );
        assert_eq!(grok_models(&["grok-4.6".into()]), None);
        assert_eq!(
            grok_models(&["grok-4.7-build-fast".into(), "grok-4.7".into()]),
            Some(vec!["grok-4.7".into()])
        );
        for model in [None, Some("grok-4.7")] {
            let mut argv = vec![
                "grok".into(),
                "--resume".into(),
                "session".into(),
                "-p".into(),
                "literal --model text".into(),
            ];
            if let Some(model) = model {
                argv.splice(1..1, ["--model".into(), model.into()]);
            }
            apply_grok(model, &catalog, &mut argv).unwrap();
            assert_eq!(&argv[..3], ["grok", "--model", "grok-4.7-build-fast"]);
            assert_eq!(
                &argv[3..],
                ["--resume", "session", "-p", "literal --model text"]
            );
            // Off leaves the selected base model in the ordinary launch.
            let mut off = vec![
                "grok".into(),
                "--model".into(),
                "grok-4.7".into(),
                "-p".into(),
                "prompt".into(),
            ];
            apply("grok", model, false, &mut off).unwrap();
            assert_eq!(off[2], "grok-4.7");
        }
        assert!(apply_grok(Some("grok-4.6"), &catalog, &mut vec!["grok".into()]).is_err());
        assert!(apply_grok(None, &[], &mut vec!["grok".into()]).is_err());
        let mut literal = vec!["grok".into(), "-p".into(), "--model".into()];
        apply_grok(None, &catalog, &mut literal).unwrap();
        assert_eq!(
            literal,
            ["grok", "--model", "grok-4.7-build-fast", "-p", "--model"]
        );
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
