param(
    [switch]$SelfTest
)

$isSta = [System.Threading.Thread]::CurrentThread.GetApartmentState() -eq "STA"
if (-not $isSta) {
    $argsList = @("-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", $PSCommandPath)
    if ($SelfTest) {
        $argsList += "-SelfTest"
    }

    & powershell.exe @argsList
    exit $LASTEXITCODE
}

$scriptPath = Join-Path $PSScriptRoot "src\DesktopPet.ps1"

if (-not (Test-Path $scriptPath)) {
    Write-Error "Desktop pet script not found: $scriptPath"
    exit 1
}

& $scriptPath -SelfTest:$SelfTest
