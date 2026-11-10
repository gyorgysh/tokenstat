// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! ThemedFieldBox's single-line field, with GPUI's actual platform IME bridge.
//! Native text, selection, candidate geometry and accessibility still need QA.

use crate::{
    commands::Command,
    design::{control, palette},
    presentation,
    text_input::Input,
};
use gpui::{prelude::*, *};
use std::ops::Range;
use unicode_segmentation::UnicodeSegmentation;

pub(crate) struct Field {
    pub input: Input,
    pub enabled: bool,
    pub focus: FocusHandle,
    pub dark: bool,
    placeholder: String,
    layout: Option<ShapedLine>,
    bounds: Option<Bounds<Pixels>>,
    scroll: Pixels,
    dragging: bool,
    caret: bool,
}
impl Field {
    pub fn new(value: String, placeholder: String, cx: &mut Context<Self>) -> Self {
        cx.spawn(async move |field, cx| {
            loop {
                cx.background_executor()
                    .timer(std::time::Duration::from_millis(500))
                    .await;
                if field
                    .update(cx, |field, cx| {
                        field.caret = !field.caret;
                        cx.notify();
                    })
                    .is_err()
                {
                    break;
                }
            }
        })
        .detach();
        Self {
            input: Input::new(value),
            enabled: true,
            focus: cx.focus_handle(),
            dark: false,
            placeholder,
            layout: None,
            bounds: None,
            scroll: px(0.),
            dragging: false,
            caret: true,
        }
    }
    pub fn command(&mut self, command: Command, cx: &mut Context<Self>) {
        if !self.enabled {
            return;
        }
        match command {
            Command::SelectAll => self.input.select_all(),
            Command::Copy | Command::Cut => {
                if !self.input.selected().is_empty() {
                    cx.write_to_clipboard(ClipboardItem::new_string(self.input.selected().into()));
                    if command == Command::Cut {
                        self.input.replace(None, "");
                    }
                }
            }
            Command::Paste => {
                if let Some(value) = cx.read_from_clipboard().and_then(|item| item.text()) {
                    self.input.replace(None, &value);
                }
            }
            Command::Undo => self.input.undo(),
            Command::Redo => self.input.redo(),
            _ => return,
        }
        self.caret = true;
        cx.notify();
    }
    fn point_index(&self, point: Point<Pixels>) -> Option<usize> {
        let bounds = self.bounds?;
        let line = self.layout.as_ref()?;
        Some(
            line.closest_index_for_x(point.x - bounds.left() + self.scroll)
                .min(self.input.text().len()),
        )
    }
    fn key(&mut self, event: &KeyDownEvent, _window: &mut Window, cx: &mut Context<Self>) {
        if !self.enabled || self.input.marked.is_some() {
            return;
        }
        let mods = event.keystroke.modifiers;
        let word = if cfg!(target_os = "macos") {
            mods.alt
        } else {
            mods.control
        };
        let edge = cfg!(target_os = "macos") && mods.platform;
        match event.keystroke.key.as_str() {
            "left" | "right" => {
                let forward = event.keystroke.key == "right";
                if edge {
                    self.input.edge(forward, mods.shift);
                } else {
                    self.input.move_cursor(forward, mods.shift, word);
                }
            }
            "home" | "end" => self.input.edge(event.keystroke.key == "end", mods.shift),
            "backspace" | "delete" => {
                let forward = event.keystroke.key == "delete";
                if edge {
                    self.input.edge(forward, true);
                }
                self.input.delete(forward, word);
            }
            _ => return,
        }
        self.caret = true;
        cx.stop_propagation();
        cx.notify();
    }
}
impl EntityInputHandler for Field {
    fn text_for_range(
        &mut self,
        range: Range<usize>,
        adjusted: &mut Option<Range<usize>>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<String> {
        let range = self.input.from_utf16(range);
        *adjusted = Some(self.input.to_utf16(range.clone()));
        Some(self.input.text()[range].into())
    }
    fn selected_text_range(
        &mut self,
        ignore_disabled: bool,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<UTF16Selection> {
        (self.enabled || ignore_disabled).then(|| UTF16Selection {
            range: self.input.to_utf16(self.input.selection()),
            reversed: self.input.reversed(),
        })
    }
    fn marked_text_range(&self, _: &mut Window, _: &mut Context<Self>) -> Option<Range<usize>> {
        self.input.marked.clone().map(|r| self.input.to_utf16(r))
    }
    fn unmark_text(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        self.input.unmark();
        cx.notify();
    }
    fn replace_text_in_range(
        &mut self,
        range: Option<Range<usize>>,
        value: &str,
        _: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.enabled {
            self.input.replace(range, value);
            self.caret = true;
            cx.notify();
        }
    }
    fn replace_and_mark_text_in_range(
        &mut self,
        range: Option<Range<usize>>,
        value: &str,
        selection: Option<Range<usize>>,
        _: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.enabled {
            self.input.replace_marked(range, value, selection);
            self.caret = true;
            cx.notify();
        }
    }
    fn bounds_for_range(
        &mut self,
        range: Range<usize>,
        _: Bounds<Pixels>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<Bounds<Pixels>> {
        let bounds = self.bounds?;
        let line = self.layout.as_ref()?;
        if line.text.as_ref() != self.input.text() {
            return None;
        }
        let range = self.input.from_utf16(range);
        Some(Bounds::new(
            point(
                bounds.left() + line.x_for_index(range.start) - self.scroll,
                bounds.top(),
            ),
            size(
                (line.x_for_index(range.end) - line.x_for_index(range.start)).max(px(1.)),
                bounds.size.height,
            ),
        ))
    }
    fn character_index_for_point(
        &mut self,
        point: Point<Pixels>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<usize> {
        self.point_index(point)
            .map(|index| self.input.to_utf16(index..index).start)
    }
}
struct Painted {
    line: ShapedLine,
    origin: Point<Pixels>,
    selection: Option<Bounds<Pixels>>,
    caret: Option<Bounds<Pixels>>,
    color: Hsla,
}
impl Render for Field {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let dark = self.dark;
        let primary = rgba(if dark { 0xffffffd9 } else { 0x000000d9 }).into();
        let line_height = presentation::system_seat(13., 400, cx).line_height;
        let entity = cx.entity();
        let paint_entity = entity.clone();
        let focused = self.focus.is_focused(window);
        let field = canvas(
            move |bounds, window, cx| {
                let field = entity.read(cx);
                let selection = field.input.selection();
                let cursor = field.input.cursor();
                let color = if field.input.text().is_empty() {
                    palette::CONTROL_GLYPH.resolve(dark)
                } else {
                    primary
                };
                let color = if field.enabled {
                    color
                } else {
                    color.opacity(0.5)
                };
                let display = if field.input.text().is_empty() {
                    field.placeholder.clone()
                } else {
                    field.input.text().to_owned()
                };
                let run = TextRun {
                    len: display.len(),
                    font: presentation::system_font(400),
                    color,
                    background_color: None,
                    underline: None,
                    strikethrough: None,
                };
                let runs = if let Some(mark) = &field.input.marked {
                    [
                        (0..mark.start, false),
                        (mark.clone(), true),
                        (mark.end..display.len(), false),
                    ]
                    .into_iter()
                    .filter(|(range, _)| !range.is_empty())
                    .map(|(range, marked)| TextRun {
                        len: range.len(),
                        underline: marked.then_some(UnderlineStyle {
                            thickness: px(1.),
                            color: Some(color),
                            wavy: false,
                        }),
                        ..run.clone()
                    })
                    .collect::<Vec<_>>()
                } else {
                    vec![run]
                };
                let line = window
                    .text_system()
                    .shape_line(display.into(), px(13.), &runs, None);
                let caret_x = line.x_for_index(cursor);
                let scroll = if focused {
                    field
                        .scroll
                        .min(caret_x)
                        .max(caret_x - bounds.size.width + px(1.))
                        .max(px(0.))
                } else {
                    px(0.)
                };
                let origin = point(bounds.left() - scroll, bounds.top());
                let selected = (focused && !selection.is_empty()).then(|| {
                    Bounds::from_corners(
                        point(origin.x + line.x_for_index(selection.start), bounds.top()),
                        point(origin.x + line.x_for_index(selection.end), bounds.bottom()),
                    )
                });
                let caret =
                    (focused && field.enabled && field.caret && selection.is_empty()).then(|| {
                        Bounds::new(
                            point(origin.x + caret_x, bounds.top()),
                            size(px(1.), bounds.size.height),
                        )
                    });
                entity.update(cx, |field, _| {
                    field.layout = Some(line.clone());
                    field.bounds = Some(bounds);
                    field.scroll = scroll;
                });
                Painted {
                    line,
                    origin,
                    selection: selected,
                    caret,
                    color: palette::ACCENT.resolve(dark),
                }
            },
            move |bounds, paint, window, cx| {
                let field = paint_entity.read(cx);
                if field.enabled {
                    window.handle_input(
                        &field.focus,
                        ElementInputHandler::new(bounds, paint_entity.clone()),
                        cx,
                    );
                }
                window.with_content_mask(Some(ContentMask { bounds }), |window| {
                    if let Some(selection) = paint.selection {
                        window.paint_quad(fill(selection, paint.color.opacity(0.25)));
                    }
                    if let Err(error) =
                        paint
                            .line
                            .paint(paint.origin, bounds.size.height, window, cx)
                    {
                        eprintln!("tokenstat: field painting failed: {error}");
                    }
                    if let Some(caret) = paint.caret {
                        window.paint_quad(fill(caret, paint.color));
                    }
                });
            },
        )
        .w_full()
        .h(px(line_height));
        div()
            .id("themed-name-field")
            .track_focus(&self.focus)
            .w_full()
            .h(px(control::HEIGHT))
            .px(px(7.))
            .flex()
            .items_center()
            .rounded(px(8.))
            .border_1()
            .border_color(palette::BORDER.resolve(dark))
            .bg(palette::PANEL.resolve(dark))
            .cursor(CursorStyle::IBeam)
            .on_key_down(cx.listener(Self::key))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|field, event: &MouseDownEvent, window, cx| {
                    if !field.enabled {
                        return;
                    }
                    field.focus.focus(window);
                    field.input.unmark();
                    let index = field
                        .point_index(event.position)
                        .unwrap_or(field.input.text().len());
                    if event.click_count >= 3 {
                        field.input.select_all();
                    } else if event.click_count == 2 {
                        let range = field
                            .input
                            .text()
                            .split_word_bound_indices()
                            .find(|(start, part)| *start <= index && index < *start + part.len())
                            .map(|(start, part)| start..start + part.len())
                            .unwrap_or(index..index);
                        field.input.select(range.start, range.end);
                    } else if event.modifiers.shift {
                        let anchor = if field.input.reversed() {
                            field.input.selection().end
                        } else {
                            field.input.selection().start
                        };
                        field.input.select(anchor, index);
                    } else {
                        field.input.select(index, index);
                    }
                    field.dragging = true;
                    field.caret = true;
                    cx.stop_propagation();
                    cx.notify();
                }),
            )
            .on_mouse_move(cx.listener(|field, event: &MouseMoveEvent, _, cx| {
                if field.dragging
                    && field.enabled
                    && let Some(index) = field.point_index(event.position)
                {
                    let anchor = if field.input.reversed() {
                        field.input.selection().end
                    } else {
                        field.input.selection().start
                    };
                    field.input.select(anchor, index);
                    cx.notify();
                }
            }))
            .on_mouse_up(
                MouseButton::Left,
                cx.listener(|field, _, _, _| field.dragging = false),
            )
            .on_mouse_up_out(
                MouseButton::Left,
                cx.listener(|field, _, _, _| field.dragging = false),
            )
            .child(field)
    }
}
