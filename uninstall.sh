#!/usr/bin/env bash
# Remove the "Bonsai 2 · Prism llama.cpp" runtime from LM Studio and switch GGUF
# back to the newest stock CUDA 12 runtime.
set -euo pipefail

RUNTIME_NAME="llama.cpp-linux-x86_64-nvidia-cuda12-avx2-prism"
HUB_MODEL="prism-ml/ternary-bonsai-2-27b"
STOCK_PREFIX="llama.cpp-linux-x86_64-nvidia-cuda12-avx2-"

pause_if_clicked() { [ "${BONSAI_PAUSE:-0}" = 1 ] && read -rp "press Enter to close" _ || true; }

if [ -z "${LMSTUDIO_HOME:-}" ]; then
  if [ -s "$HOME/.lmstudio-home-pointer" ]; then
    LMSTUDIO_HOME="$(head -n1 "$HOME/.lmstudio-home-pointer")"
  else
    LMSTUDIO_HOME="$HOME/.lmstudio"
  fi
fi
BACKENDS="$LMSTUDIO_HOME/extensions/backends"
LMS="$LMSTUDIO_HOME/bin/lms"

STOCK="$(find "$BACKENDS" -maxdepth 1 -type d -name "${STOCK_PREFIX}[0-9]*" -printf '%f\n' 2>/dev/null \
  | sort -V | tail -n1)"
if [ -n "$STOCK" ] && [ -x "$LMS" ]; then
  echo "switching GGUF back to ${STOCK_PREFIX%-}@${STOCK#"$STOCK_PREFIX"}"
  timeout 20 "$LMS" runtime select "${STOCK_PREFIX%-}@${STOCK#"$STOCK_PREFIX"}" >/dev/null \
    || echo "  could not switch automatically - pick a runtime in LM Studio: Settings -> Runtime"
fi

found=0
for d in "$BACKENDS/$RUNTIME_NAME"-*; do
  [ -d "$d" ] || continue
  rm -rf "$d"
  echo "removed $d"
  found=1
done
if [ -d "$LMSTUDIO_HOME/hub/models/$HUB_MODEL" ]; then
  rm -rf "$LMSTUDIO_HOME/hub/models/$HUB_MODEL"
  echo "removed model settings $LMSTUDIO_HOME/hub/models/$HUB_MODEL"
fi
[ "$found" = 1 ] || echo "nothing to remove - the Prism runtime is not installed"

echo "done. Restart LM Studio if it is open."
pause_if_clicked
