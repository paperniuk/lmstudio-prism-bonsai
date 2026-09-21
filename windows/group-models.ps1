# Hide the separate Ternary-Bonsai-2 .gguf entries in LM Studio's model list,
# so only the "ternary-bonsai-2-27b" virtual model (with Reasoning Effort) shows.
#
# LM Studio hides base files marked "transitive" (pulled in by a virtual model)
# in .internal\model-data.json. Files downloaded straight from Hugging Face are
# not marked, so they show up twice. LM Studio keeps this index in memory and
# writes it back, so it has to be closed while the flag is changed.
param([switch]$Quiet)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

$LmHome = $env:LMSTUDIO_HOME
if (-not $LmHome) {
    $pointer = Join-Path $env:USERPROFILE ".lmstudio-home-pointer"
    if (Test-Path $pointer) { $LmHome = (Get-Content $pointer -TotalCount 1).Trim() }
    else { $LmHome = Join-Path $env:USERPROFILE ".lmstudio" }
}
$modelData = Join-Path $LmHome ".internal\model-data.json"
if (-not (Test-Path $modelData)) { Write-Host "    $modelData not found - nothing to do"; exit 0 }

$procs = Get-Process -Name "LM Studio", "lm-studio", "llmster" -ErrorAction SilentlyContinue
if ($procs) {
    if ($Quiet) {
        Write-Host "    note: LM Studio is running - close it (tray icon too) and run Fix-Duplicates-Windows.bat"
        exit 0
    }
    $answer = Read-Host "LM Studio is running and has to be closed for this. Close it now? [Y/n]"
    if ($answer -and $answer -notmatch '^[yY]') { Write-Host "cancelled"; exit 1 }
    $procs | Stop-Process -Force
    Start-Sleep -Seconds 2
}

# Each entry looks like ["prism-ml/Ternary-Bonsai-2-27B-gguf/<file>",{...,"transitive":false,...}].
# [^\[\]]*? keeps the match inside that entry whatever the field order is.
$txt = [IO.File]::ReadAllText($modelData)
$pattern = '(\[\s*"prism-ml/Ternary-Bonsai-2-27B-gguf/[^"]+"\s*,\s*\{[^\[\]]*?"transitive"\s*:\s*)false'
$n = ([regex]::Matches($txt, $pattern, "IgnoreCase")).Count
if ($n -gt 0) {
    Copy-Item $modelData "$modelData.bak" -Force
    [IO.File]::WriteAllText($modelData, [regex]::Replace($txt, $pattern, '${1}true', "IgnoreCase"), $Utf8NoBom)
    Write-Host "    grouped $n .gguf file(s) under ternary-bonsai-2-27b (backup: model-data.json.bak)"
} elseif ($txt -match 'Ternary-Bonsai-2-27B-gguf/') {
    Write-Host "    .gguf files already grouped"
} else {
    Write-Host "    no Ternary-Bonsai-2 .gguf files in LM Studio's index yet - download them, then run this again"
}
if ($procs -and -not $Quiet) { Write-Host "    done - start LM Studio again" }
