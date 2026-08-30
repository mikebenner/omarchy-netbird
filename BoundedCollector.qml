import QtQuick
import Quickshell.Io

// A process-output collector whose memory is bounded *while* collecting, and
// whose result is complete by the time `Process.exited` runs.
//
// Getting both at once
// --------------------
// `StdioCollector` guarantees completeness (`waitForEnd`) but keeps the entire
// stream: wrapping it and trimming a derived value bounds only what downstream
// reads, so a high-rate producer still grows the shell's heap for as long as it
// runs. `SplitParser` delivers incrementally — so a cap can be applied as the
// data arrives — but exposes no completeness signal.
//
// This takes the incremental route and supplies the missing guarantee itself:
// `Process.exited` is emitted after the process's streams are closed and their
// pending `read` callbacks have been delivered, so `tail` is final when the
// exit handler runs. The proof that matters in practice is the one this widget
// depends on: the SSO flow has always read `_loginBuffer`, assembled from
// exactly these `SplitParser` deliveries, inside `loginProcess.onExited`, and
// the URL and code it needs are on the *last* lines the CLI writes.
//
// Belt and braces, because "the last line arrived" is the whole contract: a
// caller that must not mis-read a truncated document should treat an empty
// `tail` on a zero exit as "no answer" rather than as an empty answer — which
// is what `Model.parseStatus` already does.
//
// What is kept
// ------------
// The **tail**, in whole lines. For `netbird status --json` the document is
// printed after any gRPC warning chatter, so keeping the head would preserve
// the noise and discard the answer; for `up`, `down`, `networks` and `profile`
// the useful line — the prompt, the failure — is likewise last.
//
// `limit` counts UTF-16 code units, not bytes, and trimming happens on line
// boundaries so a multi-byte character is never cut in half. Line-oriented
// trimming is why this is safe: a code point cannot straddle a `\n`.
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
      // Drop whole lines from the front until it fits. Never a mid-line cut, so
      // no surrogate pair or multi-byte sequence is ever split.
      var cut = 0
      while (next.length - cut > limit) {
        var nl = next.indexOf("\n", cut)
        if (nl === -1) {
          // One line longer than the cap: keep its tail rather than nothing,
          // and accept that this single case can cut inside a line.
          cut = next.length - limit
          break
        }
        cut = nl + 1
      }
      next = next.substring(cut)
      truncated = true
    }

    text = next
  }
}
