// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

use serde_json::{Value, json};
use tokenstat_linux::{
    design::palette,
    home::{
        ActivityScope, Calendar, HeatCell, HeatmapGeometry, HomeState, format_spend,
        greeting_phrase,
    },
    localization,
};

#[path = "home/day.rs"]
mod day;
#[path = "home/devices.rs"]
mod devices;
#[path = "home/layout.rs"]
mod layout;
#[path = "home/plans.rs"]
mod plans;
#[path = "home/storage.rs"]
mod storage;
#[path = "home/store.rs"]
mod store;
#[path = "home/work.rs"]
mod work;

pub fn snapshot() -> anyhow::Result<Value> {
    let mut geometry = Vec::new();
    for width in [0., 100., 320., 600., 960., 1440., 2000.] {
        for weeks in [0, 1, 26, 53] {
            for rows in [0, 7] {
                let g = HeatmapGeometry::new(width, weeks, rows);
                let cells = if rows == 0 {
                    Vec::new()
                } else {
                    vec![vec![
                        Some(HeatCell {
                            date: "2026-11-09".into(),
                            value: 100,
                            level: 1,
                            locked: false,
                        }),
                        None,
                        Some(HeatCell {
                            date: "2026-11-11".into(),
                            value: 0,
                            level: 4,
                            locked: true,
                        }),
                    ]]
                };
                let points = [
                    (-1., 1.),
                    (0., 0.),
                    (g.cell, g.cell),
                    (g.cell + 0.1, 1.),
                    (g.stride() + 1., 1.),
                    (g.stride() * 2. + 1., 1.),
                    (1., g.stride() + 1.),
                ];
                geometry.push(json!({"width":width,"weeks":weeks,"rows":rows,"cell":g.cell,"gap":g.gap,
                "contentWidth":g.content_width(),"contentHeight":g.content_height(),"reservedHeight":g.reserved_height(),
                "slots":points.map(|(x,y)| json!({"x":x,"y":y,"slot":g.slot(x,y,&cells)}))}));
            }
        }
    }
    let spend = [
        0,
        1,
        4_999,
        5_000,
        5_001,
        14_999,
        15_000,
        15_001,
        25_000,
        35_000,
        1_005_000,
        1_015_000,
        99_995_000,
        1_234_567_890,
        i64::MAX as u64,
        u64::MAX,
    ]
    .map(|micros| json!({"micros":micros,"text":format_spend(micros)}));
    let mut greetings = Vec::new();
    for hour in [0, 5, 11, 12, 16, 17, 21, 22] {
        for history in [false, true] {
            for day in 1..=10 {
                greetings.push(json!({"hour":hour,"history":history,"day":day,"text":greeting_phrase(hour,history,day)}));
            }
        }
    }
    let fixture = Calendar::fixture(ActivityScope::ThisMachine)?;
    let mut figures = Vec::new();
    for variant in 0..4 {
        let mut calendar = fixture.clone();
        match variant {
            1 => calendar.rows.clear(),
            2 => calendar.last = "2099-12-31".into(),
            3 => {
                for cell in calendar.rows.iter_mut().flatten().flatten() {
                    cell.value = u64::MAX;
                }
            }
            _ => {}
        }
        figures.push(
            json!({"input":calendar,"today":calendar.today_value(),"week":calendar.week_value()}),
        );
    }
    let mut subtitles = Vec::new();
    for (scope, notice) in [
        ("local", None),
        ("account", None),
        ("local", Some("auth")),
        ("account", Some("stale")),
    ] {
        let mut grid = fixture.clone();
        grid.scope = Some(scope.into());
        grid.notice_code = notice.map(str::to_owned);
        grid.notice = notice.map(|_| "Fixture notice".to_owned());
        let mut home = HomeState::default();
        let request = home.begin(ActivityScope::AllMachines, false);
        home.finish(request, Ok(Some(grid)));
        subtitles.push(json!({"scope":scope,"noticeCode":notice,"text":home.subtitle()}));
    }
    let line_heights: Vec<_> = [false, true]
        .into_iter()
        .flat_map(|mono| {
            [
                9., 10., 11., 12., 13., 14., 15., 17., 20., 22., 24., 26., 11.9,
            ]
            .map(move |points| {
                let token = tokenstat_linux::design::FontToken {
                    points,
                    weight: 500,
                };
                json!({"mono":mono,"points":points,"height":token.line_height(mono)})
            })
        })
        .collect();
    Ok(
        json!({"geometry":geometry,"spend":spend,"greetings":greetings,"subtitles":subtitles,"fixture":fixture,"figures":figures,"lineHeights":line_heights,"day":day::snapshot()?,"layout":layout::snapshot(),"plans":plans::snapshot(),"store":store::snapshot(),"devices":devices::snapshot(),
        "work":work::snapshot(),
        "storage":storage::snapshot()?,
        "heat":palette::HEAT.iter().map(|c| json!({"light":[c.light.0,c.light.1],"dark":[c.dark.0,c.dark.1]})).collect::<Vec<_>>(),
        "scopes":ActivityScope::ALL.map(|s| json!({"wire":s.wire(),"label":localization::text(s.label_key(),&[]),"symbol":s.symbol()}))}),
    )
}
