#!/bin/bash
# Loads Service.qml and Panel.qml in a throwaway quickshell against the
# installed Omarchy kit, so a QML error (a duplicate property, a type that no
# longer exists, a broken binding) fails here instead of on a user's bar.
# Needs an Omarchy desktop: quickshell on PATH, a Wayland session, and the kit
# at $OMARCHY_PATH/shell. Nothing is touched: no NetBird, no bar, no config.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
KIT="${OMARCHY_PATH:-/usr/share/omarchy}/shell"

if ! command -v quickshell >/dev/null || [[ -z ${WAYLAND_DISPLAY:-} ]] || [[ ! -d $KIT/Ui ]]; then
  echo "skip - smoke load needs quickshell, a Wayland session and the Omarchy kit"
  exit 0
fi

stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
ln -s "$KIT/Ui" "$stage/Ui"
ln -s "$KIT/Commons" "$stage/Commons"
cat >"$stage/shell.qml" <<EOF
import Quickshell
import QtQuick

ShellRoot {
  Component.onCompleted: {
    var fails = []
    var files = ["Service.qml", "Panel.qml"]
    for (var i = 0; i < files.length; i++) {
      var comp = Qt.createComponent("file://$ROOT/" + files[i])
      if (comp.status === Component.Error) { fails.push(files[i] + ": " + comp.errorString().trim()); continue }
      var obj = comp.createObject(null, files[i] === "Panel.qml" ? { moduleName: "mikebenner.netbird" } : {})
      if (!obj) fails.push(files[i] + ": createObject returned null")
    }
    console.log(fails.length ? "RESULT fail " + fails.join(" | ") : "RESULT pass")
    Qt.quit()
  }
}
EOF

output=$(timeout 30 quickshell -p "$stage" --no-color 2>&1 || true)
if [[ $output == *"RESULT pass"* ]]; then
  echo "ok - Service.qml and Panel.qml load against the installed kit"
  exit 0
fi
printf '%s\n' "$output" | grep -E 'RESULT|netbird/|/omarchy-netbird/' >&2 || printf '%s\n' "$output" | tail -20 >&2
echo "not ok - Service.qml and Panel.qml load against the installed kit" >&2
exit 1
