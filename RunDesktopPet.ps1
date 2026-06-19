Set-Location -LiteralPath $PSScriptRoot

powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "Start-DesktopPet.ps1")
