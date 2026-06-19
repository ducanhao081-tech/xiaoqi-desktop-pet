Set-Location -LiteralPath $PSScriptRoot

$logDir = Join-Path $PSScriptRoot "logs"
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

$logPath = Join-Path $logDir "desktop-pet-debug.log"
Write-Host "Starting Desktop Pet..."
Write-Host "Log: $logPath"

$windowsPowerShell = Get-Command powershell.exe -ErrorAction SilentlyContinue
if (-not $windowsPowerShell) {
    $message = "powershell.exe was not found. The Windows runtime host could not be launched."
    Write-Host $message
    $message | Set-Content -LiteralPath $logPath -Encoding UTF8
    Read-Host "Press Enter to close"
    exit 1
}

& $windowsPowerShell.Source -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "Start-DesktopPet.ps1") *>&1 | Tee-Object -FilePath $logPath
$launcherSucceeded = $?
$exitCode = $LASTEXITCODE
if ($null -eq $exitCode) {
    $exitCode = if ($launcherSucceeded) { 0 } else { 1 }
}

if (-not $launcherSucceeded -and $exitCode -eq 0) {
    $exitCode = 1
}

if (-not $launcherSucceeded) {
    Write-Host ""
    Write-Host "Runtime host failed before Desktop Pet returned a normal exit code."
}

Write-Host ""
Write-Host "Desktop Pet exited with code $exitCode. If it did not open, send the log above or this file:"
Write-Host $logPath
Read-Host "Press Enter to close"
exit $exitCode
