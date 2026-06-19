Set-Location -LiteralPath $PSScriptRoot

$logDir = Join-Path $PSScriptRoot "logs"
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

$logPath = Join-Path $logDir "desktop-pet-selftest.log"
Write-Host "Running Desktop Pet self-test..."
Write-Host "Log: $logPath"

$windowsPowerShell = Get-Command powershell.exe -ErrorAction SilentlyContinue
if (-not $windowsPowerShell) {
    $message = "powershell.exe was not found. The Windows self-test host could not be launched."
    Write-Host $message
    $message | Set-Content -LiteralPath $logPath -Encoding UTF8
    exit 1
}

& $windowsPowerShell.Source -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "Start-DesktopPet.ps1") -SelfTest *>&1 | Tee-Object -FilePath $logPath
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
    Write-Host "Self-test host failed before Desktop Pet returned a normal exit code."
}

Write-Host ""
Write-Host "Self-test exited with code $exitCode. Send this file with Windows verification results:"
Write-Host $logPath
exit $exitCode
