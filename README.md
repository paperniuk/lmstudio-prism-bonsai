# lmstudio-prism-bonsai

**Ternary Bonsai 2 GGUF doesn't load in LM Studio. This makes it load.**

Linux and Windows, NVIDIA GPUs. Setup takes a double-click. Sibling of
[omlx-prism-hadamard](https://github.com/paperniuk/omlx-prism-hadamard), which does the same job for the
MLX pack in oMLX.

## The problem

Prism ML ships `Ternary-Bonsai-2-27B-gguf` in two packings: **PQ2_0** (7.2 GB)
and **PTQ1_0** (5.9 GB). LM Studio lists both files, reports the right
architecture (`qwen35`) and size, and then fails on load:

```
gguf_init_from_reader: tensor 'output.weight' has invalid ggml type 142. should be in [0, 43)
llama_model_load: error loading model: llama_model_loader: failed to load model
```

Types 142 and 143 are `PQ2_0` and `PTQ1_0`, the ternary formats. They exist
only in [Prism's llama.cpp fork](https://github.com/PrismML-Eng/llama.cpp),
which also applies the Hadamard activation transform that these weights need.
None of LM Studio's bundled runtimes include them, whatever the version.

## What this does

It adds one more runtime to LM Studio, called **"Bonsai 2 · Prism llama.cpp
(CUDA 12)"**. Its engine is Prism's official llama.cpp release build.

LM Studio 0.4 runtimes don't run llama.cpp in-process. They start a
`llama-server` child process and talk to it over HTTP. The runtime's
`backend-manifest.json` sets which executable gets started:

```json
"engine_protocol_server": {
  "runtime_kind": "llama-server",
  "executable_relative_path": "llama-server"
}
```

The installer:

1. copies the newest stock **CUDA 12 llama.cpp** runtime into a new folder
   named `…-cuda12-avx2-prism-<version>`. LM Studio's bindings, in-process
   engine and CUDA vendor libs are reused unchanged.
2. puts Prism's `llama-server` and the libraries it needs into a `prism/`
   subfolder, and points `executable_relative_path` at `prism/llama-server`.
3. renames the runtime in the manifest and `display-data.json` so it shows up
   as a separate entry, then selects it for GGUF.

Prism's libraries stay in `prism/`, apart from the runtime's own. On Linux the
server resolves them through `RUNPATH=$ORIGIN`, on Windows from the exe's own
folder. LM Studio's `libllm_engine.so` still loads LM Studio's own
`libllama`/`libggml` builds, so the two ABIs are never mixed.

LM Studio's stock runtimes are not modified, and an LM Studio update leaves
this one alone.

## Install

Get the folder: `git clone https://github.com/paperniuk/lmstudio-prism-bonsai.git`,
or on GitHub **Code → Download ZIP** and unpack it.

You need LM Studio 0.4+ with the **CUDA 12 llama.cpp** runtime downloaded
(Settings → Runtime). That is the default on NVIDIA machines.

### Windows

Double-click **`Install-Windows.bat`**.

The installer reads the driver's CUDA version from `nvidia-smi`, the same way
Prism's own `setup.ps1` does:

| Driver supports | Prism build | CUDA runtime DLLs                        |
| --------------- | ----------- | ---------------------------------------- |
| CUDA ≥ 13.3     | `cuda-13.3` | downloaded from NVIDIA's CDN (~375 MB, SHA-256 checked) |
| CUDA 12.4–13.2  | `cuda-12.4` | copied from LM Studio's CUDA 12 vendor pack |

GitHub release downloads are often slow per connection, so the Prism build is
fetched in 16 parallel byte ranges. The CUDA DLLs come from NVIDIA's redist CDN,
with Prism's GitHub bundle as the fallback.

To force a build, run `windows\install.ps1 -Cuda 12.4` (or `-Cuda 13.3`).

### Linux

Double-click **`Install-Linux.desktop`**. The first time, GNOME asks you to
right-click it and choose *Allow Launching*. Or run it from a terminal:

```bash
./install.sh
```

It downloads Prism's `linux-cuda-12.8` build (~160 MB), which matches LM
Studio's CUDA 12.8 vendor libraries.

### Then

Restart LM Studio if it was open, and load **`ternary-bonsai-2-27b`**. Pick
the PQ2_0 or PTQ1_0 variant with the Variants button. If the `mmproj` file is in
the same folder, LM Studio picks it up and image input works.

Best run the installer with LM Studio closed. See below for why.

### Reasoning effort (xhigh / medium / low)

Bonsai 2 has three reasoning-effort levels. Its chat template reads them from
the `reasoning_effort` Jinja variable: `xhigh` by default, `medium` for shorter
thinking, and `low`, which is untrained and behaves close to xhigh. For a raw
GGUF, LM Studio only offers the thinking on/off toggle.

The installer therefore also installs a virtual model,
[`hub/ternary-bonsai-2-27b/model.yaml`](hub/ternary-bonsai-2-27b/model.yaml),
into `~/.lmstudio/hub/models/prism-ml/`. It adds a **Reasoning Effort** select
(`customFields` → `setJinjaVariable: reasoning_effort`) next to **Enable
Thinking**, and sets the model card's thinking-mode sampling (temp 1.0, top-p
0.95, top-k 20). In LM Studio it appears as **`ternary-bonsai-2-27b`** with 2
variants (PQ2_0 / PTQ1_0). Load that entry, not the raw `.gguf` files.

If the `.gguf` files were downloaded straight from Hugging Face, LM Studio also
lists each of them separately, without these settings. It only hides base files
marked `"transitive": true` in `~/.lmstudio/.internal/model-data.json` (files
pulled in by a virtual model). The installer sets that flag for the Bonsai 2
files. LM Studio keeps this index in memory and rewrites it, so this step runs
only while LM Studio is **closed**, tray icon included. Otherwise the installer
prints a note and you rerun it after quitting LM Studio.

Over the API it is the OpenAI field:

```json
{ "model": "prism-ml/ternary-bonsai-2-27b", "reasoning_effort": "medium", "messages": [...] }
```

Verified by prompt length on the server side. xhigh adds a system instruction
(57 prompt tokens for "Hi"), medium adds none (15), low adds its own (45). On
the raw `.gguf` entry, `reasoning_effort` is ignored (57 either way), and
`chat_template_kwargs` is ignored by LM Studio in both cases.

### Options

| Linux                | Windows                        | Effect                                     |
| -------------------- | ------------------------------ | ------------------------------------------ |
| `--latest`           | `-Latest`                      | newest Prism release instead of the pinned one |
| `--no-select`        | `-NoSelect`                    | install, but keep the current runtime selected |
| `PRISM_TAG=<tag>`    | `$env:PRISM_TAG="<tag>"`       | a specific Prism release                   |
| `PRISM_ARCHIVE=<tgz>`|                                | use an already downloaded archive          |
| `LMSTUDIO_HOME=<dir>`| `$env:LMSTUDIO_HOME="<dir>"`   | non-default LM Studio home                 |

Pinned release: `prism-b10709-9a9394a`.

## Uninstall

Double-click `Uninstall-Windows.bat` / `Uninstall-Linux.desktop`, or
`./uninstall.sh`. It switches GGUF back to the newest stock CUDA 12 runtime
and deletes the Prism runtime folder.

## Things to know

- **LM Studio picks one runtime per model format.** While the Prism runtime is
  selected, *every* GGUF model runs on it. Prism's fork is a full llama.cpp
  (b10709) and runs ordinary models fine. It is a few hundred commits behind
  LM Studio's current build, though, so a brand-new architecture may need the
  stock runtime. Switch in Settings → Runtime → GGUF, or:
  ```bash
  lms runtime select llama.cpp-linux-x86_64-nvidia-cuda12-avx2@2.41.0
  lms runtime select llama.cpp-linux-x86_64-nvidia-cuda12-avx2-prism@2.41.0
  ```
- **Updating LM Studio's CUDA runtime** doesn't touch this one. Rerun the
  installer to rebuild it from the new template. The old copy is replaced.
- **Load errors are shown without formatting.** LM Studio's own `llama-server`
  reports failures on a special `LMSTUDIO_STARTUP_ERROR:` line. Prism's build
  doesn't have that, so a failed load (out of VRAM, for example) shows up as a
  generic error. The full reason is in the developer log.
- The Prism runtime ships with the `.node` bindings of whichever stock version
  it was copied from. If a future LM Studio drops the `llama-server` protocol,
  the installer refuses to run instead of producing a broken runtime.

## License

MIT for the scripts in this repo. The runtime downloads Prism ML's llama.cpp
builds (MIT, see `prism/LICENSE` inside the installed runtime) and reuses LM
Studio's own runtime files from your installation. Nothing from LM Studio is
redistributed here.
