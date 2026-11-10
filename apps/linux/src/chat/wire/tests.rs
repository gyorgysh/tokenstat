// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use super::*;
use serde_json::json;

#[test]
fn future_and_malformed_events_do_not_empty_a_page_but_a_broken_page_envelope_is_not_an_empty_success()
 {
    let page: EventPage = serde_json::from_value(json!({"events":[{"kind":"user","text":"Kept","seq":1},null,{"kind":"future"},{"kind":"agent","event":{"kind":"text","delta":7}}],"nextOffset":24})).unwrap();
    assert_eq!(page.events.len(), 2);
    assert_eq!(page.events[0].text.as_deref(), Some("Kept"));
    assert_eq!(page.events[1].kind, "future");
    assert_eq!(page.next_offset, 24);
    for malformed in [
        json!({"events":{}}),
        json!({"events":[],"nextOffset":-1}),
        json!({"usage":{"input":1}}),
        json!({"reset":"yes"}),
    ] {
        assert!(serde_json::from_value::<EventPage>(malformed).is_err());
    }
}
#[test]
fn read_only_approvals_never_adopt_a_private_conversation_id_and_private_approvals_require_one() {
    for conversation in [json!(null), json!(7), json!("private")] {
        let value = json!({"id":"approval","conversationId":conversation,"readOnly":true,"verb":"Run","preview":"Synthetic","createdAtMs":0,"expiresAtMs":10});
        let approval: Approval = serde_json::from_value(value.clone()).unwrap();
        assert!(approval.conversation_id.is_empty());
        let mut private = value;
        private["readOnly"] = json!(false);
        assert_eq!(
            serde_json::from_value::<Approval>(private).is_ok(),
            conversation.is_string()
        );
    }
}
#[test]
fn legacy_fallbacks_are_lazy_and_tool_inputs_are_not_usage_counters() {
    let event: TimelineEvent=serde_json::from_value(json!({"kind":"agent","atMs":1,"at_ms":{},"event":{"kind":"tool","input":{"path":"fixture"},"costUsd":0.1,"cost_usd":{},"callId":"current","call_id":false,"cacheRead":{},"cache_read":3.9,"output":7.75}})).unwrap();
    assert_eq!(event.at_ms, Some(1));
    let agent = event.event.unwrap();
    assert!(agent.input.is_none());
    assert_eq!(agent.output, Some(7));
    assert_eq!(agent.cache_read, Some(3));
    assert_eq!(agent.call_id.as_deref(), Some("current"));
    assert!(
        serde_json::from_value::<TimelineEvent>(json!({"kind":"user","atMs":{},"at_ms":1}))
            .is_err()
    );
}
#[test]
fn revisions_positions_and_permissions_are_strict_while_integral_spellings_and_maximum_revisions_survive()
 {
    let chat: super::super::Conversation=serde_json::from_value(json!({"id":"thread","workspaceId":"folder","title":"Synthetic","backend":"fixture","sendRevision":u64::MAX,"createdAtMs":1.0})).unwrap();
    assert_eq!(chat.send_revision, Some(u64::MAX));
    assert_eq!(chat.created_at_ms, 1);
    for invalid in [json!(-1), json!(0.5), json!("1"), json!(true)] {
        assert!(
            serde_json::from_value::<TimelineEvent>(json!({"kind":"user","seq":invalid})).is_err()
        );
    }
    let mut invalid = serde_json::to_value(chat).unwrap();
    invalid["allowedTools"] = json!(["Read", 7]);
    assert!(serde_json::from_value::<super::super::Conversation>(invalid).is_err());
}
