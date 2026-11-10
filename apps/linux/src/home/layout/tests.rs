// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;

#[test]
fn cancel_is_discardable_and_reset_undo_restores_the_entire_draft() {
    let saved = Arrangement::default();
    let mut editor = Editor::new(saved.clone());
    editor.preset(Preset::Usage);
    editor.toggle(Section::Pinned);
    editor.shift(Section::Activity, -1);
    let changed = editor.draft.clone();
    editor.reset();
    assert_eq!(editor.draft, saved);
    editor.undo_reset();
    assert_eq!(editor.draft, changed);
    assert!(editor.before_reset.is_none());
    editor.reset();
    editor.toggle(Section::Activity);
    editor.undo_reset();
    assert!(editor.draft.hidden.contains(&Section::Activity));
    drop(editor); // Closing the working copy does not mutate the saved value.
    assert_eq!(saved, Arrangement::default());
}

#[test]
fn all_cards_can_be_hidden_and_reordering_keeps_the_hidden_slots() {
    let mut editor = Editor::new(Arrangement::default());
    let hidden_slot = editor
        .draft
        .order
        .iter()
        .position(|s| *s == Section::Usage)
        .unwrap();
    editor.drag(Section::Continue, Section::Machines);
    assert_eq!(editor.draft.order[hidden_slot], Section::Usage);
    assert_eq!(editor.draft.visible().last(), Some(&Section::Continue));
    editor.shift(Section::Continue, -1);
    assert_eq!(editor.focused, Some(Section::Continue));
    let order = editor.draft.order.clone();
    editor.shift(Section::Usage, -1); // Hidden rows cannot move in the visible list.
    assert_eq!(editor.draft.order, order);
    for section in editor.draft.visible() {
        editor.toggle(section);
    }
    assert!(editor.draft.visible().is_empty());
    editor.toggle(Section::Activity);
    assert_eq!(editor.draft.visible(), [Section::Activity]);
}

#[test]
fn preferences_round_trip_atomically_and_preserve_future_fields() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("desktop-home.json");
    std::fs::write(&path, r#"{"future":{"name":"keep"},"order":["usage","future","usage"],"hidden":["machines"],"preset":null}"#).unwrap();
    let storage = Storage {
        path: Some(path.clone()),
    };
    let loaded = storage.load().unwrap();
    assert_eq!(loaded.order[0], Section::Usage);
    assert_eq!(loaded.order.len(), 6);
    assert!(loaded.hidden.contains(&Section::Machines));
    let mut editor = Editor::new(loaded);
    editor.preset(Preset::Work);
    editor.toggle(Section::Limits);
    storage.save(&editor.draft).unwrap();
    assert_eq!(storage.load().unwrap(), editor.draft);
    let json: serde_json::Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(json["future"]["name"], "keep");
    assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 1);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
}

#[test]
fn malformed_preferences_are_reported_and_never_replaced() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("home.json");
    let storage = Storage {
        path: Some(path.clone()),
    };
    for content in ["{broken", "[]", "null", "42"] {
        std::fs::write(&path, content).unwrap();
        assert!(storage.load().is_err());
        assert!(storage.save(&Arrangement::default()).is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), content);
        assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 1);
    }
    std::fs::write(&path, r#"{"hidden":["activity"]}"#).unwrap();
    assert_eq!(storage.load().unwrap(), Arrangement::default());
}
