// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use serde_json::{Value, json};
use tokenstat_linux::work::{
    Kind, Reference, Scope,
    continuity::{Continuity, Date, Place, restore},
    pins::{self, Pins},
    preferences::Preferences,
    text,
};

fn reference(scope: &Scope, host: &str, folder: &str, kind: Kind, item: Option<&str>) -> Reference {
    Reference {
        scope: scope.clone(),
        host_identity: host.into(),
        workspace_id: folder.into(),
        kind,
        item_id: item.map(str::to_owned),
        anchor: None,
    }
}
fn state(preferences: &Preferences, scopes: &[Scope]) -> anyhow::Result<Value> {
    let pins = Pins {
        preferences: preferences.clone(),
    };
    let continuity = Continuity {
        preferences: preferences.clone(),
    };
    let place = continuity.place()?;
    let shelves:Vec<_>=scopes.iter().map(|scope|Ok(json!({"scope":scope,"pins":pins.pins(Some(scope))?,"recent":continuity.recent(scope,4)?,"negative":continuity.recent(scope,-1)?,"last":continuity.last(scope,"host","a")?}))).collect::<anyhow::Result<_>>()?;
    let ids = vec![
        "a".into(),
        "remote:peer:a".into(),
        "é".into(),
        "remote:peer:é".into(),
    ];
    Ok(
        json!({"shelves":shelves,"place":place,"restored":scopes.iter().map(|s|restore(place.as_ref(),&ids,Some(s),Some("host"))).collect::<Vec<_>>(),"unknownRestore":restore(place.as_ref(),&ids,None,Some("host")),"keys":preferences.read(|m|{let mut k=m.keys().cloned().collect::<Vec<_>>();k.sort();k})?}),
    )
}
fn run(case: &Value) -> anyhow::Result<Value> {
    let preferences = Preferences::default();
    let scopes: Vec<Scope> = serde_json::from_value(case["scopes"].clone())?;
    if let Some(seed) = case.get("seed").and_then(Value::as_object) {
        preferences.update(|map| {
            map.extend(seed.clone());
            Ok(())
        })?;
    }
    let mut rows =
        vec![json!({"label":"initial","result":null,"state":state(&preferences,&scopes)?})];
    for step in case["steps"].as_array().unwrap() {
        // Independent handles reread the same backing preferences every time.
        let pins = Pins {
            preferences: preferences.clone(),
        };
        let continuity = Continuity {
            preferences: preferences.clone(),
        };
        let at = if step["atMode"] == "nan" {
            Date(f64::NAN)
        } else {
            Date(step["at"].as_f64().unwrap_or(0.))
        };
        let record = || serde_json::from_value::<Reference>(step["reference"].clone());
        let scope = || serde_json::from_value::<Scope>(step["scope"].clone());
        let result = match step["op"].as_str().unwrap() {
            "pin" => json!(pins.pin(
                &record()?,
                step["label"].as_str().unwrap_or("label"),
                step["folderName"].as_str().unwrap_or("folder"),
                at
            )?),
            "unpin" => {
                pins.unpin(&record()?)?;
                Value::Null
            }
            "remember" => {
                continuity.remember(&record()?, at)?;
                Value::Null
            }
            "forget" => {
                continuity.forget(
                    &scope()?,
                    step["host"].as_str().unwrap(),
                    step["workspace"].as_str().unwrap(),
                )?;
                Value::Null
            }
            "remove" => {
                continuity.remove(&scope()?)?;
                Value::Null
            }
            "place" => {
                let mut place: Place = serde_json::from_value(step["place"].clone())?;
                if step["atMode"] == "nan" {
                    place.saved_at = at;
                }
                continuity.remember_place(&place)?;
                Value::Null
            }
            "forgetPlace" => {
                continuity.forget_place()?;
                Value::Null
            }
            _ => panic!("unknown fixture operation"),
        };
        if step["report"] != false {
            rows.push(
                json!({"label":step["name"],"result":result,"state":state(&preferences,&scopes)?}),
            );
        }
    }
    Ok(json!({"input":case,"rows":rows}))
}
pub fn snapshot() -> anyhow::Result<Value> {
    let origins = [
        "https://Example.COM:443///",
        "HTTP://Example.COM:80/base///?q=1#f",
        "https://host/a/../b/",
        "https://host/a//b//",
        "https://host/%7Euser/%2f/",
        "https://host/a b/",
        " https://host/",
        "https://host/ ",
        "https://host:00443/",
        "https://host:/",
        "https://host:99999/",
        "https://user@host/",
        "https://@host/",
        "https://host./",
        "https://münich.example/",
        "https://%65XAMPLE.com/",
        "https://[FE80::1]/",
        "https://[fe80::1%25en0]/",
        "https://[::1]:443/",
        "https://foo_bar/",
        "https://a\\b/",
        "https://host/a\\b/",
        "https://host/%zz/",
        "https://host/é/",
        "https://host/e\u{301}/",
        "https://HOST?x#f",
        "http:host/path",
        "https:///path",
        "https://host\n/",
        "https://host/%2F//",
        "https://host:0",
        "https://host:65536",
        "https://host:abc",
        "https://127.1/",
        "https://0x7f000001/",
        "https://host/%7e",
        "https://host/%7e/",
        "https://host/%2fmid/end",
        "https://host/%2fmid/end/",
        "https://host/%20/%zz/",
        "https://host/a[b]/",
        "https://host/a[b]",
        "https://host/a?bad=%xx",
        "https://host:00081/",
        "https://host:+80/",
        "https://host:-1/",
        "https://host:9223372036854775807/",
        "https://host:9223372036854775808/",
        "https://[notip]/",
        "https://[::gg]/",
        "https://[::ffff:127.0.0.1]/",
        "https://[2001:0DB8:0000::1]/",
        "https://%zz/",
        "https://host%40name/",
        "https://foo bar/",
        "https://faß.de/",
        "https://host/\0/",
        "https://host/%FF/",
        "https://host/%FF",
        "https://host:001/",
        "https://.host/",
        "https://host..name/",
        "https://host%2Fname/",
        "https://\u{200b}/",
        "https://\u{ad}/",
        "https://host/%7f/",
    ];
    let mut scope_cases = vec![];
    for origin in origins {
        for identity in ["fixture", "", " "] {
            let scope = Scope::account(origin, identity);
            scope_cases.push(json!({"origin":origin,"identity":identity,"scope":scope,"key":scope.as_ref().map(Scope::storage_key)}));
        }
    }
    let a = Scope::account("https://fixture.invalid", "alice").unwrap();
    let b = Scope::account("https://fixture.invalid", "bob").unwrap();
    let local = Scope::local("installation");
    let scopes = vec![a.clone(), b.clone(), local.clone()];
    let mut labels = vec![
        "".into(),
        " \u{200b}\n".into(),
        " label \n".into(),
        "a/b".into(),
        "a\\b".into(),
        "line\nline".into(),
        "a\u{200b}b".into(),
        "a\u{2028}b".into(),
        "a\u{00ad}b".into(),
        "normal & label".into(),
        "👨‍👩‍👧‍👦".into(),
        "e\u{301}".repeat(81),
        "😀".repeat(81),
        "🇭🇺".repeat(81),
        "字".repeat(81),
    ];
    for scalar in [
        0, 9, 10, 32, 127, 133, 160, 173, 769, 1564, 6158, 8203, 8204, 8205, 8232, 8233, 8288,
        65279, 0x1f600, 0xffff, 0x10ffff, 0xe000,
    ] {
        labels.push(format!("a{}b", char::from_u32(scalar).unwrap()));
    }
    let labels: Vec<_> = labels
        .iter()
        .map(|s| json!({"input":s,"safe":pins::safe_label(s),"encoded":text::encode(s)}))
        .collect();
    let mut refs = vec![];
    for scope in [&a, &local] {
        for kind in [
            Kind::Workspace,
            Kind::Conversation,
            Kind::Terminal,
            Kind::Commit,
            Kind::SavedDiff,
        ] {
            for item in [None, Some(""), Some("item|:%/ ü"), Some("a\u{200b}b")] {
                let r = reference(scope, "host", "workspace", kind, item);
                refs.push(r);
            }
        }
    }
    for value in [
        "e\u{301}".repeat(256),
        "字".repeat(257),
        "😀".repeat(256),
        "a\u{200b}b".into(),
        "".into(),
    ] {
        refs.push(reference(
            &a,
            &value,
            "workspace",
            Kind::Conversation,
            Some("item"),
        ));
    }
    let keys:Vec<_>=refs.iter().map(|r|json!({"reference":r,"pin":pins::key(r),"conversation":r.conversation_key(),"folder":r.folder_key()})).collect();
    let mut cases = vec![];
    let mut steps = vec![];
    for i in 0..8 {
        steps.push(json!({"op":"pin","reference":reference(&a,"host",&format!("w{i}"),Kind::Workspace,None),"label":format!("folder {i}"),"at":i,"report":false}));
    }
    steps.push(json!({"op":"pin","name":"ninth-refused","reference":reference(&a,"host","ninth",Kind::Workspace,None),"at":9}));
    steps.push(json!({"op":"pin","name":"repin-full","reference":reference(&a,"host","w0",Kind::Workspace,None),"label":"new label","at":100}));
    let mut anchored = reference(&a, "host", "w0", Kind::Workspace, None);
    anchored.anchor = Some("reading".into());
    steps.push(json!({"op":"unpin","name":"unpin-anchor","reference":anchored}));
    steps.push(json!({"op":"pin","name":"other-account","reference":reference(&b,"host","w0",Kind::Workspace,None),"at":101}));
    steps.push(json!({"op":"pin","name":"nan-removes-shelf","reference":reference(&b,"host","w0",Kind::Workspace,None),"atMode":"nan"}));
    cases.push(json!({"name":"pin-capacity","scopes":scopes,"steps":steps}));
    let conversation = reference(&a, "host", "a", Kind::Conversation, Some("one"));
    let mut second = conversation.clone();
    second.item_id = Some("two".into());
    let mut peer = conversation.clone();
    peer.host_identity = "peer".into();
    let workspace = reference(&a, "peer", "a", Kind::Workspace, None);
    let place = Place::workspace(workspace, "chat".into(), Date(20.)).unwrap();
    cases.push(json!({"name":"continuity","scopes":scopes,"steps":[
        {"op":"remember","name":"first","reference":conversation,"at":1},
        {"op":"remember","name":"same-folder","reference":second,"at":2},
        {"op":"remember","name":"other-host","reference":peer,"at":3},
        {"op":"remember","name":"failed-date-keeps-visits","reference":conversation,"atMode":"nan"},
        {"op":"place","name":"remote-place","place":place},
        {"op":"place","name":"failed-place-keeps-record","place":Place::global("home",Date(0.)),"atMode":"nan"},
        {"op":"remove","name":"remove-owner","scope":a},
        {"op":"place","name":"global-place","place":Place::global("insights",Date(4.))},
        {"op":"remove","name":"global-survives","scope":a},
        {"op":"forgetPlace","name":"forget-place"}
    ]}));
    let mut steps = vec![];
    for i in 0..105 {
        steps.push(json!({"op":"remember","reference":reference(&a,"host",&format!("f{i}"),Kind::Conversation,Some("item")),"at":i,"report":false}));
    }
    steps.push(json!({"op":"remember","name":"capacity-reread","reference":conversation,"at":106}));
    steps.push(
        json!({"op":"forget","name":"forget-one-folder","scope":a,"host":"host","workspace":"a"}),
    );
    cases.push(json!({"name":"visit-capacity","scopes":scopes,"steps":steps}));
    for (name, payload) in [
        ("bad-json", "{".to_string()),
        ("future-version", "{\"version\":2,\"visits\":[]}".into()),
        ("oversize", " ".repeat(256 * 1024 + 1)),
    ] {
        cases.push(json!({"name":name,"scopes":scopes,"seed":{"work.continuity.v1":payload,"work.place.v1":"broken"},"steps":[{"op":"remember","name":"replace-unreadable-visits","reference":conversation,"at":1},{"op":"place","name":"replace-unreadable-place","place":Place::global("home",Date(2.))}]}));
    }
    let stored_pin = |scope: &Scope, label: &str, at: f64| json!({"reference":reference(scope,"host","a",Kind::Workspace,None),"label":label,"folderName":"folder","pinnedAt":at});
    let shelf = format!("pinned.work.v1.{}", a.storage_key());
    for (name, raw) in [
        (
            "duplicates-before-sorting",
            json!([
                stored_pin(&a, "old-first", 1.),
                stored_pin(&a, "new-duplicate", 10.)
            ]),
        ),
        (
            "foreign-row-before-dedup",
            json!([
                stored_pin(&b, "other-owner", 1.),
                stored_pin(&a, "same-key", 2.)
            ]),
        ),
        (
            "malformed-pin-array",
            json!([{"reference":conversation,"label":"missing-fields"}]),
        ),
    ] {
        cases.push(
            json!({"name":name,"scopes":scopes,"seed":{shelf.clone():raw.to_string()},"steps":[]}),
        );
    }
    let version_float =
        json!({"version":1.0,"visits":[{"reference":conversation,"openedAt":1.0}]}).to_string();
    cases.push(json!({"name":"numeric-version-one","scopes":scopes,"seed":{"work.continuity.v1":version_float},"steps":[]}));
    let composed = reference(&a, "host", "é", Kind::Conversation, Some("one"));
    let decomposed = reference(&a, "host", "e\u{301}", Kind::Conversation, Some("two"));
    let folder = reference(&a, "host", "e\u{301}", Kind::Workspace, None);
    cases.push(json!({"name":"canonical-folder-restoration","scopes":scopes,"steps":[
        {"op":"remember","name":"composed-visit","reference":composed,"at":1},
        {"op":"remember","name":"equivalent-folder","reference":decomposed,"at":2},
        {"op":"place","name":"use-registered-spelling","place":Place::workspace(folder,"chat".into(),Date(3.)).unwrap()}
    ]}));
    let cases = cases.iter().map(run).collect::<anyhow::Result<Vec<_>>>()?;
    Ok(json!({"scopes":scope_cases,"labels":labels,"keys":keys,"cases":cases}))
}
