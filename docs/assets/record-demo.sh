#!/usr/bin/env bash
# Record a VibeGuard demo showing real hook interceptions.
#
# Output:
#   docs/assets/demo.cast   — raw asciinema recording (asciicast-v2)
#   docs/assets/demo.gif    — rendered GIF (via agg)
#
# Prerequisites:
#   brew install asciinema agg
#   VibeGuard repo checked out (this script auto-detects via $VG or relative path)
#
# Usage:
#   bash docs/assets/record-demo.sh          # record + render
#   bash docs/assets/record-demo.sh --play   # replay existing cast
#   bash docs/assets/record-demo.sh --render # re-render GIF from cast

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAST_FILE="${SCRIPT_DIR}/demo.cast"
GIF_FILE="${SCRIPT_DIR}/demo.gif"
SCENARIO_SCRIPT="${SCRIPT_DIR}/demo-scenario.sh"

render_gif() {
  if ! command -v agg >/dev/null 2>&1; then
    echo "agg not found. Install with: brew install agg" >&2
    return 1
  fi
  agg --cols 90 --rows 28 --font-size 16 --theme monokai "${CAST_FILE}" "${GIF_FILE}"
  echo "Rendered: ${GIF_FILE}"
}

case "${1:-record}" in
  --play)
    asciinema play "${CAST_FILE}"
    ;;
  --render)
    render_gif
    ;;
  record|"")
    if ! command -v asciinema >/dev/null 2>&1; then
      echo "asciinema not found. Install with: brew install asciinema" >&2
      exit 1
    fi
    echo "Recording demo to ${CAST_FILE} ..."
    asciinema rec \
      --overwrite \
      --output-format asciicast-v2 \
      --window-size 90x28 \
      --idle-time-limit 1.5 \
      --command "bash ${SCENARIO_SCRIPT}" \
      "${CAST_FILE}"
    render_gif || echo "GIF render skipped. Run: $0 --render"
    ;;
  *)
    echo "Unknown arg: $1" >&2
    echo "Usage: $0 [record|--play|--render]" >&2
    exit 2
    ;;
esac
