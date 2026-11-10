// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Device-local Home arrangement and a discardable editor draft.
//! Source: HomeLayout.swift and DesktopHomeEditor.swift (desktop branch).

use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum Section {
    #[serde(rename = "continue")]
    Continue,
    #[serde(rename = "pinned")]
    Pinned,
    #[serde(rename = "machines")]
    Machines,
    #[serde(rename = "usage")]
    Usage,
    #[serde(rename = "activity")]
    Activity,
    #[serde(rename = "limits")]
    Limits,
}
impl Section {
    pub const ALL: [Self; 6] = [
        Self::Continue,
        Self::Pinned,
        Self::Machines,
        Self::Usage,
        Self::Activity,
        Self::Limits,
    ];
    pub fn id(self) -> &'static str {
        match self {
            Self::Continue => "continue",
            Self::Pinned => "pinned",
            Self::Machines => "machines",
            Self::Usage => "usage",
            Self::Activity => "activity",
            Self::Limits => "limits",
        }
    }
    pub fn parse(value: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|s| s.id() == value)
    }
    pub fn label_key(self) -> &'static str {
        match self {
            Self::Continue => "apple.homelayout.continue.31fbef16",
            Self::Pinned => "apple.homelayout.pinned_work.23dd8f45",
            Self::Machines => "apple.homelayout.machines.c061da19",
            Self::Usage => "apple.homelayout.today_and_this_week.2cb0c4ae",
            Self::Activity => "apple.homelayout.activity.38da1505",
            Self::Limits => "apple.homelayout.plan_limits.925788cd",
        }
    }
    pub fn detail_key(self) -> &'static str {
        match self {
            Self::Continue => {
                "apple.homelayout.the_folders_and_conversations_you_were_las.611a8af7"
            }
            Self::Pinned => "apple.homelayout.shortcuts_to_the_folders_and_conversations.395d6781",
            Self::Machines => "apple.homelayout.which_of_your_machines_are_awake.59492064",
            Self::Usage => "apple.homelayout.what_today_and_this_week_came_to.e49c5c1c",
            Self::Activity => "apple.homelayout.the_year_a_square_a_day.a3daad88",
            Self::Limits => "apple.homelayout.how_much_of_each_tool_s_subscription_is_le.16c87cc1",
        }
    }
    pub fn symbol(self) -> &'static str {
        match self {
            Self::Continue => "arrow.uturn.backward.circle.fill",
            Self::Pinned => "pin.fill",
            Self::Machines => "desktopcomputer",
            Self::Usage => "sum",
            Self::Activity => "square.grid.3x3.fill",
            Self::Limits => "gauge.with.needle",
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Preset {
    Balanced,
    Work,
    Usage,
}
impl Preset {
    pub const ALL: [Self; 3] = [Self::Balanced, Self::Work, Self::Usage];
    pub fn id(self) -> &'static str {
        match self {
            Self::Balanced => "balanced",
            Self::Work => "work",
            Self::Usage => "usage",
        }
    }
    pub fn parse(s: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|p| p.id() == s)
    }
    pub fn label_key(self) -> &'static str {
        match self {
            Self::Balanced => "apple.homelayout.balanced.5386ea5d",
            Self::Work => "apple.homelayout.work_first.c3edce98",
            Self::Usage => "apple.homelayout.usage_first.007ee7e0",
        }
    }
    pub fn arrangement(self) -> Arrangement {
        use Section::*;
        let order = match self {
            Self::Balanced => vec![Continue, Pinned, Activity, Limits, Machines, Usage],
            Self::Work => vec![Continue, Pinned, Machines, Limits, Usage, Activity],
            Self::Usage => vec![Usage, Limits, Activity, Continue, Pinned, Machines],
        };
        Arrangement {
            order,
            hidden: if self == Self::Balanced {
                [Usage].into()
            } else {
                BTreeSet::new()
            },
            preset: Some(self),
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Arrangement {
    pub order: Vec<Section>,
    pub hidden: BTreeSet<Section>,
    pub preset: Option<Preset>,
}
impl Default for Arrangement {
    fn default() -> Self {
        Preset::Balanced.arrangement()
    }
}
impl Arrangement {
    pub fn normalized(
        order: Option<Vec<Section>>,
        hidden: impl IntoIterator<Item = Section>,
        preset: Option<Preset>,
    ) -> Self {
        let Some(stored) = order else {
            return Self::default();
        };
        let mut seen = BTreeSet::new();
        let mut order: Vec<_> = stored.into_iter().filter(|s| seen.insert(*s)).collect();
        order.extend(
            Preset::Balanced
                .arrangement()
                .order
                .into_iter()
                .filter(|s| !seen.contains(s)),
        );
        Self {
            hidden: hidden.into_iter().filter(|s| order.contains(s)).collect(),
            order,
            preset,
        }
    }
    pub fn visible(&self) -> Vec<Section> {
        self.order
            .iter()
            .copied()
            .filter(|s| !self.hidden.contains(s))
            .collect()
    }
    pub fn moved(items: &[Section], offsets: &[usize], destination: i64) -> Vec<Section> {
        let lifted: BTreeSet<_> = offsets
            .iter()
            .copied()
            .filter(|i| *i < items.len())
            .collect();
        if lifted.is_empty() {
            return items.to_vec();
        }
        let mut remaining: Vec<_> = items
            .iter()
            .enumerate()
            .filter(|(i, _)| !lifted.contains(i))
            .map(|(_, s)| *s)
            .collect();
        let ahead = lifted.iter().filter(|i| (**i as i64) < destination).count() as i64;
        let target = (destination.saturating_sub(ahead)).clamp(0, remaining.len() as i64) as usize;
        remaining.splice(target..target, lifted.into_iter().map(|i| items[i]));
        remaining
    }
    pub fn move_visible(&mut self, offsets: &[usize], destination: i64) {
        let visible = self.visible();
        let moved = Self::moved(&visible, offsets, destination);
        let mut moved = moved.into_iter();
        for section in &mut self.order {
            if !self.hidden.contains(section) {
                *section = moved.next().unwrap_or(*section)
            }
        }
        self.preset = None;
    }
}
#[derive(Clone, Debug)]
pub struct Editor {
    pub draft: Arrangement,
    pub before_reset: Option<Arrangement>,
    pub focused: Option<Section>,
    pub announcement: String,
    pub error: Option<String>,
}
impl Editor {
    pub fn new(arrangement: Arrangement) -> Self {
        Self {
            draft: arrangement,
            before_reset: None,
            focused: None,
            announcement: String::new(),
            error: None,
        }
    }
    pub fn preset(&mut self, preset: Preset) {
        self.draft = preset.arrangement();
        self.before_reset = None;
        self.announcement.clear();
    }
    pub fn toggle(&mut self, section: Section) {
        let was_visible = !self.draft.hidden.contains(&section);
        if was_visible {
            self.draft.hidden.insert(section);
        } else {
            self.draft.hidden.remove(&section);
        }
        self.draft.preset = None;
        self.before_reset = None;
        self.announcement = format!(
            "{} {}.",
            crate::localization::text(section.label_key(), &[]),
            crate::localization::text(
                if was_visible {
                    "apple.desktophomeeditor.hidden.e564b408"
                } else {
                    "apple.desktophomeeditor.shown.baaf5362"
                },
                &[]
            )
        );
    }
    pub fn shift(&mut self, section: Section, delta: i64) {
        let visible = self.draft.visible();
        let Some(index) = visible.iter().position(|s| *s == section) else {
            return;
        };
        let next = index as i64 + delta;
        if next < 0 || next >= visible.len() as i64 {
            return;
        }
        let a = self.draft.order.iter().position(|s| *s == section).unwrap();
        let b = self
            .draft
            .order
            .iter()
            .position(|s| *s == visible[next as usize])
            .unwrap();
        self.draft.order.swap(a, b);
        self.changed(section);
    }
    pub fn drag(&mut self, source: Section, target: Section) {
        let visible = self.draft.visible();
        let (Some(from), Some(to)) = (
            visible.iter().position(|s| *s == source),
            visible.iter().position(|s| *s == target),
        ) else {
            return;
        };
        if from == to {
            return;
        }
        self.draft
            .move_visible(&[from], if to > from { to as i64 + 1 } else { to as i64 });
        self.changed(source);
    }
    fn changed(&mut self, section: Section) {
        self.draft.preset = None;
        self.before_reset = None;
        self.focused = Some(section);
        let position = self
            .draft
            .visible()
            .iter()
            .position(|s| *s == section)
            .unwrap_or(0)
            + 1;
        self.announcement = crate::localization::text(
            "apple.desktophomeeditor.0_moved_to_position_1.4fa1daea",
            &[
                &crate::localization::text(section.label_key(), &[]),
                &position.to_string(),
            ],
        );
    }
    pub fn reset(&mut self) {
        self.before_reset = Some(self.draft.clone());
        self.draft = Arrangement::default();
        self.announcement = crate::localization::text(
            "apple.desktophomeeditor.balanced_arrangement_restored.f3e8a3f6",
            &[],
        );
    }
    pub fn undo_reset(&mut self) {
        if let Some(previous) = self.before_reset.take() {
            self.draft = previous;
            self.announcement = crate::localization::text(
                "apple.desktophomeeditor.previous_arrangement_restored.cc0d9cd0",
                &[],
            );
        }
    }
}

/// One GUI-only preference file; unrelated/future object fields survive edits.
#[derive(Clone)]
pub struct Storage {
    pub path: Option<PathBuf>,
}
impl Storage {
    pub fn load(&self) -> anyhow::Result<Arrangement> {
        let Some(path) = &self.path else {
            return Ok(Arrangement::default());
        };
        let value = read(path)?;
        anyhow::ensure!(
            value.is_object(),
            "The saved Home preferences are not a JSON object"
        );
        let strings = |name: &str| {
            value
                .get(name)
                .and_then(|v| v.as_array())
                .and_then(|a| a.iter().map(|v| v.as_str()).collect::<Option<Vec<_>>>())
        };
        let order = strings("order").map(|a| a.into_iter().filter_map(Section::parse).collect());
        Ok(Arrangement::normalized(
            order,
            strings("hidden")
                .unwrap_or_default()
                .into_iter()
                .filter_map(Section::parse),
            value
                .get("preset")
                .and_then(|p| p.as_str())
                .and_then(Preset::parse),
        ))
    }
    pub fn save(&self, arrangement: &Arrangement) -> anyhow::Result<()> {
        use std::io::Write;
        let Some(path) = &self.path else {
            return Ok(());
        };
        let mut value = read(path)?;
        let object = value
            .as_object_mut()
            .ok_or_else(|| anyhow::anyhow!("The saved Home preferences are not a JSON object"))?;
        object.insert("order".into(), serde_json::to_value(&arrangement.order)?);
        object.insert("hidden".into(), serde_json::to_value(&arrangement.hidden)?);
        object.insert("preset".into(), serde_json::to_value(arrangement.preset)?);
        let parent = path
            .parent()
            .ok_or_else(|| anyhow::anyhow!("Home preferences need a parent directory"))?;
        std::fs::create_dir_all(parent)?;
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let temporary = parent.join(format!(
            ".home-{}-{}.tmp",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        let result = (|| {
            let mut options = std::fs::OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options
                    .mode(0o600)
                    .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
            }
            let mut file = options.open(&temporary)?;
            file.write_all(&serde_json::to_vec_pretty(&value)?)?;
            file.write_all(b"\n")?;
            file.sync_all()?;
            std::fs::rename(&temporary, path)?;
            Ok::<_, anyhow::Error>(())
        })();
        if result.is_err() {
            let _ = std::fs::remove_file(temporary);
        }
        result
    }
}
fn read(path: &Path) -> anyhow::Result<serde_json::Value> {
    match std::fs::read(path) {
        Ok(bytes) => Ok(serde_json::from_slice(&bytes)?),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(serde_json::json!({})),
        Err(e) => Err(e.into()),
    }
}

#[cfg(test)]
#[path = "layout/tests.rs"]
mod tests;
