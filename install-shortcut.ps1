# Adds "Custom AI" shortcuts to the Desktop and Start Menu that open Open WebUI as an app window.
#   .\install-shortcut.ps1            create or refresh both shortcuts
#   .\install-shortcut.ps1 -Remove    delete them
param([switch]$Remove)

$Root = $PSScriptRoot
$Name = "Custom AI"
$Links = @(
    (Join-Path ([Environment]::GetFolderPath("Desktop")) "$Name.lnk"),
    (Join-Path ([Environment]::GetFolderPath("Programs")) "$Name.lnk")
)

if ($Remove) {
    $Links | Where-Object { Test-Path $_ } | ForEach-Object { Remove-Item $_; Write-Host "  removed $_" }
    return
}

# Use Open WebUI's own icon, copied out of the venv so a reinstall there doesn't break the shortcut.
$Icon = Join-Path $Root "data\custom-ai.ico"
$static = "$Root\envs\open-webui\Lib\site-packages\open_webui\static"
New-Item -ItemType Directory -Force (Split-Path $Icon) | Out-Null
# favicon.ico is only 32px, so build a multi-size .ico from the 512px PNG (looks sharp on the desktop).
& "$Root\envs\open-webui\Scripts\python.exe" -c "from PIL import Image; Image.open(r'$static\favicon.png').save(r'$Icon', sizes=[(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)])" 2>$null
if (-not (Test-Path $Icon) -and (Test-Path "$static\favicon.ico")) { Copy-Item "$static\favicon.ico" $Icon -Force }

$shell = New-Object -ComObject WScript.Shell
foreach ($path in $Links) {
    $lnk = $shell.CreateShortcut($path)
    $lnk.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    # Minimized, so the first launch (which starts the services) shows progress in the taskbar without a console in the way.
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File `"$Root\open-app.ps1`""
    $lnk.WorkingDirectory = $Root
    $lnk.Description = "Open WebUI on the Custom AI workstation"
    $lnk.WindowStyle = 7   # minimized
    if (Test-Path $Icon) { $lnk.IconLocation = "$Icon,0" }
    $lnk.Save()
    Write-Host "  created $path"
}
