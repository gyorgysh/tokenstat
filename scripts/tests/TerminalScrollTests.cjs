// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Exercise the shipped xterm parser, buffers, markers and asynchronous writes.
const assert = require("node:assert/strict");
global.self = global;
const { Terminal } = require("../../apps/android/app/src/main/assets/term/xterm.js");
const Scroll = require("../../apps/android/app/src/main/assets/term/term-scroll.js");

async function run(rows, cols) {
  const term = new Terminal({ rows, cols, scrollback: 40, allowProposedApi: true });
  // With no DOM, route viewport scroll requests to the shipped buffer service.
  // Parsing, trimming, reflow, marker disposal and scroll events remain real.
  term._core.viewport = {
    scrollLines: lines => term._core.scrollLines(lines, false, 1),
    syncScrollArea() {},
    reset() {},
  };
  const changes = [];
  const scroll = new Scroll(term, value => changes.push(value));
  const write = text => new Promise(resolve => scroll.write(text, resolve));
  const top = () => term.buffer.active.getLine(term.buffer.active.viewportY).translateToString(true);
  try {
    await write(Array.from({ length: 35 }, (_, i) => `line ${i}\r\n`).join(""));
    assert.equal(term.buffer.active.viewportY, term.buffer.active.baseY);
    scroll.setEnabled(true);
    scroll.scrollLines(-8);
    const held = top();
    assert.equal(scroll.isReading(), true);
    await write("live update\r\n\x1b[6n\x1b[?1000h");
    assert.equal(top(), held, "output and cursor reports retain the held line");
    await Promise.all([write("first burst\r\n"), write("second burst\r\n")]);
    assert.equal(top(), held, "queued writes retain the same anchor");
    scroll.resize(() => term.resize(cols + 10, rows - 2));
    assert.equal(top(), held, "keyboard/viewport resizing retains the anchor");
    await write(Array.from({ length: 5 }, (_, i) => `trim ${i}\r\n`).join(""));
    assert.equal(top(), held, "bounded scrollback trimming adjusts the anchor");
    assert.ok(term.markers.length <= 1, "only one reading marker is retained");
    await write(Array.from({ length: 60 }, (_, i) => `new ${i}\r\n`).join(""));
    assert.equal(term.buffer.active.viewportY, 0, "an expired anchor holds the oldest retained output");
    assert.equal(scroll.isReading(), true);
    scroll.followLatest();
    assert.equal(scroll.isReading(), false);
    await write("latest\r\n");
    assert.equal(term.buffer.active.viewportY, term.buffer.active.baseY);
    scroll.scrollLines(-4);
    scroll.scrollLines(1000);
    assert.equal(scroll.isReading(), false, "scrolling to the bottom resumes following");
    scroll.scrollLines(-4);
    scroll.setEnabled(false);
    assert.equal(term.buffer.active.viewportY, term.buffer.active.baseY, "scroll off immediately follows");
    await write("off mode\r\n");
    assert.equal(term.buffer.active.viewportY, term.buffer.active.baseY);
    scroll.setEnabled(true);
    scroll.scrollLines(-5);
    await write("\x1b[?1049halternate\x1b[?1049l");
    assert.ok(term.buffer.active.viewportY <= term.buffer.active.baseY);
    await write("\x1bcreset\r\n");
    assert.equal(scroll.isReading(), false, "a reset clears expired reading state");
    assert.equal(term.markers.length, 0);
    assert.ok(changes.includes(true) && changes.includes(false));
  } finally { term.dispose(); }
}
(async () => {
  await run(10, 40);
  await run(20, 100);
  console.log("TerminalScrollTests: phone and tablet buffers passed");
})().catch(error => { console.error(error); process.exitCode = 1; });
