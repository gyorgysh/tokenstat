// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use fold::Detail;
use serde_json::{Value, json};

fn rows(events: Value, running: bool) -> Vec<Row> {
    coalesce(
        &serde_json::from_value::<Vec<crate::chat::wire::TimelineEvent>>(events).unwrap(),
        Some("codex"),
        running,
    )
}
fn agent(kind: &str, fields: Value) -> Value {
    let mut event = fields;
    event["kind"] = json!(kind);
    json!({"kind":"agent","event":event})
}
fn tool_rows(rows: &[Row]) -> Vec<&Tool> {
    rows.iter()
        .filter_map(|r| {
            if let Kind::Tool { state } = &r.kind {
                Some(state)
            } else {
                None
            }
        })
        .collect()
}
fn group(rows: &[Row]) -> &StepGroup {
    rows.iter()
        .find_map(|r| {
            if let Kind::Group { group } = &r.kind {
                Some(group)
            } else {
                None
            }
        })
        .unwrap()
}

#[test]
fn reused_call_ids_close_in_start_order_and_keep_each_original_provider_after_reconstruction() {
    let rows = rows(
        json!([
            {"kind":"agent","backend":"muse","seq":1,"event":{"kind":"toolStart","callId":"shared","verb":"Bash Input"}},
            {"kind":"agent","backend":"codex","seq":2,"event":{"kind":"toolStart","callId":"shared","verb":"Read","target":"two.rs"}},
            {"kind":"agent","backend":"codex","seq":3,"event":{"kind":"toolEnd","callId":"shared","detail":"{\"command\":\"cargo test\"}"}},
            {"kind":"agent","backend":"claude","seq":4,"event":{"kind":"toolEnd","callId":"shared","detail":"Read output","ok":false}}
        ]),
        true,
    );
    let tools = tool_rows(&rows);
    assert_eq!(tools[0].verb, "Bash");
    assert_eq!(tools[0].target, "cargo test");
    assert!(!tools[0].running && !tools[0].failed);
    assert_eq!(tools[1].target, "two.rs");
    assert!(!tools[1].running && tools[1].failed);
    let sources = rows
        .iter()
        .filter(|r| matches!(r.kind, Kind::Tool { .. }))
        .map(|r| r.source_backend.as_deref())
        .collect::<Vec<_>>();
    assert_eq!(sources, [Some("muse"), Some("codex")]);
}
#[test]
fn archive_positions_preserve_tool_and_prose_anchors_when_an_older_page_is_prepended() {
    let tail = json!([
        {"kind":"agent","seq":20,"event":{"kind":"toolStart","callId":"tool","verb":"Read"}},
        {"kind":"agent","seq":21,"event":{"kind":"toolEnd","callId":"tool"}},
        {"kind":"agent","seq":22,"event":{"kind":"text","delta":"A reply"}}
    ]);
    let before = rows(tail.clone(), false);
    let mut events = vec![
        json!({"kind":"agent","seq":1,"event":{"kind":"toolStart","callId":"tool","verb":"Read"}}),
        json!({"kind":"agent","seq":2,"event":{"kind":"toolEnd","callId":"tool"}}),
    ];
    events.extend(tail.as_array().unwrap().clone());
    let after = rows(json!(events), false);
    for row in before {
        assert!(after.iter().any(|r| r == &row));
    }
    assert_eq!(after.last().unwrap().id, "text-s22");
}
#[test]
fn edit_events_replace_their_start_and_completed_patch_without_duplicate_cards_or_losing_provenance()
 {
    let rows = rows(
        json!([
            {"kind":"agent","seq":1,"event":{"kind":"toolStart","callId":"edit","verb":"Edit","target":"a.rs"}},
            {"kind":"agent","seq":2,"event":{"kind":"edit","callId":"edit","path":"a.rs","patch":"--- a/file\n+++ b/file\n-old\n+new"}},
            {"kind":"agent","seq":3,"event":{"kind":"toolEnd","callId":"edit","detail":"must not replace patch"}},
            {"kind":"agent","seq":4,"event":{"kind":"edit","callId":"edit","path":"a.rs","added":3}}
        ]),
        false,
    );
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].id, "tool-s1");
    let Kind::Edit { state } = &rows[0].kind else {
        panic!("expected edit")
    };
    assert_eq!((state.added, state.removed, state.revision), (3, 1, 1));
    assert!(state.patch.contains("+new"));
    assert!(!state.running);
    assert_eq!(rows[0].source_backend.as_deref(), Some("codex"));
}
#[test]
fn steer_keeps_a_live_tool_and_edit_revision_while_a_new_user_turn_closes_it() {
    let start = agent(
        "toolStart",
        json!({"callId":"edit","verb":"Edit","target":"a.rs"}),
    );
    let mut events = vec![
        start,
        json!({"kind":"user","text":"Also tests","steer":true}),
    ];
    let live = rows(json!(events), true);
    assert!(matches!(&live[0].kind,Kind::Edit{state} if state.running));
    assert!(live[1].is_steer);
    events.push(json!({"kind":"user","atMs":1000,"text":"New turn"}));
    let closed = rows(json!(events), true);
    assert!(
        matches!(&closed[0].kind,Kind::Edit{state} if !state.running&&state.ended_at_ms==Some(1000))
    );
}
#[test]
fn answered_and_withdrawn_questions_update_the_existing_card_and_rejected_json_stays_readable() {
    let events = json!([
        {"kind":"question","id":"q","question":"Choose?","options":["A","B"]},
        {"kind":"answer","questionId":"q","text":"A","delivery":"queued"},
        {"kind":"answerWithdrawn","questionId":"q"}
    ]);
    let rows = rows(events, false);
    assert_eq!(rows.len(), 1);
    assert!(
        matches!(&rows[0].kind,Kind::Question{question} if question.answer.is_none()&&question.delivery.is_none()&&question.blocking)
    );
    let pending = "Before\n```tokenstat-question\n{\"question\":\"Unfinished";
    assert_eq!(question::stripping(pending, true), "Before");
    assert_eq!(question::stripping(pending, false), pending);
    let invalid = "```tokenstat-question\n{\"question\":7}\n```";
    assert_eq!(question::stripping(invalid, true), invalid);
}
#[test]
fn bounded_snippets_keep_full_copyable_detail_and_do_not_color_headers_or_shell_traces_as_edits() {
    let detail = format!(
        "--- a/file\n+++ b/file\n-old\n+new\n{}\n{}",
        "x".repeat(40000),
        "line\n".repeat(70)
    );
    let rows = rows(
        json!([agent("toolEnd", json!({"verb":"Diff","detail":detail}))]),
        false,
    );
    let state = tool_rows(&rows)[0];
    assert_eq!(state.detail.as_deref(), Some(detail.as_str()));
    assert_eq!(state.snippet.len(), 61);
    assert_eq!(state.snippet[0], "| --- a/file");
    assert_eq!(state.snippet[2], "-old");
    assert!(state.snippet[4].chars().count() <= 603);
    assert_eq!(tool::snippet("Bash", Some("+ set -x")), ["| + set -x"]);
    assert!(!tool::is_diff_line("+́combining"));
    let clipped = tool::clip(&format!("x{}", "́".repeat(5000)));
    assert!(clipped.ends_with('…'));
    assert!(clipped.chars().count() <= 2401);
}
#[test]
fn images_need_explicit_matching_tool_provenance_and_a_real_user_turn_resets_the_link() {
    let raw = rows(
        json!([
            agent("toolStart",json!({"callId":"read","verb":"Read"})),agent("toolEnd",json!({"callId":"read"})),
            agent("attachment",json!({"id":"one","mediaType":"image/png","callId":"read"})),
            {"kind":"user","text":"Steer","steer":true},agent("attachment",json!({"id":"two","mediaType":"image/png","callId":"read"})),
            {"kind":"user","text":"New turn"},agent("attachment",json!({"id":"three","mediaType":"image/png","callId":"read"}))
        ]),
        false,
    );
    let prepared = images::prepare(&raw);
    assert_eq!(
        prepared[0]
            .image_attachments
            .iter()
            .map(|a| a.id.as_str())
            .collect::<Vec<_>>(),
        ["one", "two"]
    );
    assert_eq!(images::row_id("attachment-one", &prepared), prepared[0].id);
    assert!(prepared.iter().any(|r| r.id == "attachment-three"));
    assert!(
        !prepared[0]
            .image_attachments
            .iter()
            .any(|a| a.id == "three")
    );
}
#[test]
fn detail_groups_retain_stable_owners_and_open_members_use_the_original_plain_step_style() {
    let raw = rows(
        json!([
            agent(
                "toolEnd",
                json!({"callId":"one","verb":"Read","target":"a.rs"})
            ),
            agent(
                "toolEnd",
                json!({"callId":"two","verb":"Search","target":"needle"})
            )
        ]),
        false,
    );
    let closed = fold::fold(&raw, Detail::Compact, false, |_| false);
    let header = &closed[0];
    assert_eq!(fold::owner(&raw[1].id, &closed), Some(header.id.clone()));
    assert_eq!(group(&closed).steps, 2);
    let open = fold::fold(&raw, Detail::Compact, false, |_| true);
    assert_eq!(open[0].id, header.id);
    assert!(fold::owner(&raw[1].id, &open).is_none());
    assert_eq!(open[1].group_id.as_deref(), Some(header.id.as_str()));
    assert_eq!(open[1].plain_step, Some(PlainStep::Line));
}
#[test]
fn minimal_usage_saturates_counts_and_missing_cost_cannot_become_an_invented_positive_charge() {
    let raw = rows(
        json!([
            agent("usage", json!({"input":u64::MAX,"output":1,"costUsd":0.25})),
            agent("usage", json!({"input":10,"output":2}))
        ]),
        false,
    );
    let folded = fold::fold(&raw, Detail::Minimal, false, |_| false);
    assert_eq!(folded.len(), 1);
    assert!(matches!(
        folded[0].kind,
        Kind::Usage {
            input: u64::MAX,
            output: 3,
            cost: None
        }
    ));
}
#[test]
fn turn_changes_keep_closed_edits_and_coalesce_canonical_paths_without_drawing_the_live_turns_card()
{
    let raw = rows(
        json!([{ "kind":"user","text":"Question"},agent("edit",json!({"path":"café.rs","added":1})),agent("edit",json!({"path":"cafe\u{301}.rs","added":2}))]),
        false,
    );
    let finished = fold::fold(&raw, Detail::Minimal, false, |_| false);
    let changes = finished
        .iter()
        .find_map(|r| {
            if let Kind::Changes { changes } = &r.kind {
                Some(changes)
            } else {
                None
            }
        })
        .unwrap();
    assert_eq!(changes.files.len(), 1);
    assert_eq!(changes.files[0].added, 3);
    assert_eq!(changes.files[0].patches.len(), 2);
    assert!(
        !fold::fold(&raw, Detail::Minimal, true, |_| false)
            .iter()
            .any(|r| matches!(r.kind, Kind::Changes { .. }))
    );
}
#[test]
fn minimal_activity_keeps_a_long_running_call_ahead_of_many_finished_steps() {
    let mut events = vec![agent(
        "toolStart",
        json!({"callId":"long","verb":"Bash","target":"sleep"}),
    )];
    for n in 0..6 {
        events.push(agent(
            "toolEnd",
            json!({"callId":n.to_string(),"verb":"Read","target":n.to_string()}),
        ));
    }
    let raw = rows(json!(events), true);
    let folded = fold::fold(&raw, Detail::Minimal, true, |_| false);
    let group = group(&folded);
    assert_eq!(group.recent_activity.len(), 3);
    assert!(
        group
            .activity_preview()
            .iter()
            .any(|a| a.running && a.target == "sleep")
    );
}
#[test]
fn sign_in_recovery_uses_only_prompt_attachments_and_never_a_tools_unrelated_auth_error() {
    let raw = rows(
        json!([{ "kind":"user","text":"Synthetic retry"},agent("attachment",json!({"id":"user","mediaType":"image/png"})),
        agent("text",json!({"delta":"Not logged in · Please run /login"})),agent("usage",json!({"input":0,"output":0})),
        agent("failed",json!({"text":"Claude Code is not signed in on this computer."})),agent("attachment",json!({"id":"agent","mediaType":"image/png"}))]),
        false,
    );
    let recovery = auth::latest_recovery(&raw, "claude").unwrap();
    assert_eq!(recovery.attachments.len(), 1);
    assert_eq!(recovery.attachments[0].id, "user");
    assert!(auth::latest_recovery(&raw, "codex").is_none());
    assert!(!auth::needs_sign_in(
        "GitHub authentication required",
        "cursor"
    ));
    let shown = auth::presented(&raw);
    assert!(!shown.iter().any(|r| matches!(r.kind, Kind::Usage { .. })));
}
#[test]
fn complete_row_equality_preserves_canonical_strings_and_detects_meaningful_nested_changes() {
    let a = rows(
        json!([agent(
            "toolEnd",
            json!({"callId":"café","verb":"Read","target":"café.rs","detail":"café"})
        )]),
        false,
    );
    let mut b = rows(
        json!([agent(
            "toolEnd",
            json!({"callId":"cafe\u{301}","verb":"Read","target":"cafe\u{301}.rs","detail":"cafe\u{301}"})
        )]),
        false,
    );
    assert_eq!(a, b);
    assert_eq!(
        fold::fold(&a, Detail::Minimal, false, |_| false),
        fold::fold(&b, Detail::Minimal, false, |_| false)
    );
    if let Kind::Tool { state } = &mut b[0].kind {
        state.failed = true;
    }
    assert_ne!(a, b);
}
