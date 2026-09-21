# Add a "Bonsai 2 - Prism llama.cpp" runtime to LM Studio on Windows, so the
# PQ2_0 / PTQ1_0 GGUF packs of Ternary-Bonsai-2 load.
#
# Nothing of LM Studio's own is modified: a new runtime folder is created next
# to the stock ones under %USERPROFILE%\.lmstudio\extensions\backends\.
# Remove it with Uninstall-Windows.bat.
#
#   install.ps1                 pinned Prism release, select the new runtime
#   install.ps1 -Latest         newest Prism release instead of the pinned one
#   install.ps1 -NoSelect       install but keep the current runtime selected
#   install.ps1 -Cuda 12.4      force the CUDA build (default: from the driver)
#
# Env: PRISM_TAG, LMSTUDIO_HOME.
param(
    [switch]$Latest,
    [switch]$NoSelect,
    [ValidateSet("12.4", "13.3")][string]$Cuda
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # Invoke-WebRequest is very slow with it on
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$PrismRepo    = "PrismML-Eng/llama.cpp"
$PrismTag     = if ($env:PRISM_TAG) { $env:PRISM_TAG } else { "prism-b10709-9a9394a" }
$RuntimeName  = "llama.cpp-win-x86_64-nvidia-cuda12-avx2-prism"
$TemplateBase = "llama.cpp-win-x86_64-nvidia-cuda12-avx2"
$HubModel     = "prism-ml\ternary-bonsai-2-27b"   # model.yaml with the reasoning-effort selector
$Utf8NoBom    = New-Object System.Text.UTF8Encoding $false

function Say($msg)  { Write-Host "==> $msg" -ForegroundColor Green }
function Info($msg) { Write-Host "    $msg" }
function Die($msg)  { Write-Host "error: $msg" -ForegroundColor Red; exit 1 }
function Write-Json($path, $text) { [IO.File]::WriteAllText($path, $text, $Utf8NoBom) }
# Native tools write progress to stderr; under "Stop" PowerShell 5.1 would turn
# that into a terminating error, so run them with "Continue".
function Run-Native([scriptblock]$cmd) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { & $cmd } finally { $ErrorActionPreference = $prev }
}
# lms waits for LM Studio's daemon when the app is closed - don't hang on it.
function Invoke-Lms([string[]]$lmsArgs, [int]$timeoutSec = 20) {
    $p = Start-Process -FilePath $Lms -ArgumentList $lmsArgs -NoNewWindow -PassThru `
        -RedirectStandardOutput (Join-Path $env:TEMP "bonsai-lms.out") -RedirectStandardError (Join-Path $env:TEMP "bonsai-lms.err")
    if (-not $p.WaitForExit($timeoutSec * 1000)) { $p.Kill(); return $false }
    return ($p.ExitCode -eq 0)
}
function Json-Str($s) { '"' + ($s -replace '\\', '\\' -replace '"', '\"' -replace "`n", '\n') + '"' }

# Size of a remote file after redirects, or 0 if the server does not say.
function Get-RemoteSize($url) {
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curl) { return 0 }
    $head = Run-Native { & $curl.Source -sIL $url 2>$null }
    $len = $head | Where-Object { $_ -match '^content-length:\s*(\d+)' } | ForEach-Object { [int64]$Matches[1] } | Select-Object -Last 1
    if ($len) { return $len } else { return 0 }
}

# GitHub release downloads can be slow per connection, so big files are fetched
# as $parts byte ranges in parallel and joined. Falls back to one connection.
function Download($url, $out, [int]$parts = 16) {
    Info "downloading $(Split-Path $url -Leaf)"
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curl) { Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing; return }

    $size = Get-RemoteSize $url
    if ($size -gt 20MB -and $parts -gt 1) {
        $chunk = [math]::Ceiling($size / $parts)
        $jobs = @()
        for ($i = 0; $i -lt $parts; $i++) {
            $from = $i * $chunk; $to = [math]::Min($from + $chunk - 1, $size - 1)
            $part = "$out.part$i"
            $p = Start-Process -FilePath $curl.Source -NoNewWindow -PassThru -ArgumentList @(
                "-sfL", "--retry", "5", "--retry-delay", "2", "-r", "$from-$to", "-o", ('"' + $part + '"'), ('"' + $url + '"'))
            $null = $p.Handle   # keeps ExitCode readable after exit
            $jobs += [pscustomobject]@{ Proc = $p; Part = $part; Len = $to - $from + 1 }
        }
        $t0 = Get-Date
        while ($jobs | Where-Object { -not $_.Proc.HasExited }) {
            $done = ($jobs | ForEach-Object { if (Test-Path $_.Part) { (Get-Item $_.Part).Length } else { 0 } } | Measure-Object -Sum).Sum
            $sec = [math]::Max(((Get-Date) - $t0).TotalSeconds, 1)
            Write-Host -NoNewline ("`r    {0,5:N1} / {1:N1} MB  {2,6:N1} Mbit/s   " -f ($done / 1MB), ($size / 1MB), ($done * 8 / 1e6 / $sec))
            Start-Sleep -Milliseconds 700
        }
        Write-Host ""
        $ok = $true
        foreach ($j in $jobs) {
            if ($j.Proc.ExitCode -ne 0 -or -not (Test-Path $j.Part) -or (Get-Item $j.Part).Length -ne $j.Len) { $ok = $false }
        }
        if ($ok) {
            $fs = [IO.File]::Create($out)
            try {
                foreach ($j in $jobs) {
                    $in = [IO.File]::OpenRead($j.Part)
                    try { $in.CopyTo($fs) } finally { $in.Close() }
                }
            } finally { $fs.Close() }
            $jobs | ForEach-Object { Remove-Item $_.Part -Force }
            return
        }
        Info "parallel download failed, retrying with one connection"
        $jobs | ForEach-Object { Remove-Item $_.Part -Force -ErrorAction SilentlyContinue }
    }
    Run-Native { & $curl.Source -fL --retry 5 --progress-bar -o $out $url }
    if ($LASTEXITCODE -ne 0) { Die "download failed: $url" }
}

# cudart / cuBLAS / cuBLASLt DLLs straight from NVIDIA's redist CDN (much
# faster than GitHub), checked against the SHA-256 in NVIDIA's manifest.
# Returns $false if anything goes wrong, so the caller can fall back.
function Get-NvidiaCudaDlls($cuda, $dest, $work) {
    $redist = "https://developer.download.nvidia.com/compute/cuda/redist"
    $manifestName = @{ "12.4" = "redistrib_12.4.1.json"; "13.3" = "redistrib_13.3.1.json" }[$cuda]
    try {
        $m = Invoke-RestMethod "$redist/$manifestName" -UseBasicParsing
        foreach ($pkg in "cuda_cudart", "libcublas") {
            $w = $m.$pkg."windows-x86_64"
            $zip = Join-Path $work "$pkg.zip"
            Download "$redist/$($w.relative_path)" $zip
            if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne $w.sha256.ToUpper()) { throw "sha256 mismatch for $pkg" }
            Unzip $zip (Join-Path $work $pkg)
            Get-ChildItem (Join-Path $work $pkg) -Recurse -Include "cudart64_*.dll", "cublas64_*.dll", "cublasLt64_*.dll" |
                Copy-Item -Destination $dest
        }
        return (Test-Path (Join-Path $dest "cublasLt64_*.dll"))
    } catch {
        Info "NVIDIA download failed: $($_.Exception.Message)"
        return $false
    }
}

function Unzip($zip, $dest) {
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if ($tar) {
        Run-Native { & $tar.Source -xf $zip -C $dest }
        if ($LASTEXITCODE -eq 0) { return }
    }
    Expand-Archive -Path $zip -DestinationPath $dest -Force
}

# ---- locate LM Studio ---------------------------------------------------------
$LmHome = $env:LMSTUDIO_HOME
if (-not $LmHome) {
    $pointer = Join-Path $env:USERPROFILE ".lmstudio-home-pointer"
    if (Test-Path $pointer) { $LmHome = (Get-Content $pointer -TotalCount 1).Trim() }
    else { $LmHome = Join-Path $env:USERPROFILE ".lmstudio" }
}
$Backends = Join-Path $LmHome "extensions\backends"
$Lms = Join-Path $LmHome "bin\lms.exe"
if (-not (Test-Path $Backends)) { Die "LM Studio runtimes not found in $Backends (set LMSTUDIO_HOME)" }
Say "LM Studio: $LmHome"

# ---- GPU / driver -> which CUDA build --------------------------------------------
$smi = $null
foreach ($p in @((Get-Command nvidia-smi -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
                 "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe",
                 "$env:SystemRoot\System32\nvidia-smi.exe")) {
    if ($p -and (Test-Path $p)) { $smi = $p; break }
}
if ($smi) {
    $smiOut = Run-Native { & $smi 2>&1 | Out-String }
    $gpu = Run-Native { & $smi --query-gpu=name,driver_version --format=csv,noheader 2>$null | Select-Object -First 1 }
    Info "GPU: $gpu"
} elseif (-not $Cuda) {
    Die "nvidia-smi not found - install the NVIDIA driver first (or pass -Cuda 12.4 / -Cuda 13.3)"
}
if (-not $Cuda) {
    if ($smiOut -match 'CUDA(?:\s+UMD)?\s+Version:\s+(\d+)\.(\d+)') {
        $major = [int]$Matches[1]; $minor = [int]$Matches[2]
        if ($major -gt 13 -or ($major -eq 13 -and $minor -ge 3)) { $Cuda = "13.3" }
        elseif ($major -gt 12 -or ($major -eq 12 -and $minor -ge 4)) { $Cuda = "12.4" }
        else { Die "driver supports CUDA $major.$minor; 12.4 or newer is required - update the NVIDIA driver" }
    } else { $Cuda = "12.4" }
}
Info "using the CUDA $Cuda build"

# ---- template: newest stock CUDA 12 runtime -----------------------------------------
# Its LM Studio bindings (.node files) are reused as-is; only the llama-server
# that LM Studio spawns is swapped for Prism's build.
$template = Get-ChildItem $Backends -Directory |
    Where-Object { $_.Name -match "^$([regex]::Escape($TemplateBase))-(\d+(\.\d+)*)$" } |
    Sort-Object { [version]($_.Name.Substring($TemplateBase.Length + 1)) } |
    Select-Object -Last 1
if (-not $template) {
    Die "no stock 'CUDA 12 llama.cpp' runtime installed.`n     In LM Studio open Settings -> Runtime, download 'CUDA 12 llama.cpp (Windows)', then rerun."
}
$TemplateVersion = $template.Name.Substring($TemplateBase.Length + 1)
$manifestText = Get-Content (Join-Path $template.FullName "backend-manifest.json") -Raw
if ($manifestText -notmatch '"engine_protocol_server"') {
    Die "$($template.Name) is too old (no llama-server protocol). Update the CUDA 12 runtime in LM Studio."
}
$artifactsPath = Join-Path $template.FullName "engine-protocol-server-artifacts.json"
$artifacts = Get-Content $artifactsPath -Raw | ConvertFrom-Json
$StockExe = $artifacts.executable_relative_path          # e.g. llama-server.exe
Say "template runtime: $($template.Name)"

# ---- fetch Prism llama.cpp ---------------------------------------------------------
$Work = Join-Path $env:TEMP ("bonsai-prism-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force -Path $Work | Out-Null
try {
    if ($Latest) {
        $rel = Invoke-RestMethod "https://api.github.com/repos/$PrismRepo/releases/latest" -UseBasicParsing
        $PrismTag = $rel.tag_name
    }
    $base = "https://github.com/$PrismRepo/releases/download/$PrismTag"
    Say "Prism llama.cpp $PrismTag"
    $zip = Join-Path $Work "llama.zip"
    Download "$base/llama-$PrismTag-bin-win-cuda-$Cuda-x64.zip" $zip
    Unzip $zip (Join-Path $Work "x")
    $server = Get-ChildItem (Join-Path $Work "x") -Recurse -Filter "llama-server.exe" | Select-Object -First 1
    if (-not $server) { Die "llama-server.exe not found in the archive" }
    $Src = $server.DirectoryName

    # ---- assemble the runtime -------------------------------------------------------
    $Dest = Join-Path $Backends "$RuntimeName-$TemplateVersion"
    $Tmp = "$Dest.tmp"
    Say "installing into $Dest"
    if (Test-Path $Tmp) { Remove-Item $Tmp -Recurse -Force }
    Copy-Item $template.FullName $Tmp -Recurse
    Remove-Item (Join-Path $Tmp $StockExe) -Force -ErrorAction SilentlyContinue
    $PrismDir = Join-Path $Tmp "prism"
    New-Item -ItemType Directory -Force -Path $PrismDir | Out-Null

    # Windows loads DLLs from the exe's own folder first, so Prism's server
    # picks up its ggml/llama DLLs from prism\ and never LM Studio's.
    Copy-Item (Join-Path $Src "llama-server.exe") $PrismDir
    Copy-Item (Join-Path $Src "*.dll") $PrismDir
    if (Test-Path (Join-Path $Src "LICENSE")) { Copy-Item (Join-Path $Src "LICENSE") $PrismDir }

    # CUDA runtime DLLs next to the exe as well.
    $vendor = Join-Path $Backends "vendor\win-llama-cuda12-vendor-v1"
    if ($Cuda -eq "12.4" -and (Test-Path (Join-Path $vendor "cudart64_12.dll"))) {
        Info "CUDA 12 DLLs: reusing LM Studio's ($vendor)"
        Copy-Item (Join-Path $vendor "*.dll") $PrismDir
    } else {
        Info "CUDA $Cuda DLLs: from NVIDIA (developer.download.nvidia.com)"
        if (-not (Get-NvidiaCudaDlls $Cuda $PrismDir $Work)) {
            Info "falling back to Prism's cudart bundle on GitHub"
            $rt = Join-Path $Work "cudart.zip"
            Download "$base/cudart-llama-bin-win-cuda-$Cuda-x64.zip" $rt
            Unzip $rt (Join-Path $Work "rt")
            Get-ChildItem (Join-Path $Work "rt") -Recurse -Filter "*.dll" | Copy-Item -Destination $PrismDir
        }
    }
    Set-Content -Path (Join-Path $PrismDir "PRISM_VERSION") -Value "$PrismTag cuda-$Cuda"

    # manifest: new name, spawn prism\llama-server.exe
    $exeRel = "prism/llama-server.exe"
    # only the top-level name - target_libraries entries have "name" keys too
    $m = $manifestText -replace ('("name"\s*:\s*")' + [regex]::Escape($TemplateBase) + '(")'), "`${1}$RuntimeName`${2}"
    if ($m -eq $manifestText) { Die "unexpected backend-manifest.json layout in $($template.Name)" }
    $m = $m -replace '("executable_relative_path"\s*:\s*")[^"]*(")', "`${1}$exeRel`${2}"
    Write-Json (Join-Path $Tmp "backend-manifest.json") $m

    # artifacts: LM Studio's files minus the stock exe, plus everything in prism\
    $entries = @()
    foreach ($f in $artifacts.files) {
        if ($f.relative_path -ne $StockExe) {
            $entries += '    { "relative_path": ' + (Json-Str $f.relative_path) + ', "executable": ' + ([string]$f.executable).ToLower() + ' }'
        }
    }
    foreach ($f in Get-ChildItem $PrismDir -File | Sort-Object Name) {
        $isExe = if ($f.Name -eq "llama-server.exe") { "true" } else { "false" }
        $entries += '    { "relative_path": ' + (Json-Str ("prism/" + $f.Name)) + ', "executable": ' + $isExe + ' }'
    }
    $a = "{`n  ""schema_version"": $($artifacts.schema_version),`n  ""runtime_kind"": " + (Json-Str $artifacts.runtime_kind) +
         ",`n  ""executable_relative_path"": " + (Json-Str $exeRel) + ",`n  ""files"": [`n" + ($entries -join ",`n") + "`n  ]`n}`n"
    Write-Json (Join-Path $Tmp "engine-protocol-server-artifacts.json") $a

    # display name in LM Studio's runtime list
    $desc = "llama.cpp fork by PrismML with PQ2_0 / PTQ1_0 ternary kernels ($PrismTag, CUDA $Cuda). Runs regular GGUF models too."
    $d = '[["en",{"langKey":"en","displayName":' + (Json-Str "Bonsai 2 - Prism llama.cpp (CUDA $Cuda)") +
         ',"description":' + (Json-Str $desc) + ',"releaseNotes":[{"version":' + (Json-Str $TemplateVersion) +
         ',"releaseNotes":' + (Json-Str "- Prism llama.cpp $PrismTag`n") + '}]}]]'
    Write-Json (Join-Path $Tmp "display-data.json") $d

    # drop earlier installs, put this one in place
    Get-ChildItem $Backends -Directory | Where-Object { $_.Name -like "$RuntimeName-*" -and $_.Name -notlike "*.tmp" } |
        Remove-Item -Recurse -Force
    Move-Item $Tmp $Dest

    # ---- smoke test --------------------------------------------------------------
    $exe = Join-Path $Dest "prism\llama-server.exe"
    $ver = Run-Native { & $exe --version 2>&1 | Out-String }
    if ($LASTEXITCODE -ne 0) { Write-Host $ver; Die "prism llama-server.exe failed to start (see above)" }
    ($ver -split "`n") | Where-Object { $_ -match "version|built|CUDA" } | Select-Object -First 4 | ForEach-Object { Info $_.Trim() }
}
finally {
    Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- model.yaml: reasoning effort selector -----------------------------------------
# LM Studio only offers a thinking on/off toggle for this GGUF. The virtual
# model adds xhigh / medium / low, passed to the chat template as reasoning_effort.
$HubDest = Join-Path $LmHome "hub\models\$HubModel"
New-Item -ItemType Directory -Force -Path $HubDest | Out-Null
Copy-Item (Join-Path $PSScriptRoot "..\hub\ternary-bonsai-2-27b\*") $HubDest -Force
Say "model settings: $HubDest"

# Files downloaded straight from Hugging Face are listed on their own, next to
# the virtual model and without its settings. LM Studio hides base files that
# it marks "transitive" (pulled in by a virtual model), so mark them that way.
$modelData = Join-Path $LmHome ".internal\model-data.json"
if (Test-Path $modelData) {
    if (Get-Process -Name "LM Studio", "lm-studio", "llmster" -ErrorAction SilentlyContinue) {
        Info "note: LM Studio is running - close it and rerun to hide the duplicate"
        Info "      Ternary-Bonsai-2 .gguf entries (it rewrites its index on exit)"
    } else {
        $txt = [IO.File]::ReadAllText($modelData)
        $pattern = '(\["prism-ml/Ternary-Bonsai-2-27B-gguf/[^"]+"\s*,\s*\{\s*"source"\s*:\s*\{[^}]*\}\s*,\s*"transitive"\s*:\s*)false'
        $n = ([regex]::Matches($txt, $pattern, "IgnoreCase")).Count
        if ($n -gt 0) {
            Write-Json $modelData ([regex]::Replace($txt, $pattern, '${1}true', "IgnoreCase"))
            Info "grouped $n .gguf file(s) under the virtual model"
        } else { Info ".gguf files already grouped" }
    }
}

# ---- select it ------------------------------------------------------------------
if (-not $NoSelect -and (Test-Path $Lms)) {
    Say "selecting $RuntimeName@$TemplateVersion as the GGUF runtime"
    $ok = $false
    for ($i = 0; $i -lt 5 -and -not $ok; $i++) {
        $ok = Invoke-Lms @("runtime", "select", "$RuntimeName@$TemplateVersion")
        if (-not $ok) { Start-Sleep -Seconds 2 }
    }
    if ($ok) { Info "selected" } else { Info "could not select automatically - pick it in LM Studio: Settings -> Runtime" }
}

Write-Host ""
Say "done."
Info "Runtime: 'Bonsai 2 - Prism llama.cpp (CUDA $Cuda)'  ($PrismTag)"
Info ""
Info "If LM Studio is open, restart it so it sees the new runtime, then load"
Info "'ternary-bonsai-2-27b' (2 variants: PQ2_0 / PTQ1_0). Its settings have"
Info "Reasoning Effort (xhigh / medium / low) next to Enable Thinking; over the"
Info "API send ""reasoning_effort"": ""medium""."
Info ""
Info "Switch runtimes any time in Settings -> Runtime -> GGUF."
Info "Remove with Uninstall-Windows.bat"
