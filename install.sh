#!/usr/bin/env bash
# Add a "Bonsai 2 (Prism)" llama.cpp runtime to LM Studio on Linux, so the
# PQ2_0 / PTQ1_0 GGUF packs of Ternary-Bonsai-2 load.
#
# Nothing of LM Studio's own is modified: a new runtime folder is created next
# to the stock ones under ~/.lmstudio/extensions/backends/. Remove it with
# ./uninstall.sh.
#
#   ./install.sh                 pinned Prism release, select the new runtime
#   ./install.sh --latest        newest Prism release instead of the pinned one
#   ./install.sh --no-select     install but keep the current runtime selected
#
# Env: PRISM_TAG (release tag), PRISM_ARCHIVE (local .tar.gz, skips download),
#      LMSTUDIO_HOME (defaults to ~/.lmstudio-home-pointer, then ~/.lmstudio).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRISM_REPO="PrismML-Eng/llama.cpp"
PRISM_TAG="${PRISM_TAG:-prism-b10709-9a9394a}"
PRISM_CUDA="12.8"                      # matches LM Studio's CUDA 12.8 vendor libs
RUNTIME_NAME="llama.cpp-linux-x86_64-nvidia-cuda12-avx2-prism"
HUB_MODEL="prism-ml/ternary-bonsai-2-27b"   # model.yaml with the reasoning-effort selector
TEMPLATE_PREFIX="llama.cpp-linux-x86_64-nvidia-cuda12-avx2-"
SELECT=1

for arg in "$@"; do
  case "$arg" in
    --latest)    PRISM_TAG="latest" ;;
    --no-select) SELECT=0 ;;
    -h|--help)   sed -n '2,16p' "$0"; exit 0 ;;
    *)           echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; pause_if_clicked; exit 1; }
# Set by the double-click launcher, so the window stays open to read the result.
pause_if_clicked() { [ "${BONSAI_PAUSE:-0}" = 1 ] && read -rp "press Enter to close" _ || true; }

[ "$(uname -s)" = "Linux" ] || die "this script is for Linux (use Install-Windows.bat on Windows)"
[ "$(uname -m)" = "x86_64" ] || die "only x86_64 is supported"
command -v python3 >/dev/null || die "python3 is required"
command -v curl >/dev/null || die "curl is required"

# ---- locate LM Studio -------------------------------------------------------
if [ -z "${LMSTUDIO_HOME:-}" ]; then
  if [ -s "$HOME/.lmstudio-home-pointer" ]; then
    LMSTUDIO_HOME="$(head -n1 "$HOME/.lmstudio-home-pointer")"
  else
    LMSTUDIO_HOME="$HOME/.lmstudio"
  fi
fi
BACKENDS="$LMSTUDIO_HOME/extensions/backends"
LMS="$LMSTUDIO_HOME/bin/lms"
[ -d "$BACKENDS" ] || die "LM Studio runtimes not found in $BACKENDS (set LMSTUDIO_HOME)"
say "LM Studio: $LMSTUDIO_HOME"

command -v nvidia-smi >/dev/null && nvidia-smi --query-gpu=name,driver_version --format=csv,noheader \
  | sed 's/^/    GPU: /' || echo "    warning: nvidia-smi not found - is the NVIDIA driver installed?"

# ---- template: newest stock CUDA 12 runtime -----------------------------------
# Its LM Studio bindings (.node files) are reused as-is; only the llama-server
# that LM Studio spawns is swapped for Prism's build.
TEMPLATE="$(find "$BACKENDS" -maxdepth 1 -type d -name "${TEMPLATE_PREFIX}[0-9]*" -printf '%f\n' \
  | sort -V | tail -n1)"
[ -n "$TEMPLATE" ] || die "no stock 'CUDA 12 llama.cpp' runtime installed.
     In LM Studio open Settings -> Runtime, download 'CUDA 12 llama.cpp (Linux)', then rerun."
TEMPLATE_DIR="$BACKENDS/$TEMPLATE"
TEMPLATE_VERSION="${TEMPLATE#"$TEMPLATE_PREFIX"}"
grep -q '"engine_protocol_server"' "$TEMPLATE_DIR/backend-manifest.json" \
  || die "$TEMPLATE is too old (no llama-server protocol). Update the CUDA 12 runtime in LM Studio."
say "template runtime: $TEMPLATE"

# ---- fetch Prism llama.cpp ----------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ -n "${PRISM_ARCHIVE:-}" ]; then
  ARCHIVE="$PRISM_ARCHIVE"
  [ -f "$ARCHIVE" ] || die "PRISM_ARCHIVE=$ARCHIVE does not exist"
  say "using local archive $ARCHIVE"
else
  if [ "$PRISM_TAG" = "latest" ]; then
    PRISM_TAG="$(curl -fsSL "https://api.github.com/repos/$PRISM_REPO/releases/latest" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')" \
      || die "could not query the latest Prism release"
  fi
  ASSET="llama-$PRISM_TAG-bin-linux-cuda-$PRISM_CUDA-x64.tar.gz"
  URL="https://github.com/$PRISM_REPO/releases/download/$PRISM_TAG/$ASSET"
  ARCHIVE="$WORK/$ASSET"
  say "downloading $ASSET (~160 MB)"
  curl -fL --progress-bar -o "$ARCHIVE" "$URL" || die "download failed: $URL"
fi

mkdir -p "$WORK/x"
tar -xzf "$ARCHIVE" -C "$WORK/x"
SRC="$(dirname "$(find "$WORK/x" -type f -name llama-server | head -n1)")"
[ -x "$SRC/llama-server" ] || die "llama-server not found in the archive"
[ "$SRC" = "$WORK/x" ] || PRISM_TAG="$(basename "$SRC" | sed 's/^llama-//')"

# ---- assemble the runtime -----------------------------------------------------
DEST="$BACKENDS/$RUNTIME_NAME-$TEMPLATE_VERSION"
say "installing into $DEST"
rm -rf "$DEST.tmp"
mkdir -p "$DEST.tmp/prism"

# LM Studio's own files (bindings, in-process engine and its libs) - untouched.
cp -a "$TEMPLATE_DIR/." "$DEST.tmp/"
rm -f "$DEST.tmp/llama-server"

# Prism's server + the libraries it needs. It carries RUNPATH=$ORIGIN, so it
# resolves these from prism/ and never mixes with LM Studio's libllama/libggml.
cp -a "$SRC"/llama-server "$SRC"/lib*.so* "$DEST.tmp/prism/"
cp -a "$SRC"/LICENSE "$DEST.tmp/prism/LICENSE" 2>/dev/null || true
echo "$PRISM_TAG" > "$DEST.tmp/prism/PRISM_VERSION"

python3 - "$DEST.tmp" "$RUNTIME_NAME" "$PRISM_TAG" <<'PY'
import json, os, sys
dest, name, tag = sys.argv[1:]

def rw(fn, edit):
    p = os.path.join(dest, fn)
    with open(p) as f: data = json.load(f)
    edit(data)
    with open(p, "w") as f: json.dump(data, f, indent=2)

def manifest(m):
    m["name"] = name
    m["engine_protocol_server"]["executable_relative_path"] = "prism/llama-server"
rw("backend-manifest.json", manifest)

def artifacts(a):
    a["executable_relative_path"] = "prism/llama-server"
    files = [f for f in a["files"] if f["relative_path"] != "llama-server"]
    for fn in sorted(os.listdir(os.path.join(dest, "prism"))):
        files.append({"relative_path": "prism/" + fn,
                      "executable": fn == "llama-server"})
    a["files"] = files
rw("engine-protocol-server-artifacts.json", artifacts)

def display(d):
    for _, v in d:
        v["displayName"] = "Bonsai 2 · Prism llama.cpp (CUDA 12)"
        v["description"] = ("llama.cpp fork by PrismML with PQ2_0 / PTQ1_0 ternary kernels "
                            f"({tag}). Runs regular GGUF models too.")
        v["releaseNotes"] = [{"version": v.get("releaseNotes", [{}])[0].get("version", ""),
                              "releaseNotes": f"- Prism llama.cpp {tag}\n"}]
rw("display-data.json", display)
PY

# Drop earlier installs (built from an older template) and put this one in place.
find "$BACKENDS" -maxdepth 1 -type d -name "$RUNTIME_NAME-*" ! -name "*.tmp" -exec rm -rf {} +
mv "$DEST.tmp" "$DEST"

# ---- smoke test: the binary starts and knows the Prism types ---------------------
VENDOR="$BACKENDS/vendor/linux-llama-cuda12-vendor-v1"
if ! LD_LIBRARY_PATH="$VENDOR" "$DEST/prism/llama-server" --version >"$WORK/ver.txt" 2>&1; then
  cat "$WORK/ver.txt" >&2
  die "prism llama-server failed to start (missing CUDA libs? see above)"
fi
sed 's/^/    /' "$WORK/ver.txt" | grep -i -E "version|built|CUDA" | head -n4 || true

# ---- model.yaml: reasoning effort selector ---------------------------------------
# LM Studio only offers a thinking on/off toggle for this GGUF. The virtual
# model adds xhigh / medium / low, passed to the chat template as reasoning_effort.
HUB_DEST="$LMSTUDIO_HOME/hub/models/$HUB_MODEL"
mkdir -p "$HUB_DEST"
cp "$REPO_ROOT/hub/${HUB_MODEL#*/}"/* "$HUB_DEST/"
say "model settings: $HUB_DEST"

# Files downloaded straight from Hugging Face are listed on their own, next to
# the virtual model and without its settings. LM Studio hides base files that
# it marks "transitive" (pulled in by a virtual model), so mark them that way.
MODEL_DATA="$LMSTUDIO_HOME/.internal/model-data.json"
if [ -f "$MODEL_DATA" ]; then
  if pgrep -x lm-studio >/dev/null || pgrep -x llmster >/dev/null; then
    echo "    note: LM Studio is running - close it and rerun to hide the duplicate"
    echo "          Ternary-Bonsai-2 .gguf entries (it rewrites its index on exit)"
  else
    python3 - "$MODEL_DATA" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f: data = json.load(f)
n = 0
for key, info in data.get("json", []):
    if key.lower().startswith("prism-ml/ternary-bonsai-2-27b-gguf/") and not info.get("transitive"):
        info["transitive"] = True; n += 1
if n:
    with open(path, "w") as f: json.dump(data, f, separators=(",", ":"))
print(f"    grouped {n} .gguf file(s) under the virtual model" if n else "    .gguf files already grouped")
PY
  fi
fi

# ---- select it ----------------------------------------------------------------
if [ "$SELECT" = 1 ] && [ -x "$LMS" ]; then
  say "selecting $RUNTIME_NAME@$TEMPLATE_VERSION as the GGUF runtime"
  # A freshly added runtime can take a moment to show up in LM Studio's index.
  for _ in 1 2 3 4 5; do
    # lms waits for LM Studio's daemon when the app is closed - don't hang on it
    timeout 20 "$LMS" runtime select "$RUNTIME_NAME@$TEMPLATE_VERSION" >/dev/null 2>&1 && break
    sleep 2
  done
  timeout 20 "$LMS" runtime ls 2>/dev/null | grep -q "$RUNTIME_NAME@$TEMPLATE_VERSION.*✓" \
    && echo "    selected" \
    || echo "    could not select automatically - pick it in LM Studio: Settings -> Runtime"
fi

echo
say "done."
cat <<EOF
    Runtime: "Bonsai 2 · Prism llama.cpp (CUDA 12)"  ($PRISM_TAG)

    If LM Studio is open, restart it so it sees the new runtime, then load
    "ternary-bonsai-2-27b" (2 variants: PQ2_0 / PTQ1_0). Its settings have
    Reasoning Effort (xhigh / medium / low) next to Enable Thinking; over the
    API send "reasoning_effort": "medium".

    Switch runtimes any time in Settings -> Runtime -> GGUF.
    Remove with ./uninstall.sh
EOF
pause_if_clicked
