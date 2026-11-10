// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Platform shaping measurements in a hidden window, with no host/archive IO.

use gpui::{prelude::*, *};
use serde_json::json;
use tokenstat_linux::{
    design::{FontToken, fonts},
    presentation,
};

struct Hidden;
impl Render for Hidden {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
    }
}
fn main() {
    Application::new().run(|app| {
        presentation::register_fonts(app).expect("The original bundled fonts must register");
        app.open_window(WindowOptions { show: false, focus: false, ..Default::default() }, |window, app| {
            let mut inputs = vec![
                (".SystemUIFont", 10., 400, "API list price"),
                (".SystemUIFont", 10., 400, "not an extra bill"),
                (".SystemUIFont", 13., 600, "Models"),
                (".SystemUIFont", 13., 500, "Open in Insights"),
                (fonts::INTERFACE, 9., 600, "SELECTED DAY"),
                (fonts::INTERFACE, 10., 400, "Fresh input"),
                (fonts::INTERFACE, 13., 600, "Today opens here"),
                (fonts::INTERFACE, 15., 600, "Nov 9, 2026"),
                (fonts::INTERFACE, 22., 500, "$1.50+"),
            ];
            for points in [10., 11., 12., 13., 15.] {
                for weight in [400, 500, 600, 700] {
                    for text in ["Models", "Open in Insights", "Árvíztűrő tükörfúrógép", "Σύνδεση", "設定", "الإعدادات", "📊 Devices"] {
                        inputs.push((".SystemUIFont", points, weight, text));
                    }
                }
            }
            let mut cases = Vec::new();
            for (family, points, weight, text) in inputs {
                let mut font = if family == ".SystemUIFont" { presentation::system_font(weight) } else {
                    let mut font = font(family);
                    font.weight = FontWeight(f32::from(weight));
                    font
                };
                let numeric = text == "$1.50+";
                if numeric { font.features = FontFeatures(std::sync::Arc::new(vec![("tnum".into(), 1)])); }
                let selection = font.weight.0;
                let run = TextRun { len: text.len(), font, color: black(), background_color: None, underline: None, strikethrough: None };
                let line = window.text_system().shape_line(text.into(), px(points), &[run], None);
                let seat = if family == ".SystemUIFont" { presentation::system_seat(points, weight, app) } else { presentation::interface_seat(FontToken { points, weight }, app) };
                cases.push(json!({"family":family,"points":points,"weight":weight,"selectedWeight":selection,"text":text,"numeric":numeric,"width":f32::from(line.width).ceil(),"advance":f32::from(line.width),"seat":seat}));
            }
            println!("{}", json!({"cases":cases}));
            app.new(|_| Hidden)
        }).expect("The hidden font-measurement window must open");
        app.quit();
    });
}
