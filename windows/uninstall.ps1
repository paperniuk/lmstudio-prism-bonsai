# Remove the "Bonsai 2 - Prism llama.cpp" runtime from LM Studio and switch GGUF
# back to the newest stock CUDA 12 runtime.
$ErrorActionPreference = "Stop"

$RuntimeName  = "llama.cpp-win-x86_64-nvidia-cuda12-avx2-prism"
$TemplateBase = "llama.cpp-win-x86_64-nvidia-cuda12-avx2"
$HubModel     = "prism-ml\ternary-bonsai-2-27b"

$LmHome = $env:LMSTUDIO_HOME
if (-not $LmHome) {
    $pointer = Join-Path $env:USERPROFILE ".lmstudio-home-pointer"
    if (Test-Path $pointer) { $LmHome = (Get-Content $pointer -TotalCount 1).Trim() }
    else { $LmHome = Join-Path $env:USERPROFILE ".lmstudio" }
}
$Backends = Join-Path $LmHome "extensions\backends"
$Lms = Join-Path $LmHome "bin\lms.exe"
if (-not (Test-Path $Backends)) { Write-Host "LM Studio runtimes not found in $Backends"; exit 1 }

$stock = Get-ChildItem $Backends -Directory |
    Where-Object { $_.Name -match "^$([regex]::Escape($TemplateBase))-(\d+(\.\d+)*)$" } |
    Sort-Object { [version]($_.Name.Substring($TemplateBase.Length + 1)) } |
    Select-Object -Last 1
if ($stock -and (Test-Path $Lms)) {
    $alias = "$TemplateBase@" + $stock.Name.Substring($TemplateBase.Length + 1)
    Write-Host "switching GGUF back to $alias"
    # lms waits for LM Studio's daemon when the app is closed - don't hang on it
    $p = Start-Process -FilePath $Lms -ArgumentList @("runtime", "select", $alias) -NoNewWindow -PassThru `
        -RedirectStandardOutput (Join-Path $env:TEMP "bonsai-lms.out") -RedirectStandardError (Join-Path $env:TEMP "bonsai-lms.err")
    $ok = $p.WaitForExit(20000); if (-not $ok) { $p.Kill() } else { $ok = ($p.ExitCode -eq 0) }
    if (-not $ok) { Write-Host "  could not switch automatically - pick a runtime in LM Studio: Settings -> Runtime" }
}

$found = Get-ChildItem $Backends -Directory | Where-Object { $_.Name -like "$RuntimeName-*" }
if ($found) {
    foreach ($d in $found) {
        try {
            Remove-Item $d.FullName -Recurse -Force
            Write-Host "removed $($d.FullName)"
        } catch {
            Write-Host "could not remove $($d.FullName) - close LM Studio (a model may be loaded from it) and run again" -ForegroundColor Red
            exit 1
        }
    }
} else {
    Write-Host "nothing to remove - the Prism runtime is not installed"
}
$hubDir = Join-Path $LmHome "hub\models\$HubModel"
if (Test-Path $hubDir) { Remove-Item $hubDir -Recurse -Force; Write-Host "removed model settings $hubDir" }
Write-Host "done. Restart LM Studio if it is open."
