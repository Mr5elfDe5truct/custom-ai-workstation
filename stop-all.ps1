# Stops everything start-all.ps1 launched. ComfyUI (Comfy Desktop) is left alone.
param([switch]$KeepOllama)

$Root = $PSScriptRoot
Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($Root, 'OrdinalIgnoreCase') } | ForEach-Object {
    Write-Host "  stopping $($_.Name) ($($_.Id))"
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}
# Headless ComfyUI runs from Comfy Desktop's folder, so find it by its port (8188) instead.
Get-NetTCPConnection -LocalPort 8188 -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "  stopping ComfyUI ($($_.OwningProcess))"
    Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue
}
if (-not $KeepOllama) { Get-Process ollama -ErrorAction SilentlyContinue | Stop-Process -Force }
Write-Host "Stopped."
