// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Fixed UTC fixtures for the original sidebar layout contract.
use serde_json::{Value, json};
use std::{cmp::Ordering, collections::HashMap};
use tokenstat_linux::{
    chat::Conversation,
    desktop_data::Repository,
    sidebar::{
        ProjectsSort,
        layout::{self, Collation, Day},
    },
};
use unicode_normalization::{UnicodeNormalization, char::is_combining_mark};

struct FixtureCollation;
fn folded(value: &str) -> String {
    value
        .nfd()
        .filter(|c| !is_combining_mark(*c))
        .flat_map(char::to_lowercase)
        .collect()
}
impl Collation for FixtureCollation {
    fn contains(&self, haystack: &str, needle: &str) -> bool {
        folded(haystack).contains(&folded(needle))
    }
    fn compare(&self, left: &str, right: &str) -> Ordering {
        folded(left).cmp(&folded(right))
    }
}
fn main() {
    let now: i64 = 1_700_006_400;
    let input = json!([
        {"id":"one","name":"Café","path":"/one","exists":true,"machineID":null,"machineLabel":null,"chats":[
            {"id":"a","workspaceId":"one","title":"Alpha","backend":"Codex","updatedAtMs":(now-86400)*1000,"running":false,"branch":"main"},
            {"id":"b","workspaceId":"one","title":"Zeta","backend":"Claude","updatedAtMs":(now-12*86400)*1000,"running":true},
            {"id":"c","workspaceId":"one","title":"Echo","backend":"Codex","updatedAtMs":(now-3*86400)*1000,"lastMessageAtMs":now*1000,"running":false}]},
        {"id":"two","name":"Beta","path":"/two","exists":true,"machineID":"peer","machineLabel":"Laptop","chats":[
            {"id":"d","workspaceId":"two","title":"Delta","backend":"Muse","updatedAtMs":(now-6*86400)*1000,"running":false,"branch":"feature"},
            {"id":"e","workspaceId":"two","title":"Gamma","backend":"Claude","updatedAtMs":(now-7*86400)*1000,"running":false}]}
    ]);
    let folders: Vec<Repository> = serde_json::from_value(input.clone()).unwrap();
    let chats: HashMap<String, Vec<Conversation>> = input
        .as_array()
        .unwrap()
        .iter()
        .map(|item| {
            (
                item["id"].as_str().unwrap().into(),
                serde_json::from_value(item["chats"].clone()).unwrap(),
            )
        })
        .collect();
    let mut cases: Vec<Value> = vec![];
    for query in ["", "  CAFE  ", "laptop", "feature", "claude", "missing"] {
        for sort in [
            ProjectsSort::Manual,
            ProjectsSort::Name,
            ProjectsSort::Recent,
        ] {
            let entries =
                layout::chat_entries(&folders, |f| &chats[&f.id], query, sort, &FixtureCollation);
            let folder_rows = folders
                .iter()
                .filter(|f| layout::matches(f, &chats[&f.id], query, &FixtureCollation));
            let ordered = layout::ordered_folders(
                folder_rows,
                sort,
                |f| {
                    chats[&f.id]
                        .iter()
                        .map(|c| c.last_message_at_ms.unwrap_or(c.updated_at_ms))
                        .max()
                        .unwrap_or(0)
                },
                &FixtureCollation,
            );
            let groups = layout::day_groups(&entries, |ms| {
                let start = ms.div_euclid(86_400_000) * 86_400;
                (start, (now - start) / 86_400)
            });
            cases.push(json!({"query":query,"sort":sort.as_str(),"folders":ordered.iter().map(|f| &f.id).collect::<Vec<_>>(),"entries":entries.iter().map(|e| &e.chat.id).collect::<Vec<_>>(),"filtered":folders.iter().map(|f|layout::filtered_chats(&chats[&f.id],query,&FixtureCollation).iter().map(|c|c.id.clone()).collect::<Vec<_>>()).collect::<Vec<_>>(),"groups":groups.iter().map(|(day, rows)|json!({"day":match day {Day::Working=>"working".into(),Day::Today=>"today".into(),Day::Yesterday=>"yesterday".into(),Day::Day(start)=>format!("day:{start}"),Day::Older=>"older".into()},"entries":rows.iter().map(|e| &e.chat.id).collect::<Vec<_>>() })).collect::<Vec<_>>()}));
        }
    }
    println!("{}", json!({"input":input,"now":now,"cases":cases}));
}
