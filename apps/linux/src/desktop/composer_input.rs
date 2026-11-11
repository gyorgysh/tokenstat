// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Multiline GPUI input for conversation drafts. Text ownership and persistence
//! stay with the caller; this entity owns only editing, shaping and focus.

use crate::{commands::Command, design::palette, presentation, text_input::Input};
use gpui::{prelude::*, *};
use std::ops::Range;
use unicode_segmentation::UnicodeSegmentation;

const LINE_HEIGHT: f32 = 20.;
const HEIGHT: f32 = 100.;

struct Line {
    start: usize,
    top: Pixels,
    layout: WrappedLine,
}
struct Layout {
    lines: Vec<Line>,
    bounds: Bounds<Pixels>,
    scroll: Pixels,
    actual: bool,
    content_height: Pixels,
    text: String,
}
impl Layout {
    fn position(&self, index: usize) -> Point<Pixels> {
        let Some(line) = self.lines.iter().rev().find(|line| line.start <= index) else {
            return self.bounds.origin;
        };
        let relative = index.saturating_sub(line.start).min(line.layout.len());
        let local = line
            .layout
            .position_for_index(relative, px(LINE_HEIGHT))
            .unwrap_or_default();
        point(
            self.bounds.left() + local.x,
            self.bounds.top() + line.top + local.y - self.scroll,
        )
    }
    fn index(&self, position: Point<Pixels>) -> usize {
        if !self.actual || self.lines.is_empty() {
            return 0;
        }
        let y = position.y - self.bounds.top() + self.scroll;
        let line = self
            .lines
            .iter()
            .rev()
            .find(|line| y >= line.top)
            .unwrap_or(&self.lines[0]);
        let local_y = (y - line.top)
            .max(px(0.))
            .min(line.layout.size(px(LINE_HEIGHT)).height - px(1.));
        let local = point(position.x - self.bounds.left(), local_y);
        let index = line
            .layout
            .closest_index_for_position(local, px(LINE_HEIGHT))
            .unwrap_or_else(|i| i);
        line.start + index.min(line.layout.len())
    }
}

pub(super) struct ComposerInput {
    pub input: Input,
    pub focus: FocusHandle,
    pub dark: bool,
    pub placeholder: String,
    layout: Option<Layout>,
    scroll: Pixels,
    dragging: bool,
    caret: bool,
    reveal_caret: bool,
}
pub(super) struct Edited;
impl EventEmitter<Edited> for ComposerInput {}
impl ComposerInput {
    pub fn new(value: String, dark: bool, placeholder: String, cx: &mut Context<Self>) -> Self {
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
            focus: cx.focus_handle(),
            dark,
            placeholder,
            layout: None,
            scroll: px(0.),
            dragging: false,
            caret: true,
            reveal_caret: true,
        }
    }
    pub fn command(&mut self, command: Command, cx: &mut Context<Self>) {
        let previous = self.input.text().to_owned();
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
                if let Some(text) = cx.read_from_clipboard().and_then(|item| item.text()) {
                    self.input.replace(None, &text);
                }
            }
            Command::Undo => self.input.undo(),
            Command::Redo => self.input.redo(),
            _ => return,
        }
        self.caret = true;
        self.reveal_caret = true;
        if previous != self.input.text() {
            cx.emit(Edited);
        }
        cx.notify();
    }
    fn line_edge(&mut self, end: bool, extend: bool) {
        if let Some(layout) = &self.layout
            && layout.text == self.input.text()
            && !layout.lines.is_empty()
        {
            let mut position = layout.position(self.input.cursor());
            position.x = if end {
                layout.bounds.right() + px(1.)
            } else {
                layout.bounds.left() - px(1.)
            };
            position.y += px(LINE_HEIGHT / 2.);
            let next = layout.index(position);
            let anchor = if extend {
                if self.input.reversed() {
                    self.input.selection().end
                } else {
                    self.input.selection().start
                }
            } else {
                next
            };
            self.input.select(anchor, next);
        } else {
            self.input.edge(end, extend);
        }
    }
    fn key(&mut self, event: &KeyDownEvent, _: &mut Window, cx: &mut Context<Self>) {
        if self.input.marked.is_some() {
            return;
        }
        let previous = self.input.text().to_owned();
        let mods = event.keystroke.modifiers;
        let word = if cfg!(target_os = "macos") {
            mods.alt
        } else {
            mods.control
        };
        let edge = cfg!(target_os = "macos") && mods.platform;
        match event.keystroke.key.as_str() {
            "enter" => self.input.replace(None, "\n"),
            "left" | "right" => {
                let forward = event.keystroke.key == "right";
                if edge {
                    self.line_edge(forward, mods.shift);
                } else {
                    self.input.move_cursor(forward, mods.shift, word);
                }
            }
            "home" | "end" => {
                let end = event.keystroke.key == "end";
                if mods.control {
                    self.input.edge(end, mods.shift);
                } else {
                    self.line_edge(end, mods.shift);
                }
            }
            "up" | "down" => {
                if let Some(layout) = &self.layout {
                    let mut position = layout.position(self.input.cursor());
                    position.y += px(if event.keystroke.key == "up" {
                        -LINE_HEIGHT / 2.
                    } else {
                        LINE_HEIGHT * 1.5
                    });
                    let index = layout.index(position);
                    let anchor = if mods.shift {
                        if self.input.reversed() {
                            self.input.selection().end
                        } else {
                            self.input.selection().start
                        }
                    } else {
                        index
                    };
                    self.input.select(anchor, index);
                }
            }
            "backspace" | "delete" => {
                let forward = event.keystroke.key == "delete";
                if edge && self.input.selection().is_empty() {
                    self.line_edge(forward, true);
                    if !self.input.selection().is_empty() {
                        self.input.replace(None, "");
                    }
                } else {
                    self.input.delete(forward, word);
                }
            }
            _ => return,
        }
        self.caret = true;
        self.reveal_caret = true;
        if previous != self.input.text() {
            cx.emit(Edited);
        }
        cx.stop_propagation();
        cx.notify();
    }
}
impl EntityInputHandler for ComposerInput {
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
        _: bool,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<UTF16Selection> {
        Some(UTF16Selection {
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
        let previous = self.input.text().to_owned();
        self.input.replace(range, value);
        self.caret = true;
        self.reveal_caret = true;
        if previous != self.input.text() {
            cx.emit(Edited);
        }
        cx.notify();
    }
    fn replace_and_mark_text_in_range(
        &mut self,
        range: Option<Range<usize>>,
        value: &str,
        selection: Option<Range<usize>>,
        _: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let previous = self.input.text().to_owned();
        self.input.replace_marked(range, value, selection);
        self.caret = true;
        self.reveal_caret = true;
        if previous != self.input.text() {
            cx.emit(Edited);
        }
        cx.notify();
    }
    fn bounds_for_range(
        &mut self,
        range: Range<usize>,
        _: Bounds<Pixels>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<Bounds<Pixels>> {
        let layout = self.layout.as_ref()?;
        if layout.text != self.input.text() || layout.lines.is_empty() {
            return None;
        }
        let range = self.input.from_utf16(range);
        let start = layout.position(range.start);
        let end = layout.position(range.end);
        Some(Bounds::new(
            start,
            size(
                if start.y == end.y {
                    (end.x - start.x).max(px(1.))
                } else {
                    px(1.)
                },
                px(LINE_HEIGHT),
            ),
        ))
    }
    fn character_index_for_point(
        &mut self,
        point: Point<Pixels>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<usize> {
        let index = self.layout.as_ref()?.index(point);
        Some(self.input.to_utf16(index..index).start)
    }
}

struct Painted {
    layout: Layout,
    selection: Vec<Bounds<Pixels>>,
    caret: Option<Bounds<Pixels>>,
    color: Hsla,
}
impl Render for ComposerInput {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let focused = self.focus.is_focused(window);
        let dark = self.dark;
        let entity = cx.entity();
        let paint_entity = entity.clone();
        let canvas = canvas(
            move |bounds, window, cx| {
                let field = entity.read(cx);
                let actual = !field.input.text().is_empty();
                let display = if actual {
                    field.input.text().to_owned()
                } else {
                    field.placeholder.clone()
                };
                let color = if actual {
                    super::primary(dark)
                } else {
                    palette::CONTROL_GLYPH.resolve(dark)
                };
                let base = TextRun {
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
                    .filter(|(r, _)| !r.is_empty())
                    .map(|(range, marked)| TextRun {
                        len: range.len(),
                        underline: marked.then_some(UnderlineStyle {
                            thickness: px(1.),
                            color: Some(color),
                            wavy: false,
                        }),
                        ..base.clone()
                    })
                    .collect::<Vec<_>>()
                } else {
                    vec![base]
                };
                let shaped = window
                    .text_system()
                    .shape_text(
                        display.into(),
                        px(13.),
                        &runs,
                        Some(bounds.size.width.max(px(1.))),
                        None,
                    )
                    .unwrap_or_default();
                let mut start = 0;
                let mut top = px(0.);
                let lines = shaped
                    .into_iter()
                    .map(|line| {
                        let result = Line {
                            start,
                            top,
                            layout: line,
                        };
                        start += result.layout.len() + 1;
                        top += result.layout.size(px(LINE_HEIGHT)).height;
                        result
                    })
                    .collect::<Vec<_>>();
                let mut layout = Layout {
                    lines,
                    bounds,
                    scroll: field.scroll,
                    actual,
                    content_height: top,
                    text: field.input.text().to_owned(),
                };
                if focused && actual && field.reveal_caret && !layout.lines.is_empty() {
                    let cursor = layout.position(field.input.cursor());
                    if cursor.y < bounds.top() {
                        layout.scroll = (layout.scroll - (bounds.top() - cursor.y)).max(px(0.));
                    } else if cursor.y + px(LINE_HEIGHT) > bounds.bottom() {
                        layout.scroll += cursor.y + px(LINE_HEIGHT) - bounds.bottom();
                    }
                }
                layout.scroll = layout.scroll.min((top - bounds.size.height).max(px(0.)));
                let mut selection = Vec::new();
                let selected = field.input.selection();
                if focused && actual && !selected.is_empty() {
                    for line in &layout.lines {
                        let start = selected
                            .start
                            .saturating_sub(line.start)
                            .min(line.layout.len());
                        let end = selected
                            .end
                            .saturating_sub(line.start)
                            .min(line.layout.len());
                        if end <= start {
                            continue;
                        }
                        let mut breaks = vec![start];
                        for boundary in line.layout.wrap_boundaries() {
                            let index =
                                line.layout.runs()[boundary.run_ix].glyphs[boundary.glyph_ix].index;
                            if index > start && index < end {
                                breaks.push(index);
                            }
                        }
                        breaks.push(end);
                        for segment in breaks.windows(2) {
                            let a = line
                                .layout
                                .position_for_index(segment[0], px(LINE_HEIGHT))
                                .unwrap_or_default();
                            let mut b = line
                                .layout
                                .position_for_index(segment[1], px(LINE_HEIGHT))
                                .unwrap_or_default();
                            // At a wrap boundary the API returns the end of the prior
                            // visual line; it is also the start of the next segment.
                            let mut x = a.x;
                            let mut y = a.y;
                            if segment[0] != start {
                                x = px(0.);
                                y += px(LINE_HEIGHT);
                            }
                            if b.y != y {
                                b.x = bounds.size.width;
                            }
                            selection.push(Bounds::new(
                                point(
                                    bounds.left() + x,
                                    bounds.top() + line.top + y - layout.scroll,
                                ),
                                size((b.x - x).max(px(1.)), px(LINE_HEIGHT)),
                            ));
                        }
                    }
                }
                let caret =
                    (focused && field.caret && selected.is_empty() && !layout.lines.is_empty())
                        .then(|| {
                            Bounds::new(
                                layout.position(field.input.cursor()),
                                size(px(1.), px(LINE_HEIGHT)),
                            )
                        });
                entity.update(cx, |field, _| {
                    field.scroll = layout.scroll;
                    field.reveal_caret = false;
                });
                Painted {
                    layout,
                    selection,
                    caret,
                    color: palette::ACCENT.resolve(dark),
                }
            },
            move |bounds, paint, window, cx| {
                let field = paint_entity.read(cx);
                window.handle_input(
                    &field.focus,
                    ElementInputHandler::new(bounds, paint_entity.clone()),
                    cx,
                );
                window.with_content_mask(Some(ContentMask { bounds }), |window| {
                    for rect in &paint.selection {
                        window.paint_quad(fill(*rect, paint.color.opacity(0.25)));
                    }
                    for line in &paint.layout.lines {
                        let origin =
                            point(bounds.left(), bounds.top() + line.top - paint.layout.scroll);
                        if let Err(error) = line.layout.paint(
                            origin,
                            px(LINE_HEIGHT),
                            TextAlign::Left,
                            None,
                            window,
                            cx,
                        ) {
                            eprintln!("tokenstat: composer painting failed: {error}");
                        }
                    }
                    if let Some(caret) = paint.caret {
                        window.paint_quad(fill(caret, paint.color));
                    }
                });
                paint_entity.update(cx, |field, _| field.layout = Some(paint.layout));
            },
        )
        .w_full()
        .h(px(HEIGHT));
        div()
            .id("chat-composer-input")
            .track_focus(&self.focus)
            .w_full()
            .cursor(CursorStyle::IBeam)
            .on_key_down(cx.listener(Self::key))
            .on_scroll_wheel(cx.listener(|field, event: &ScrollWheelEvent, window, cx| {
                if let Some(layout) = &field.layout {
                    let limit = (layout.content_height - layout.bounds.size.height).max(px(0.));
                    let delta = event.delta.pixel_delta(window.line_height()).y;
                    let next = (field.scroll - delta).max(px(0.)).min(limit);
                    if next != field.scroll {
                        field.scroll = next;
                        field.reveal_caret = false;
                        cx.stop_propagation();
                        cx.notify();
                    }
                }
            }))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|field, event: &MouseDownEvent, window, cx| {
                    field.focus.focus(window);
                    field.input.unmark();
                    let index = field
                        .layout
                        .as_ref()
                        .map(|layout| layout.index(event.position))
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
                    field.reveal_caret = true;
                    cx.stop_propagation();
                    cx.notify();
                }),
            )
            .on_mouse_move(cx.listener(|field, event: &MouseMoveEvent, _, cx| {
                if field.dragging
                    && let Some(layout) = &field.layout
                {
                    let index = layout.index(event.position);
                    let anchor = if field.input.reversed() {
                        field.input.selection().end
                    } else {
                        field.input.selection().start
                    };
                    field.input.select(anchor, index);
                    field.reveal_caret = true;
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
            .child(canvas)
    }
}
