# Changelog

## 1.0.0 — 2026-10-15

The daemon state machine moved out of the bar widget into the plugin's own `service` entry point. The shell loads it once and every monitor's widget reads the same instance, so there is one `netbird status` poll per interval instead of one per monitor, one toggle gate, and bar icons that agree the instant you click.

Brought up to the conventions Omarchy's own panels follow since this plugin was written:

- The panel card is built on first open rather than at startup (`KeyboardPanel.content`).
- The palette singleton is qualified for Qt 6.12 (`Commons.Color`).
- Every `Text` that renders a value from the daemon or the management server declares `textFormat: Text.PlainText`, so a peer named `<img src=…>` can never make the shell fetch anything.
- IPC answers over the shell's own socket (`ShellIpc`), so `omarchy-shell mikebenner.netbird …` no longer pays the `qs ipc` startup on every call.
- The bar glyph is sized and centred the way the kit's own icons are.

Fixed: peer rows sat flush against the row edge (anchors margins on an unanchored layout). Renamed the icon's `state` to `status` so it is not read as Qt's state machine. New preview and screenshots; source-level tests guard every convention above.

## 0.1.1 — 2026-09-05

Networks, profiles, per-peer detail, SSH and ping, relay list, version notice.

## 0.1.0 — 2026-08-31

First release: bar glyph, keyboard-driven panel, peers with copy menus, SSO login.
