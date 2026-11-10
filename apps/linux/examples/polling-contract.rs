// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use serde_json::{Value, json};
use std::io::Read;
use tokenstat_linux::chat::polling::Cadence;

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let input: Value = serde_json::from_str(&input).unwrap();
    let traces=input["traces"].as_array().unwrap().iter().map(|trace| {
        let mut cadence=Cadence::default();
        trace.as_array().unwrap().iter().map(|action| {
            // Monotonic clock arguments are not host JSON numbers. Parse the
            // explicit decimal fixture directly, preserving every clock bit.
            let now:f64=action["now"].as_str().unwrap().parse().unwrap();
            let value=match action["op"].as_str().unwrap() {
                "note"=>{cadence.note(action["success"].as_bool().unwrap(),action["changed"].as_bool().unwrap(),now);Value::Null},
                "interval"=>json!({"ms":cadence.interval(action["busy"].as_bool().unwrap(),action["attachments"].as_bool().unwrap(),now).as_millis() as u64}),
                "status"=>json!({"claim":cadence.claim_status(now,action["force"].as_bool().unwrap())}),
                "approvals"=>json!({"claim":cadence.claim_approvals(now,action["force"].as_bool().unwrap())}),
                other=>panic!("unknown fixture action: {other}"),
            };
            json!({"nowBits":now.to_bits().to_string(),"value":value})
        }).collect::<Vec<_>>()
    }).collect::<Vec<_>>();
    println!("{}", json!({"traces":traces}));
}
