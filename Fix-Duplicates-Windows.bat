@echo off
rem Double-click: shows Ternary-Bonsai-2 only once in LM Studio (hides the separate .gguf entries).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\group-models.ps1"
echo.
pause
