# Opens Open WebUI as its own app window (no tabs or address bar), starting the workstation first if needed.
#   .\open-app.ps1             start services if they're down, then open the window
#   .\open-app.ps1 -NoStart    just open the window (start-all.ps1 uses this)
param([switch]$NoStart)

$Root = $PSScriptRoot
$Url = "http://localhost:8080"
# Separate browser profile so the app gets its own taskbar entry and doesn't mix with normal browsing.
$AppProfile = Join-Path $Root "data\app-profile"

function Test-Port($port) {
    [bool](Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
}

if (-not $NoStart -and -not (Test-Port 8080)) {
    & "$Root\start-all.ps1" -NoBrowser
}

$browser = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($browser) {
    New-Item -ItemType Directory -Force $AppProfile | Out-Null
    Start-Process -FilePath $browser -ArgumentList "--app=$Url", "--user-data-dir=`"$AppProfile`"", "--no-first-run", "--no-default-browser-check", "--window-size=1280,900"
} else {
    Start-Process $Url   # no Chrome or Edge found: fall back to the default browser
}
