import QtQuick
import Quickshell.Io
import "Model.js" as Model

// A process-output collector whose memory is bounded *while* collecting, and
// whose result is complete by the time `Process.exited` runs.
//
// Completeness — settled from the quickshell source, not assumed
// -------------------------------------------------------------
// quickshell v0.3.1 (the installed version), `src/io/process.cpp`,
// `Process::onFinished` at lines 274-286:
//
//     if (this->mStdoutParser) this->mStdoutParser->streamEnded(this->stdoutBuffer);
//     if (this->mStderrParser) this->mStderrParser->streamEnded(this->stderrBuffer);
//     ...
//     emit this->exited(exitCode, exitStatus);
//
// and `src/io/datastream.cpp`, `SplitParser::streamEnded` at lines 101-103:
//
//     if (!buffer.isEmpty()) emit this->read(QString(buffer));
//
// So every whole line has already been delivered by `parseBytes` as it
// arrived, the trailing partial line is flushed by `streamEnded`, and only
// then is `exited` emitted. A `SplitParser` therefore *has* a completeness
// guarantee — it is expressed as ordering rather than as a signal, which is
// why the type carries no `waitForEnd`. `tail` is final in the exit handler.
//
// That settles the question that made an earlier revision fall back to
// `StdioCollector`: there is no need to trade bounded memory for completeness,
// so the streaming design is used for every process here.
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
