// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
(function (root) {
  "use strict";

  // Keep one marker, rather than copying terminal history on every update.
  function TerminalScrollController(term, onReadingChanged) {
    var enabled = false;
    var reading = false;
    var marker = null;
    var restoring = false;
    var pendingWrites = 0;

    function setReading(value) {
      if (reading === value) return;
      reading = value;
      onReadingChanged(value);
    }
    function clearMarker() {
      if (marker) marker.dispose();
      marker = null;
    }
    function rememberPosition() {
      clearMarker();
      var buffer = term.buffer.active;
      var held = enabled && buffer.type === "normal" && buffer.viewportY < buffer.baseY;
      if (held) marker = term.registerMarker(buffer.viewportY - buffer.baseY - buffer.cursorY);
      setReading(held);
    }
    function restorePosition() {
      restoring = true;
      try {
        if (term.buffer.active.type !== "normal" || term.buffer.active.baseY === 0) {
          clearMarker();
          setReading(false);
        } else if (enabled && reading) {
          // Once the held line ages out, stay at the oldest retained output.
          term.scrollToLine(marker && !marker.isDisposed ? marker.line : 0);
          if (!marker || marker.isDisposed) rememberPosition();
        } else {
          term.scrollToBottom();
        }
      } finally { restoring = false; }
    }
    term.onScroll(function () {
      if (!restoring && !pendingWrites) rememberPosition();
    });

    this.setEnabled = function (value) {
      enabled = !!value;
      term.options.scrollOnUserInput = !enabled;
      if (!enabled) this.followLatest();
      else rememberPosition();
    };
    this.isEnabled = function () { return enabled; };
    this.isReading = function () { return reading; };
    this.followLatest = function () {
      clearMarker();
      setReading(false);
      restorePosition();
    };
    this.scrollLines = function (lines) {
      restoring = true;
      try { term.scrollLines(lines); } finally { restoring = false; }
      rememberPosition();
    };
    this.write = function (bytes, callback) {
      pendingWrites++;
      term.write(bytes, function () {
        pendingWrites--;
        restorePosition();
        if (callback) callback();
      });
    };
    this.resize = function (operation) {
      restoring = true;
      try { operation(); } finally { restoring = false; }
      restorePosition();
    };
  }

  root.TerminalScrollController = TerminalScrollController;
  if (typeof module !== "undefined") module.exports = TerminalScrollController;
})(typeof window !== "undefined" ? window : globalThis);
