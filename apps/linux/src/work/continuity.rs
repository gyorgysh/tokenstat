// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! WorkContinuityStore and WorkPlace use the source Codable envelope shapes.

use super::{Kind, Reference, Scope, destination, preferences::Preferences, text};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

const VISITS: &str = "work.continuity.v1";
const PLACE: &str = "work.place.v1";

/// Codable Date is seconds since 2001-01-01. Reject nonfinite writes rather
/// than silently encoding null, which JSONEncoder would not do.
#[derive(Clone, Copy, Debug, PartialEq, Deserialize)]
#[serde(transparent)]
pub struct Date(pub f64);
impl Serialize for Date {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        if !self.0.is_finite() {
            return Err(serde::ser::Error::custom(
                "A saved work date must be finite",
            ));
        }
        serializer.serialize_f64(self.0)
    }
}
impl Date {
    /// Host/UI clocks use Unix milliseconds; storage keeps Swift's epoch.
    pub fn from_unix_ms(ms: i64) -> Self {
        Self(ms as f64 / 1000. - 978_307_200.)
    }
}

/// Exactly one global or workspace shape may be restored at launch.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Place {
    pub global_section: Option<String>,
    pub folder: Option<Reference>,
    pub folder_section: Option<String>,
    pub saved_at: Date,
}
impl Place {
    /// Globals retain the source raw section, including future values.
    pub fn global(section: impl Into<String>, at: Date) -> Self {
        Self {
            global_section: Some(section.into()),
            folder: None,
            folder_section: None,
            saved_at: at,
        }
    }
    /// A workspace place keeps host-owned identifiers, not a shell route string.
    pub fn workspace(folder: Reference, section: String, at: Date) -> Option<Self> {
        let place = Self {
            global_section: None,
            folder: Some(folder),
            folder_section: Some(section),
            saved_at: at,
        };
        place.is_well_formed().then_some(place)
    }
    /// Partial or conflicting shapes never become a launch destination.
    pub fn is_well_formed(&self) -> bool {
        if let Some(section) = &self.global_section {
            return !section.is_empty() && self.folder.is_none() && self.folder_section.is_none();
        }
        match (&self.folder, &self.folder_section) {
            (Some(folder), Some(section)) => {
                folder.kind == Kind::Workspace
                    && !folder.host_identity.is_empty()
                    && !folder.workspace_id.is_empty()
                    && !section.is_empty()
            }
            _ => false,
        }
    }
}

/// Restore only a folder still present in the authoritative directory.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Destination {
    Global { section: String },
    Workspace { folder: String, section: String },
}

/// Local registrations may reopen before account verification. Remote work
/// still requires the exact account scope that recorded it.
pub fn restore(
    place: Option<&Place>,
    ids: &[String],
    scope: Option<&Scope>,
    local: Option<&str>,
) -> Option<Destination> {
    let place = place.filter(|p| p.is_well_formed())?;
    if let Some(section) = &place.global_section {
        return Some(Destination::Global {
            section: section.clone(),
        });
    }
    let folder = place.folder.as_ref()?;
    let id = destination::folder_id(folder, ids.iter().map(String::as_str), local)?;
    if destination::route(id, None).peer.is_some() && scope != Some(&folder.scope) {
        return None;
    }
    Some(Destination::Workspace {
        folder: id.into(),
        section: place.folder_section.clone()?,
    })
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Visit {
    reference: Reference,
    opened_at: Date,
}
#[derive(Serialize, Deserialize)]
struct Envelope {
    #[serde(deserialize_with = "version")]
    version: u32,
    visits: Vec<Visit>,
}
#[derive(Serialize, Deserialize)]
struct PlaceEnvelope {
    #[serde(deserialize_with = "version")]
    version: u32,
    place: Place,
}

fn version<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<u32, D::Error> {
    // JSONDecoder accepts an integral JSON number such as 1.0 for Int.
    let value = Value::deserialize(deserializer)?;
    Ok(u32::from(value.as_f64() == Some(1.)))
}

/// Each operation reads current storage, so another window's visits survive.
#[derive(Clone, Default)]
pub struct Continuity {
    pub preferences: Preferences,
}
impl Continuity {
    /// Newest first, limited globally before filtering by scope, like Swift.
    pub fn recent(&self, scope: &Scope, limit: i64) -> anyhow::Result<Vec<Reference>> {
        self.preferences.read(|map| {
            read_visits(map)
                .into_iter()
                .filter(|v| v.reference.scope == *scope)
                .take(limit.max(0) as usize)
                .map(|v| v.reference)
                .collect()
        })
    }
    /// One remembered conversation per folder and account, across all hosts.
    pub fn remember(&self, reference: &Reference, at: Date) -> anyhow::Result<()> {
        if reference.kind != Kind::Conversation
            || reference.item_id.as_ref().is_none_or(|s| s.is_empty())
            || reference.host_identity.is_empty()
            || reference.workspace_id.is_empty()
        {
            return Ok(());
        }
        self.preferences.update(|map| {
            let mut visits = read_visits(map);
            visits.retain(|v| !same_folder(&v.reference, reference));
            visits.insert(
                0,
                Visit {
                    reference: reference.clone(),
                    opened_at: at,
                },
            );
            visits.truncate(100);
            if let Ok(data) = serde_json::to_string(&Envelope { version: 1, visits }) {
                map.insert(VISITS.into(), Value::String(data));
            }
            Ok(())
        })
    }
    /// Forgetting a folder leaves every other host/folder/account intact.
    pub fn forget(&self, scope: &Scope, host: &str, workspace: &str) -> anyhow::Result<()> {
        self.preferences.update(|map| {
            let visits = read_visits(map)
                .into_iter()
                .filter(|v| {
                    !(v.reference.scope == *scope
                        && text::equal(&v.reference.host_identity, host)
                        && text::equal(&v.reference.workspace_id, workspace))
                })
                .collect();
            map.insert(
                VISITS.into(),
                Value::String(serde_json::to_string(&Envelope { version: 1, visits })?),
            );
            Ok(())
        })
    }
    /// Removing an account retires its workspace place too, but keeps globals.
    pub fn remove(&self, scope: &Scope) -> anyhow::Result<()> {
        self.preferences.update(|map| {
            let visits = read_visits(map)
                .into_iter()
                .filter(|v| v.reference.scope != *scope)
                .collect();
            map.insert(
                VISITS.into(),
                Value::String(serde_json::to_string(&Envelope { version: 1, visits })?),
            );
            if read_place(map)
                .and_then(|p| p.folder)
                .is_some_and(|f| f.scope == *scope)
            {
                map.remove(PLACE);
            }
            Ok(())
        })
    }
    /// The last conversation is specific to both host and raw workspace id.
    pub fn last(
        &self,
        scope: &Scope,
        host: &str,
        workspace: &str,
    ) -> anyhow::Result<Option<Reference>> {
        self.preferences.read(|map| {
            read_visits(map)
                .into_iter()
                .find(|v| {
                    v.reference.scope == *scope
                        && text::equal(&v.reference.host_identity, host)
                        && text::equal(&v.reference.workspace_id, workspace)
                        && v.reference.kind == Kind::Conversation
                })
                .map(|v| v.reference)
        })
    }
    /// A malformed/nonfinite replacement does not erase the previous place.
    pub fn remember_place(&self, place: &Place) -> anyhow::Result<()> {
        if !place.is_well_formed() {
            return Ok(());
        }
        let Ok(data) = serde_json::to_string(&PlaceEnvelope {
            version: 1,
            place: place.clone(),
        }) else {
            return Ok(());
        };
        self.preferences.update(|map| {
            map.insert(PLACE.into(), Value::String(data));
            Ok(())
        })
    }
    /// Read at most 32KiB and accept only a well-formed version-one place.
    pub fn place(&self) -> anyhow::Result<Option<Place>> {
        self.preferences.read(read_place)
    }
    /// Explicitly leaving restorable routes clears the single place record.
    pub fn forget_place(&self) -> anyhow::Result<()> {
        self.preferences.update(|map| {
            map.remove(PLACE);
            Ok(())
        })
    }
}
fn same_folder(a: &Reference, b: &Reference) -> bool {
    a.scope == b.scope
        && text::equal(&a.host_identity, &b.host_identity)
        && text::equal(&a.workspace_id, &b.workspace_id)
}
fn read_visits(map: &Map<String, Value>) -> Vec<Visit> {
    let Some(data) = map
        .get(VISITS)
        .and_then(Value::as_str)
        .filter(|s| s.len() <= 256 * 1024)
    else {
        return vec![];
    };
    let Ok(mut envelope) = serde_json::from_str::<Envelope>(data) else {
        return vec![];
    };
    if envelope.version != 1 {
        return vec![];
    }
    envelope.visits.sort_by(|a, b| {
        b.opened_at
            .0
            .partial_cmp(&a.opened_at.0)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    envelope.visits.truncate(100);
    envelope.visits
}
fn read_place(map: &Map<String, Value>) -> Option<Place> {
    let data = map.get(PLACE)?.as_str().filter(|s| s.len() <= 32 * 1024)?;
    let envelope: PlaceEnvelope = serde_json::from_str(data).ok()?;
    (envelope.version == 1 && envelope.place.is_well_formed()).then_some(envelope.place)
}
