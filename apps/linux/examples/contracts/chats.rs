// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use serde_json::{Value, json};
use tokenstat_linux::{
    chat::{Conversation, directory::Presentation, history, menu},
    commands::EntryKind,
};

fn row(id: &str) -> Conversation {
    serde_json::from_value(
        json!({"id":id,"workspaceId":"folder","title":"Conversation","backend":"codex"}),
    )
    .unwrap()
}
pub fn snapshot() -> Value {
    let mut windows = Vec::new();
    let mut loops = Vec::new();
    for count in [0, 1, 4, 5, 6, 9, 10, 11, 15, 33] {
        for selected in [
            None,
            Some(-1),
            Some(0),
            Some(4),
            Some(5),
            Some(9),
            Some(10),
            Some(16),
            Some(count - 1),
            Some(count),
            Some(count + 1),
        ] {
            let current = selected.and_then(|v| usize::try_from(v).ok());
            for expanded in [false, true] {
                let range = history::visible(count as usize, current, expanded);
                windows.push(json!({"count":count,"selected":selected,"expanded":expanded,"range":[range.start,range.end]}));
            }
            for step in [-2, -1, 0, 1, 2] {
                loops.push(json!({"count":count,"current":selected,"step":step,"next":history::looped(count as usize,current,step)}));
            }
        }
    }
    let mut orders = Vec::new();
    for ids in [
        vec!["a", "b", "c"],
        vec!["new", "b", "a"],
        vec!["e\u{301}", "a", "é"],
        vec!["b", "b", "a"],
    ] {
        let rows = ids.iter().map(|id| row(id)).collect::<Vec<_>>();
        for held in [
            None,
            Some(vec![]),
            Some(vec!["a", "b", "a"]),
            Some(vec!["é", "a"]),
            Some(vec!["missing", "c", "b"]),
        ] {
            let held = held.map(|held| held.iter().map(|id| id.to_string()).collect::<Vec<_>>());
            orders.push(json!({"ids":ids,"held":held,"ordered":history::holding_order(&rows,held.as_deref()).iter().map(|row|row.id.clone()).collect::<Vec<_>>()}));
        }
    }
    let mut menus = Vec::new();
    for bits in 0..32 {
        for count in [0, 7, 8, 9] {
            let state = menu::State {
                shared: bits & 1 != 0,
                running: bits & 2 != 0,
                copying: bits & 4 != 0,
                reference: bits & 8 != 0,
                pinned: bits & 16 != 0,
                pin_count: count,
            };
            let entries=menu::items(&state).iter().map(|entry|json!({"kind":match entry.kind {EntryKind::Action=>"action",EntryKind::Separator=>"separator",EntryKind::Heading=>"heading"},"title":entry.title,"enabled":entry.enabled,"selected":entry.selected,"symbol":entry.icon.map(|icon|icon.symbol()),"destructive":entry.destructive})).collect::<Vec<_>>();
            menus.push(json!({"state":state,"entries":entries}));
        }
    }
    let presentation=(0..16).map(|bits|json!({"content":bits&1!=0,"loaded":bits&2!=0,"loading":bits&4!=0,"error":bits&8!=0,"result":Presentation::resolve(bits&1!=0,bits&2!=0,bits&4!=0,bits&8!=0)})).collect::<Vec<_>>();
    let now = 1_700_000_000_000_i64;
    let ages = [
        -1,
        0,
        1,
        now + 1000,
        now,
        now - 59999,
        now - 60000,
        now - 3599999,
        now - 3600000,
        now - 86399999,
        now - 86400000,
        now - 86400000 * 14 + 1,
        now - 86400000 * 14,
        now - 86400000 * 365 + 1,
        now - 86400000 * 365,
        now - 86400000 * 730,
    ]
    .map(|ms| json!({"ms":ms,"now":now,"label":history::age(ms,now)}));
    let timers = [
        -1000, 0, 999, 1000, 59999, 60000, 3599999, 3600000, 3900000, 7200000,
    ]
    .map(
        |elapsed| json!({"start":now-elapsed,"now":now,"label":history::elapsed(now-elapsed,now)}),
    );
    let mut untouched = Vec::new();
    for title in ["New chat", "", "New Chat", "A conversation"] {
        for messaged in [false, true] {
            for running in [false, true] {
                for draft in [false, true] {
                    for selected in [false, true] {
                        let mut conversation = row("one");
                        conversation.title = title.into();
                        conversation.last_message_at_ms = messaged.then_some(0);
                        conversation.running = running;
                        untouched.push(json!({"conversation":conversation,"draft":draft,"selected":selected,"unused":conversation.unused(Some(draft)),"shown":history::shown(&conversation,selected.then_some("one"),Some(draft))}));
                    }
                }
            }
        }
    }
    let mut wires = Vec::new();
    let base = json!({"id":"one","workspaceId":"folder","title":"","backend":"codex"});
    for (key, value) in [
        ("pull", json!({"future":1})),
        (
            "pull",
            json!({"number":7,"title":"PR","url":"https://fixture.invalid/7","state":"open","draft":false,"baseRef":"main"}),
        ),
        ("teamShare", json!({"id":"publication"})),
        ("teamShare", json!({})),
        ("running", Value::Null),
        ("running", json!("yes")),
        ("updatedAtMs", Value::Null),
        ("lastMessageAtMs", json!(0)),
        ("id", json!(1)),
    ] {
        let mut input = base.clone();
        input[key] = value;
        let result = serde_json::from_value::<Conversation>(input.clone());
        let output=result.ok().map(|row|json!({"id":row.id,"workspace":row.workspace_id,"title":row.title,"backend":row.backend,"label":row.label(),"running":row.running,"updated":row.updated_at_ms,"last":row.last_message_at_ms,"shared":row.team_share.map(|share|share.id),"pull":row.pull.map(|pull|pull.symbol().to_owned())}));
        wires.push(json!({"input":input,"output":output}));
    }
    let initials = [
        "codex",
        "unknown-tool",
        "e\u{301}",
        "é",
        "ß",
        "東京",
        "🇭🇺",
        "👩🏽‍💻",
        "👨‍👩‍👧‍👦",
        "",
    ]
    .map(|id| json!({"id":id,"initial":tokenstat_linux::display::harness_initial(id)}));
    json!({"patience":tokenstat_linux::chat::DIRECTORY_TIMEOUT_SECS,"cacheCap":tokenstat_linux::chat::directory::CACHE_CAP,"initials":initials,"windows":windows,"loops":loops,"orders":orders,"menus":menus,"presentation":presentation,"ages":ages,"timers":timers,"untouched":untouched,"wires":wires})
}
