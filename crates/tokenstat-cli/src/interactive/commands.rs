/// One slash command the prompt can run or complete.
pub(super) struct CommandDef {
    pub(super) name: &'static str,
    pub(super) aliases: &'static [&'static str],
    pub(super) about: &'static str,
}

pub(super) const COMMANDS: &[CommandDef] = &[
    // Account and data lifecycle first. Tabs are reachable with the 1-9 keys
    // and the arrow keys, so the palette's top rows belong to the commands a
    // user comes looking for: linking, syncing, scanning, fetching.
    CommandDef {
        name: "setup",
        aliases: &["start", "onboard"],
        about: "Getting started: scan local logs, then link tokenstat.ai",
    },
    CommandDef {
        name: "scan",
        aliases: &[],
        about: "Read new data into the archive",
    },
    CommandDef {
        name: "login",
        aliases: &[],
        about: "Link this machine to tokenstat.ai (device login wizard)",
    },
    CommandDef {
        name: "sync",
        aliases: &[],
        about: "Upload sealed aggregates to tokenstat.ai",
    },
    CommandDef {
        name: "logout",
        aliases: &[],
        about: "Forget the tokenstat.ai sync token for a host",
    },
    CommandDef {
        name: "fetch",
        aliases: &[],
        about: "Fetch Cursor/Antigravity usage (shell: tokenstat fetch)",
    },
    CommandDef {
        name: "auth",
        aliases: &[],
        about: "Vendor tokens: auth cursor|antigravity (auto keychain)",
    },
    CommandDef {
        name: "filter",
        aliases: &["f"],
        about: "Filter tabs: --model --project --since --until --last N · clear",
    },
    CommandDef {
        name: "budget",
        aliases: &[],
        about: "Show list-rate budget status (set via tokenstat budget)",
    },
    // Tabs. Keep the same order as the number keys so muscle memory carries.
    CommandDef {
        name: "summary",
        aliases: &["overview", "s"],
        about: "Headline stats and activity grid",
    },
    CommandDef {
        name: "daily",
        aliases: &["d"],
        about: "Usage per day",
    },
    CommandDef {
        name: "weekly",
        aliases: &["w"],
        about: "Usage per ISO week",
    },
    CommandDef {
        name: "monthly",
        aliases: &["m"],
        about: "Usage per month",
    },
    CommandDef {
        name: "models",
        aliases: &[],
        about: "Usage per model",
    },
    CommandDef {
        name: "projects",
        aliases: &["p"],
        about: "Usage per project",
    },
    CommandDef {
        name: "sessions",
        aliases: &[],
        about: "Busiest sessions",
    },
    CommandDef {
        name: "blocks",
        aliases: &["b"],
        about: "Five-hour usage windows",
    },
    CommandDef {
        name: "doctor",
        aliases: &[],
        about: "Archive health check",
    },
    CommandDef {
        name: "heatmap",
        aliases: &[],
        about: "Activity heatmap (also: tokenstat heatmap)",
    },
    CommandDef {
        name: "wrapped",
        aliases: &[],
        about: "Year-in-review (also: tokenstat wrapped)",
    },
    CommandDef {
        name: "sort",
        aliases: &[],
        about: "Toggle newest/oldest first on Daily and Monthly",
    },
    CommandDef {
        name: "export",
        aliases: &[],
        about: "Export is a one-shot CLI command (tokenstat export)",
    },
    CommandDef {
        name: "help",
        aliases: &["h", "?"],
        about: "List available commands",
    },
    CommandDef {
        name: "quit",
        aliases: &["exit", "q"],
        about: "Leave the interactive client",
    },
];
