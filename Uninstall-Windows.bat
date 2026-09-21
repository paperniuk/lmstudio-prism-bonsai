@echo off
rem Double-click: removes the Bonsai 2 (Prism llama.cpp) runtime from LM Studio.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\uninstall.ps1" %*
echo.
pause
