# NetBird Omarchy Widget

Omarchy bar widget for [NetBird](https://netbird.io), modeled on the
first-party `omarchy.tailscale` widget: the same bar icon, the same
keyboard-driven popup, the same power switch in the hero, and the same copy
menus. Everything it knows comes from the `netbird` CLI.

<!-- screenshot: bar icon + open panel — add docs/screenshot.png -->

## Features

- Shows the NetBird daemon's state in the bar, with the connected/total peer
  count in the bar tooltip and in the hero
- Left click opens a keyboard-friendly panel
- Right click toggles NetBird on/off, middle click refreshes
- Hero line carries the management host and how long the current session has
  left ("session expires in 1d 6h")
- This device's FQDN, NetBird address, and relay availability on one row, with
  a copy menu
- Every peer from `netbird status --json`, sorted by name, each with a status
  glyph — bright for `Connected`, dimmed for `Connecting` and `Idle`, crossed
  for `Disconnected`. Lazy connections leave healthy peers idle for hours, so
  an online-only list would look like an empty network.
- Copy a peer's name, FQDN, or NetBird address
- SSO login: when the daemon needs to re-authenticate, the widget runs
  `netbird up --no-browser`, picks the login URL out of its output, and hands
  it to `omarchy-launch-browser`

## Keyboard shortcuts

Inside the panel:

- `j` / `k` or arrows: move cursor
- `enter` / `space`: activate current row (toggle on the hero, copy menu on a
  device or peer row)
- `c`: copy the selected row's NetBird address
- `n`: copy the selected row's short name
- `d`: copy the selected row's FQDN
- `t`: toggle NetBird
- `r`: refresh status
- `esc`: close

## Install

```bash
omarchy plugin add https://github.com/mikebenner/omarchy-netbird.git --enable
```

Then place it in the bar, e.g. next to the network widget:

```bash
omarchy plugin enable mikebenner.netbird --section right --before omarchy.network
```

## Settings

Settings live inline on the widget's entry in `~/.config/omarchy/shell.json`.

| Key | Type | Default | Range | What it does |
|---|---|---|---|---|
| `refreshIntervalSec` | integer | `30` | 5–3600 | How often `netbird status --json` is polled |

## IPC

```bash
omarchy-shell mikebenner.netbird open      # open the panel
omarchy-shell mikebenner.netbird close     # close the panel
omarchy-shell mikebenner.netbird toggle    # toggle the panel
omarchy-shell mikebenner.netbird refresh   # re-poll netbird status
omarchy-shell mikebenner.netbird up        # netbird up (SSO login when needed)
omarchy-shell mikebenner.netbird down      # netbird down
omarchy-shell mikebenner.netbird status    # one-line summary of the mesh
```

`status` answers with the daemon state, this device's name and address, the
peer count, and the session clock, e.g.

```
Connected · laptop · 100.64.0.9 · 1/4 peers · session expires in 1d 6h
```

## Replaces netbird-ui-bin

This widget is meant to take the place of the `netbird-ui` tray app. Nothing
here uninstalls it — disable its autostart yourself once you're happy with the
widget.

The autostart entry is a user file, not a packaged one. It is not launched
directly, though: `systemd-xdg-autostart-generator` turns it into a systemd
user unit at login, so the desktop file is what to edit and the unit is what
to stop.

```bash
# what the generator made of it
systemctl --user list-units 'app-netbird*' --all
#   UNIT                          LOAD   ACTIVE   SUB     DESCRIPTION
#   app-netbird@autostart.service loaded <active> <state> NetBird
```

Stop autostarting it, by setting `Hidden=true` in the desktop file — the
generator then skips it at the next login:

```bash
sed -i 's/^Hidden=false$/Hidden=true/' ~/.config/autostart/netbird.desktop
```

Removing the file (`rm ~/.config/autostart/netbird.desktop`) works too, but
`Hidden=true` is reversible.

Either way the tray app already running in this session keeps running. Stop it
through its unit rather than by signalling the process, so systemd does not
count it as a crash:

```bash
systemctl --user stop 'app-netbird@autostart.service'
```

The `netbird` daemon and the `netbird` CLI are untouched — the widget needs
both.

## Requirements

- `netbird` CLI on `PATH`, with the daemon running
- `wl-copy` for the copy actions
- `omarchy-launch-browser` for SSO login

No privilege escalation: `/var/run/netbird.sock` is world-writable, so
`status`, `up`, and `down` all run as you. There is no equivalent of
Tailscale's `tailscale set --operator` handshake and the widget never asks for
one.

## What was dropped from the Tailscale widget

NetBird has no analogue for these, so they are simply gone: exit nodes,
Mullvad regions, account/profile switching, Taildrop file sending, and the
operator authorization row.

## Icon

`NetbirdIcon.qml` draws the NetBird mark natively as two flat wing polygons on
a `Canvas`, the same reasoning as the Tailscale widget's dot grid: straight
edges survive an 11px bar slot where a scaled image or a curved silhouette
turns to mush.

## Tests

`Model.js` holds all the parsing and formatting and is loadable by both QML
(`import "Model.js" as Model`) and Node.

```bash
node --test test/
```

Fixtures under `test/fixtures/` are synthetic `netbird status --json`
documents — example hostnames, CGNAT addresses, and fake keys. No real mesh
data is committed.

## License

MIT — see [LICENSE](LICENSE).
