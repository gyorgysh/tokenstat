// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use serde_json::{Value, json};
use tokenstat_linux::devices::{DeviceKind, Machine, Selection};

fn reading(machine: &Machine) -> Value {
    json!({"id":machine.id(),"display":machine.display_name(),"subtitle":machine.subtitle(),"isHost":machine.is_host(),"reportsArchiveSync":machine.is_host(),"symbol":machine.symbol(),"homeLabel":machine.home_label(),"status":machine.home_status()})
}
pub fn snapshot() -> Value {
    let mut records = Vec::new();
    for label in [
        None,
        Some(""),
        Some(" \u{200b} "),
        Some("iPad mini"),
        Some("IPHONE Linux"),
        Some("Android tab desk"),
        Some("MacBook Air"),
        Some("ThinkPad"),
        Some("Mac Studio"),
        Some("Linux box"),
        Some("Generic"),
        Some("π device"),
    ] {
        for platform in [
            None,
            Some("Android tablet"),
            Some("Ubuntu 24.04"),
            Some("iPadOS"),
        ] {
            for kind in [None, Some("client"), Some("host")] {
                for online in [None, Some(false), Some(true)] {
                    let machine = Machine {
                        machine_id: Some(format!("fixture-{}", records.len())),
                        label: label.map(str::to_owned),
                        kind: kind.map(str::to_owned),
                        platform: platform.map(str::to_owned),
                        online,
                        ..Machine::default()
                    };
                    records.push(json!({"input":machine,"reading":reading(&machine)}));
                }
            }
        }
    }
    for id in [None, Some("")] {
        for label in [None, Some(""), Some("named")] {
            let machine = Machine {
                machine_id: id.map(str::to_owned),
                label: label.map(str::to_owned),
                ..Machine::default()
            };
            records.push(json!({"input":machine,"reading":reading(&machine)}));
        }
    }
    let machines = Machine::fixture();
    let mut renamed = machines.clone();
    renamed[0].label = Some("Renamed Studio".into());
    let label_only = Machine {
        label: Some("label-only".into()),
        ..Machine::default()
    };
    let mut empty_id = label_only.clone();
    empty_id.machine_id = Some("".into());
    let cases = [
        (machines.clone(), renamed, Some(0)),
        (machines.clone(), machines[1..].to_vec(), Some(0)),
        (vec![label_only.clone()], vec![label_only], Some(0)),
        (vec![empty_id.clone()], vec![empty_id], Some(0)),
        (machines.clone(), machines.clone(), None),
        (vec![Machine::default()], vec![], Some(0)),
    ];
    let selections:Vec<_>=cases.into_iter().map(|(before,after,index)| {
        let mut selection=Selection::default();
        if let Some(index)=index {selection.select_account(&before[index]);}
        let key=match &selection.kind {Some(DeviceKind::Account(id))=>Some(id),_=>None};
        json!({"before":before,"after":after,"index":index,"key":key,"selected":selection.account(&after).map(reading)})
    }).collect();
    json!({"records":records,"selections":selections,"fixture":machines})
}
