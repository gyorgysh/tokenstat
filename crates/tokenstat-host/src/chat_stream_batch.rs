// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Publish complete lines together, with a deadline for unfinished prose.
use crate::transcript::Event;
use std::time::{Duration, Instant};

const MAX_BYTES: usize = 64 * 1024;
const MAX_WAIT: Duration = Duration::from_millis(350);

pub(super) struct TextBatch {
    max_wait: Duration,
    pending: Option<Event>,
    since: Option<Instant>,
}

impl Default for TextBatch {
    fn default() -> Self {
        Self {
            max_wait: MAX_WAIT,
            pending: None,
            since: None,
        }
    }
}

impl TextBatch {
    pub(super) fn push(&mut self, events: Vec<Event>, now: Instant) -> Vec<Event> {
        let mut output = self.due(now);
        for event in events {
            let compatible = matches!(
                (&self.pending, &event),
                (Some(Event::Text { .. }), Event::Text { .. })
                    | (Some(Event::Thinking { .. }), Event::Thinking { .. })
            );
            if !compatible {
                output.extend(self.flush());
            }
            match event {
                Event::Text { delta } => self.text(delta, false, now, &mut output),
                Event::Thinking { delta } => self.text(delta, true, now, &mut output),
                event => output.push(event),
            }
        }
        output
    }

    fn text(&mut self, delta: String, thinking: bool, now: Instant, output: &mut Vec<Event>) {
        let previous = self.pending.as_ref().map_or(0, |event| match event {
            Event::Text { delta } | Event::Thinking { delta } => delta.len(),
            _ => unreachable!(),
        });
        if previous.saturating_add(delta.len()) > MAX_BYTES {
            output.extend(self.flush());
        }
        if self.pending.is_none() {
            self.since = Some(now);
            self.pending = Some(if thinking {
                Event::Thinking {
                    delta: String::new(),
                }
            } else {
                Event::Text {
                    delta: String::new(),
                }
            });
        }
        let text = match self.pending.as_mut().unwrap() {
            Event::Text { delta } | Event::Thinking { delta } => delta,
            _ => unreachable!(),
        };
        text.push_str(&delta);
        if text.len() >= MAX_BYTES {
            output.extend(self.flush());
        } else if let Some(end) = text.rfind('\n') {
            let rest = text.split_off(end + 1);
            output.extend(self.flush());
            if !rest.is_empty() {
                self.pending = Some(if thinking {
                    Event::Thinking { delta: rest }
                } else {
                    Event::Text { delta: rest }
                });
                self.since = Some(now);
            }
        }
    }

    pub(super) fn wait(&self, now: Instant, fallback: Duration) -> Duration {
        self.since.map_or(fallback, |since| {
            self.max_wait
                .saturating_sub(now.saturating_duration_since(since))
                .min(fallback)
        })
    }

    pub(super) fn due(&mut self, now: Instant) -> Vec<Event> {
        if self
            .since
            .is_some_and(|since| now.saturating_duration_since(since) >= self.max_wait)
        {
            self.flush()
        } else {
            Vec::new()
        }
    }

    pub(super) fn flush(&mut self) -> Vec<Event> {
        self.since = None;
        self.pending.take().into_iter().collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn text(s: &str) -> Event {
        Event::Text { delta: s.into() }
    }
    fn content(events: &[Event]) -> String {
        events
            .iter()
            .map(|event| match event {
                Event::Text { delta } => delta.as_str(),
                _ => panic!("unexpected event"),
            })
            .collect()
    }
    #[test]
    fn complete_lines_publish_without_partial_next_line() {
        let now = Instant::now();
        let mut batch = TextBatch::default();
        assert!(batch.push(vec![text("Hello ")], now).is_empty());
        let output = batch.push(vec![text("🌍\nNext")], now + Duration::from_millis(40));
        assert_eq!(content(&output), "Hello 🌍\n");
        assert_eq!(content(&batch.flush()), "Next");
    }
    #[test]
    fn continued_tokens_do_not_extend_the_deadline() {
        let now = Instant::now();
        let mut batch = TextBatch::default();
        for tick in 0..7 {
            assert!(
                batch
                    .push(vec![text("word ")], now + Duration::from_millis(tick * 50))
                    .is_empty()
            );
        }
        assert_eq!(
            batch.wait(now + Duration::from_millis(349), Duration::from_secs(1)),
            Duration::from_millis(1)
        );
        assert_eq!(content(&batch.due(now + MAX_WAIT)), "word ".repeat(7));
        assert!(batch.flush().is_empty());
    }
    #[test]
    fn event_boundaries_and_finish_preserve_order_and_exact_bytes() {
        let now = Instant::now();
        let mut batch = TextBatch::default();
        let output = batch.push(
            vec![
                text("reply"),
                Event::Thinking {
                    delta: "think".into(),
                },
                Event::Session {
                    id: "session".into(),
                },
                text("tail"),
            ],
            now,
        );
        assert_eq!(
            serde_json::to_value(&output).unwrap(),
            serde_json::to_value(vec![
                text("reply"),
                Event::Thinking {
                    delta: "think".into()
                },
                Event::Session {
                    id: "session".into()
                }
            ])
            .unwrap()
        );
        assert_eq!(content(&batch.flush()), "tail");
    }
    #[test]
    fn large_chunks_are_bounded_without_splitting_unicode() {
        let now = Instant::now();
        let mut batch = TextBatch::default();
        let large = "🌍".repeat(MAX_BYTES / 4 + 1);
        assert!(batch.push(vec![text("prefix")], now).is_empty());
        assert_eq!(
            content(&batch.push(vec![text(&large)], now)),
            format!("prefix{large}")
        );
        assert!(batch.flush().is_empty());
    }
    #[test]
    fn compare_readable_chunks_on_word_streams() {
        let words: Vec<String> = (0..120)
            .map(|i| format!("word{i}{}", if i < 48 && i % 12 == 11 { "\n" } else { " " }))
            .collect();
        let expected = words.concat();
        for wait_ms in [120, 240, 350, 500, 700] {
            let now = Instant::now();
            let mut batch = TextBatch {
                max_wait: Duration::from_millis(wait_ms),
                ..Default::default()
            };
            let mut emitted = Vec::new();
            let mut next = 0;
            for tick in 0..=500 {
                let elapsed = tick * 10;
                let mut events = Vec::new();
                while next < words.len() && next as u64 * 37 <= elapsed {
                    events.push(text(&words[next]));
                    next += 1;
                }
                for event in batch.push(events, now + Duration::from_millis(elapsed)) {
                    emitted.push((elapsed, event));
                }
            }
            assert_eq!(next, words.len());
            assert!(
                batch.flush().is_empty(),
                "idle tail must publish before completion"
            );
            let actual: String = emitted
                .iter()
                .map(|(_, event)| match event {
                    Event::Text { delta } => delta.as_str(),
                    _ => unreachable!(),
                })
                .collect();
            assert_eq!(actual, expected);
            let mut consumed = 0;
            let mut max_delay = 0;
            for (at, event) in &emitted {
                let Event::Text { delta } = event else {
                    unreachable!()
                };
                let end = consumed + delta.len();
                let mut offset = 0;
                for (index, word) in words.iter().enumerate() {
                    if offset >= consumed && offset < end {
                        max_delay = max_delay.max(at - index as u64 * 37);
                    }
                    offset += word.len();
                }
                consumed = end;
            }
            assert!(max_delay <= wait_ms + 20);
            println!(
                "word stream: cap={wait_ms}ms updates={} original=120 max_delay={max_delay}ms",
                emitted.len()
            );
        }
    }
}
