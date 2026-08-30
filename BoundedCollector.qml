import QtQuick
import Quickshell.Io

// A process-output collector that hands downstream a bounded amount of text.
//
// Why this is built on `StdioCollector` and not on `SplitParser`
// -------------------------------------------------------------
// Capping as the data arrives — appending each `SplitParser` line into a string
// and trimming the front — bounds memory more tightly, and was the first shape
// of this component. It was wrong for one reason: nothing documents that every
// `read` has been delivered by the time `Process.exited` fires, so the parsed
// status document could be silently short. The type metadata bears that out —
// `SplitParser` exposes only `splitMarker` and the inherited `read` signal,
// while `StdioCollector` is the type that carries `waitForEnd` and
// `streamFinished`, which exist precisely to express "the stream is complete".
// A truncated status document is a wrong panel; a larger transient buffer is
// not. So: collect with the guarantee, and bound what is passed on.
//
// The transient size is bounded anyway, from the other end: every daemon
// invocation is wrapped in `timeout` (8 s for status and down, 130 s for the
// blocking login), so a CLI that decides to narrate can only do so for that
// long before it is killed.
//
// What is kept
// ------------
// The **tail**. For `netbird status --json` the document is printed after any
// gRPC warning chatter, so keeping the head would preserve the noise and throw
// away the answer; for `up` and `down` the useful line — the SSO prompt, the
// failure — is likewise last. One rule, and it is the right one in each case.
//
// `tail` is exactly what the process wrote, minus anything trimmed off the
// front: no lines are joined or dropped by this component.
StdioCollector {
  id: root

  // Bytes to hand downstream. The default suits a status document; callers
  // that only ever see short messages set something much smaller.
  property int limit: 262144

  // Read this rather than `text`. Valid once the stream has finished, which
  // `waitForEnd` guarantees has happened before `Process.exited`.
  readonly property string tail: text.length > limit
    ? text.substring(text.length - limit)
    : text

  waitForEnd: true
}
