@ECHO OFF
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0workspace.ps1" %*
