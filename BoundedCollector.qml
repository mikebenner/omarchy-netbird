import QtQuick
import Quickshell.Io
import "Model.js" as Model

// A process-output collector whose *retained* text is bounded, and whose
// result is complete by the time `Process.exited` runs.
//
// Completeness — settled from the quickshell source, not assumed
// -------------------------------------------------------------
// Cited against the installed version, quickshell 0.3.1, at the tag rather
// than a branch, so the quotes below can be checked as written:
//
//   https://github.com/quickshell-mirror/quickshell/blob/v0.3.1/src/io/process.cpp#L274-L287
//   https://github.com/quickshell-mirror/quickshell/blob/v0.3.1/src/io/datastream.cpp#L101-L103
//
// The line numbers in this file's own history were wrong — earlier revisions
// cited `process.cpp:254-266` and `datastream.cpp:39-96`, which at that tag
// are `Process::onFinished`'s neighbours and `DataStream::onBytesAvailable`,
// not the code that carries the guarantee. Those numbers were carried forward
// from review to review without being re-fetched. The two lines that actually
// carry it, quoted so they can be found even if the numbering shifts again:
//
//   process.cpp:277   if (this->mStdoutParser) this->mStdoutParser->streamEnded(this->stdoutBuffer);
//   process.cpp:282   emit this->exited(exitCode, exitStatus);
//
// `Process::onFinished` (`process.cpp:274-287`) runs in that order: it clears
// the running process, calls `streamEnded` on the stdout parser and then the
// stderr one (`:277-278`), and only after that emits `exited` (`:282`).
//
// And the flush those calls perform, `datastream.cpp:101-103` in full:
//
//   void SplitParser::streamEnded(QByteArray& buffer) {
//       if (!buffer.isEmpty()) emit this->read(QString(buffer));
//   }
//
// Whole lines are already delivered as they arrive — `SplitParser::parseBytes`
// (`datastream.cpp:43-99`) emits each delimiter-terminated chunk at `:85` — so
// between the two, every line plus the trailing partial one has been handed to
// `onRead` before `exited` fires. A `SplitParser` therefore *has* a
// completeness guarantee; it is expressed as ordering rather than as a signal,
// which is why the type carries no `waitForEnd`. `tail` is final in the exit
// handler.
//
// That settles the question that made an earlier revision fall back to
// `StdioCollector`: there is no need to trade bounded retention for
// completeness, so the streaming design is used for every process here.
//
// What `limit` does NOT bound — and what actually does
// ----------------------------------------------------
// `limit` caps only the text this component retains across lines. The
// per-line buffer lives inside quickshell itself: with no delimiter in the
// incoming bytes, `parseBytes` appends them to the Process-owned buffer and
// emits nothing (`datastream.cpp:91-92`, `buffer.append(incoming)`), so a
// single line with no newline grows that buffer for as long as the stream
// runs — and nothing reachable from QML can cap it. The real ceiling on such
// a producer is time, not memory: every command here is argv `timeout -k 2 8`
// (`timeout -k 5 130` for login), so an endless unterminated line is cut off
// when its process is killed, at most seconds in.
//
// What is kept
// ------------
// The **tail**. For `netbird status --json` the document is printed after any
// gRPC warning chatter, so keeping the head would preserve the noise and
// discard the answer; for `up`, `down`, `networks` and `profile` the useful
// line — the prompt, the failure — is likewise last.
//
// Trimming is `Model.trimToLimit`: whole lines from the front, and for the one
// case with no line boundary to land on (a single line longer than the whole
// budget) the cut steps off a low surrogate so the result never begins with
// half a code point. `limit` counts UTF-16 code units, not bytes.
SplitParser {
  id: root

  // Approximate ceiling on retained text, in UTF-16 code units. Whole lines are
  // dropped from the front until the buffer is under it, so the real figure is
  // this plus at most one line.
  property int limit: 262144

  // Everything retained so far, oldest lines dropped first.
  property string text: ""

  // True once anything was dropped. Read by `Service` when it reports a
  // failure, so a truncated message is never presented as the whole story.
  property bool truncated: false

  // What callers read. Named apart from `text` so a reader cannot accidentally
  // depend on an untrimmed value that no longer exists.
  readonly property string tail: text

  function reset() {
    text = ""
    truncated = false
  }

  onRead: function(line) {
    var chunk = String(line === undefined || line === null ? "" : line)
    var next = text === "" ? chunk : text + "\n" + chunk

    if (next.length > limit) {
      next = Model.trimToLimit(next, limit)
      truncated = true
    }

    text = next
  }
}
