// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use serde_json::{Value, json};
use tokenstat_linux::{
    display,
    home::{HeatCell, day::*},
};

pub fn snapshot() -> anyhow::Result<Value> {
    let mut geometry = Vec::new();
    for width in [240., 320., 640., 1260., 1920.] {
        for height in [220., 620., 825.] {
            for anchor in [
                None,
                Some((0., 0.)),
                Some((width - 20., height - 20.)),
                Some((width / 2., height / 2.)),
                Some((32., height - 16.)),
                Some((width - 16., 32.)),
            ] {
                let rect = anchor.map(|(x, y)| Rect {
                    x,
                    y,
                    width: 12.,
                    height: 12.,
                });
                geometry.push(json!({"window":[width,height],"anchor":rect,"result":PopoverGeometry::new(rect,width,height)}));
            }
        }
    }
    let money: Vec<_> = [i64::MIN,-1_015_000,-5_000,-1,0,5_000,1_015_000,i64::MAX].into_iter().flat_map(|micros| {
        [false,true].into_iter().flat_map(move |estimated| [false,true].map(move |complete| json!({"micros":micros,"estimated":estimated,"complete":complete,"text":display::money(micros,estimated,complete)})))
    }).collect();
    let tokens = [
        0,
        999,
        1000,
        1050,
        1250,
        9950,
        9999,
        10000,
        10500,
        11500,
        999_999,
        1_000_000,
        1_050_000,
        1_250_000,
        999_999_999,
        1_000_000_000,
        u64::MAX,
    ]
    .map(|n| json!({"n":n,"text":display::tokens(n)}));
    let models = [
        "",
        " ",
        "\tfoo/model\u{a0}",
        "//vendor//model//",
        "default",
        "AUTO",
        "vendor/cursor-default",
        "model: leaf",
        "model: ",
        "\nmodel\n",
        "\u{000b}model\u{000c}",
        "\u{85}model\u{85}",
        "\u{2028}model\u{2029}",
        "\u{2003}model\u{2003}",
        "\u{200b}model\u{200b}",
    ]
    .map(|id| json!({"id":id,"text":display::short_model(id)}));
    let harnesses = ["","claude","claude_code","claude_code_estimate","claude_code_rollup","codex","grok","opencode","opencode2","cline","openclaw","muse","devin","pi","dsh","zed","copilot","agy","antigravity-v2","cursor","gemini","hermes","kilo","kimi","qwen","future_tool"].map(|id| json!({"id":id,"canonical":display::harness_canonical(id),"key":display::harness_key(id),"name":display::harness_name(id),"asset":display::harness_brand_asset(id)}));
    let base = DayDetail::fixture(&HeatCell {
        date: "2026-11-09".into(),
        value: 1_500_000,
        level: 2,
        locked: false,
    })
    .unwrap();
    let mut details = vec![base.clone()];
    let mut empty = base.clone();
    empty.rows.clear();
    empty.unpriced_models.clear();
    details.push(empty);
    let mut unknown = base.clone();
    for row in &mut unknown.rows {
        row.fresh = None;
        row.cache_read = Some(0);
        row.cache_write5m = None;
        row.cache_write1h = None;
        row.output = None;
    }
    details.push(unknown);
    let mut extreme = base.clone();
    for row in &mut extreme.rows {
        row.tokens = u64::MAX;
        row.fresh = Some(u64::MAX);
        row.cache_read = Some(u64::MAX);
        row.cache_write5m = Some(u64::MAX);
        row.cache_write1h = Some(u64::MAX);
        row.output = Some(u64::MAX);
    }
    extreme.rows.push(DayPart {
        model: "".into(),
        src: "".into(),
        fresh: None,
        cache_read: None,
        cache_write5m: None,
        cache_write1h: None,
        output: None,
        tokens: 1,
        events: 1,
    });
    extreme.rows[2].src = "claude_code_rollup".into();
    extreme
        .unpriced_models
        .extend(["vendor/gpt-6".into(), "absent/local".into()]);
    details.push(extreme);
    let mut duplicate = base.clone();
    let mut row = duplicate.rows[0].clone();
    row.src = "claude_code_estimate".into();
    duplicate.rows.push(row);
    duplicate.rows.reverse();
    details.push(duplicate);
    let mut readings = Vec::new();
    for detail in details {
        for extra in [
            None,
            Some(DayOverview::default()),
            Some(DayOverview::fixture(&base)),
        ] {
            let mut input_extra = serde_json::to_value(&extra)?;
            // Supply full original bridge fixtures so the Swift comparison
            // decodes its actual Bucket/Counters/Totals declarations.
            if let Some(object) = input_extra.as_object_mut() {
                for name in ["byModel", "bySource", "byProject", "bySession"] {
                    for bucket in object[name].as_array_mut().unwrap() {
                        bucket["events"] = 0.into();
                        bucket["sessions"] = 0.into();
                        let counters = bucket["counters"].as_object_mut().unwrap();
                        counters.insert("inputTotal".into(), 0.into());
                        counters.insert("hasUnknown".into(), true.into());
                    }
                }
                if !object["totals"].is_null() {
                    object["totals"]["counters"] =
                        json!({"total":0,"inputTotal":0,"hasUnknown":true});
                    object["totals"]["events"] = 0.into();
                    object["totals"]["days"] = 0.into();
                }
            }
            readings.push(json!({"detail":detail,"extra":input_extra,"result":{
                "priced":model_rows(&detail,extra.as_ref(),false),"unpriced":model_rows(&detail,extra.as_ref(),true),"harnesses":harness_rows(&detail,extra.as_ref()),
                "projects":extra.as_ref().map(|e|bucket_rows(&e.by_project)).unwrap_or_default(),"sessions":extra.as_ref().map(|e|bucket_rows(&e.by_session)).unwrap_or_default(),
                "counters":detail.counters(),"segments":detail.segments().iter().map(|s|json!({"kind":s.kind,"value":s.value,"total":s.total,"width":s.width(296.),"percent":s.percent()})).collect::<Vec<_>>()
            }}));
        }
    }
    Ok(
        json!({"geometry":geometry,"money":money,"tokens":tokens,"models":models,"harnesses":harnesses,"readings":readings}),
    )
}
