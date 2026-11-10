// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use serde_json::{Value, json};
use tokenstat_linux::{
    home::layout::{Arrangement, Preset, Section},
    localization,
};

fn ids(sections: impl IntoIterator<Item = Section>) -> Vec<&'static str> {
    sections.into_iter().map(Section::id).collect()
}
fn hidden_ids(arrangement: &Arrangement) -> Vec<&'static str> {
    let mut values = ids(arrangement.hidden.iter().copied());
    values.sort();
    values
}
pub fn snapshot() -> Value {
    let sections = Section::ALL.map(|s| json!({"id":s.id(),"label":localization::text(s.label_key(),&[]),"detail":localization::text(s.detail_key(),&[]),"symbol":s.symbol()}));
    let presets = Preset::ALL.map(|p| { let a=p.arrangement(); json!({"id":p.id(),"label":localization::text(p.label_key(),&[]),"order":ids(a.order.iter().copied()),"hidden":hidden_ids(&a),"visible":ids(a.visible())}) });
    let orders = [
        None,
        Some(vec![]),
        Some(vec![Section::Usage, Section::Activity, Section::Usage]),
        Some(Section::ALL.into_iter().rev().collect()),
    ];
    let mut normalizations = Vec::new();
    for order in orders {
        for mask in 0..64 {
            let hidden: Vec<_> = Section::ALL
                .into_iter()
                .enumerate()
                .filter(|(i, _)| mask & (1 << i) != 0)
                .map(|(_, s)| s)
                .collect();
            let result = Arrangement::normalized(order.clone(), hidden.clone(), None);
            normalizations.push(json!({"input":order.as_ref().map(|o|ids(o.iter().copied())),"hidden":ids(hidden),"order":ids(result.order.iter().copied()),"resolvedHidden":hidden_ids(&result)}));
        }
    }
    let mut moves = Vec::new();
    for mask in [0, 9, 21, 63] {
        let mut arrangement = Preset::Work.arrangement();
        arrangement.hidden = Section::ALL
            .into_iter()
            .enumerate()
            .filter(|(i, _)| mask & (1 << i) != 0)
            .map(|(_, s)| s)
            .collect();
        for offsets in [
            vec![],
            vec![0],
            vec![1, 3],
            vec![0, 0, 6],
            vec![5, 99],
            vec![99],
        ] {
            for destination in [-4, 0, 1, 3, 6, 99] {
                let mut result = arrangement.clone();
                result.move_visible(&offsets, destination);
                moves.push(json!({"input":ids(arrangement.order.iter().copied()),"hidden":hidden_ids(&arrangement),"offsets":offsets,"destination":destination,"all":ids(Arrangement::moved(&arrangement.order,&offsets,destination)),"visible":ids(result.order)}));
            }
        }
    }
    json!({"sections":sections,"presets":presets,"normalizations":normalizations,"moves":moves})
}
