@echo off
rem Double-click: adds the Bonsai 2 (Prism llama.cpp) runtime to LM Studio.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\install.ps1" %*
echo.
pause
