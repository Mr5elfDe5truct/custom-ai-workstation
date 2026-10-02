# Custom AI Workstation installer, by R.G. Studios.
# Sets up the whole local AI stack on a Windows PC with an NVIDIA GPU: tools, llama.cpp, the Python
# environments, ComfyUI, the models you pick, shortcuts and (optionally) the Prestige desktop app.
# Safe to run again: anything already in place is skipped.
#
#   setup.cmd                                   double-click (runs this script)
#   .\install.ps1                               guided install into %USERPROFILE%\RG Studios\Workstation
#   .\install.ps1 -Root D:\AI\Workstation       somewhere else
#   .\install.ps1 -Yes -Packs fast,images       no questions, these model packs
#   .\install.ps1 -Packs none                   software only, no models
# Without cloning first, from PowerShell:
#   irm https://raw.githubusercontent.com/Mr5elfDe5truct/custom-ai-workstation/main/install.ps1 -OutFile "$env:TEMP\install.ps1"
#   powershell -ExecutionPolicy Bypass -File "$env:TEMP\install.ps1"
param(
    [string]$Root,
    [string[]]$Packs,
    [switch]$Yes,
    [switch]$NoPrestige,
    [switch]$NoTest,
    [switch]$NoShortcuts,     # leave the Desktop / Start Menu shortcuts alone
    [switch]$NoComfyDesktop,  # install ComfyUI into the workstation even if Comfy Desktop is present
    [switch]$NoGpuCheck,      # carry on without an NVIDIA GPU (for testing the installer, e.g. in Windows Sandbox)
    [string]$Branch = "main"
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # Invoke-WebRequest's progress bar is very slow in Windows PowerShell
$Repo = "Mr5elfDe5truct/custom-ai-workstation"

# ---------- look and feel ----------
function Say($text, $color = "Gray") { Write-Host $text -ForegroundColor $color }
function Step($n, $text) { Write-Host ""; Write-Host "[$n] $text" -ForegroundColor Yellow }
function Ok($text) { Write-Host "    + $text" -ForegroundColor Green }
function Skip($text) { Write-Host "    = $text" -ForegroundColor DarkGray }
function Warn($text) { Write-Host "    ! $text" -ForegroundColor DarkYellow }
function Ask($question, $default) {
    if ($Yes) { return $default }
    $a = Read-Host "$question [$default]"
    if ([string]::IsNullOrWhiteSpace($a)) { $default } else { $a.Trim() }
}
function AskYesNo($question, [bool]$default) {
    if ($Yes) { return $default }
    $d = if ($default) { "Y/n" } else { "y/N" }
    $a = Read-Host "$question [$d]"
    if ([string]::IsNullOrWhiteSpace($a)) { return $default }
    return $a.Trim().ToLower().StartsWith("y")
}

function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    foreach ($p in "$env:USERPROFILE\.local\bin", "$env:LOCALAPPDATA\Programs\Ollama") {
        if ((Test-Path $p) -and ($env:Path -notlike "*$p*")) { $env:Path += ";$p" }
    }
}
function Has($cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

# winget comes with Windows 11 and recent Windows 10. Where it's missing (older Windows 10, Windows Sandbox,
# LTSC), install App Installer and its dependencies from Microsoft's winget-cli releases on GitHub.
function Ensure-Winget {
    if (Has winget.exe) { return }
    Say "    winget is missing; installing it from github.com/microsoft/winget-cli…"
    $rel = Invoke-RestMethod "https://api.github.com/repos/microsoft/winget-cli/releases/latest" -Headers @{ "User-Agent" = "rg-installer" }
    $tmp = Join-Path $env:TEMP "rg-winget"
    New-Item -ItemType Directory -Force $tmp | Out-Null
    foreach ($n in "DesktopAppInstaller_Dependencies.zip", "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle") {
        $a = $rel.assets | Where-Object { $_.name -eq $n }
        if (-not $a) { throw "Couldn't find $n in the winget release. Install 'App Installer' from the Microsoft Store, then run this again." }
        Download $a.browser_download_url (Join-Path $tmp $n)
    }
    Expand-Archive (Join-Path $tmp "DesktopAppInstaller_Dependencies.zip") (Join-Path $tmp "deps") -Force
    $deps = @(Get-ChildItem (Join-Path $tmp "deps") -Recurse -Include *.appx, *.msix | Where-Object { $_.Directory.Name -eq "x64" })
    if (-not $deps) { throw "The winget dependencies download had no x64 packages. Install 'App Installer' from the Microsoft Store, then run this again." }
    foreach ($d in $deps) {
        try { Add-AppxPackage -Path $d.FullName -ErrorAction Stop; Ok $d.BaseName }
        catch { Warn "$($d.BaseName): $($_.Exception.Message.Split([char]10)[0])" }   # usually a newer version is already there
    }
    Add-AppxPackage -Path (Join-Path $tmp "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle")
    $env:Path += ";$env:LOCALAPPDATA\Microsoft\WindowsApps"
    if (-not (Has winget.exe)) { throw "winget still isn't available. Install 'App Installer' from the Microsoft Store, then run this again." }
    Ok "winget $(winget.exe --version)"
}

function Install-Tool($id, $name, $cmd, $exists) {
    if (($cmd -and (Has $cmd)) -or ($exists -and (Test-Path $exists))) { Skip "$name already installed"; return }
    Ensure-Winget
    Say "    installing $name…"
    winget.exe install --id $id -e --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
    $code = $LASTEXITCODE
    Refresh-Path
    if ($cmd -and -not (Has $cmd)) {
        if ($code) { throw "Installing $name failed (winget exit code $code). Run this again, or install it yourself: winget install $id" }
        Warn "$name installed, but '$cmd' isn't on PATH yet; a new terminal may be needed"
    } elseif ($exists -and -not (Test-Path $exists)) {
        throw "Installing $name failed (winget exit code $code). Run this again, or install it yourself: winget install $id"
    } else { Ok "$name installed" }
}

# Resumable download with curl.exe (ships with Windows 10/11).
function Download($url, $dest) {
    if (Test-Path $dest) { Skip "$(Split-Path $dest -Leaf) already downloaded"; return }
    New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
    $part = "$dest.part"
    Say "    downloading $(Split-Path $dest -Leaf)…"
    & curl.exe -L --fail --retry 5 --retry-delay 3 -C - --progress-bar -o $part $url
    if ($LASTEXITCODE) { throw "Download failed: $url (run install.ps1 again to resume)" }
    Move-Item $part $dest -Force
    Ok (Split-Path $dest -Leaf)
}
function HF($repo, $path) { "https://huggingface.co/$repo/resolve/main/$path" }

# ---------- 1. this PC ----------
Write-Host ""
Write-Host "  Custom AI Workstation  ·  R.G. Studios" -ForegroundColor Red
Write-Host "  A local, private AI stack: chat, voice, vision, images and video." -ForegroundColor DarkGray
Refresh-Path

Step 1 "Checking this PC"
if (-not [Environment]::Is64BitOperatingSystem) { throw "A 64-bit Windows is required." }
$os = (Get-CimInstance Win32_OperatingSystem).Caption
Ok $os
$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
Ok "$ramGB GB RAM"
$cudaMajor = 0; $gpuName = $null; $vramGB = 0
if (Has nvidia-smi) {
    $q = (& nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits | Select-Object -First 1) -split ","
    $gpuName = $q[0].Trim(); $vramGB = [math]::Round([double]$q[1] / 1024)
    $cv = [regex]::Match((& nvidia-smi | Out-String), "CUDA (?:UMD )?Version:\s*([\d.]+)").Groups[1].Value
    $cudaMajor = if ($cv) { [int]($cv.Split(".")[0]) } else { 12 }
    Ok "$gpuName, $vramGB GB VRAM, driver supports CUDA $cv"
    if ($vramGB -lt 8) { Warn "Less than 8 GB of VRAM: stick to the small models" }
} else {
    Warn "No NVIDIA GPU found (nvidia-smi is missing). The stack needs an NVIDIA GPU with a recent driver."
    if (-not $NoGpuCheck -and -not (AskYesNo "Continue anyway?" $false)) { exit 1 }
    $cudaMajor = 12
}
$cudaTag = if ($cudaMajor -ge 13) { "13.4" } else { "12.4" }      # llama.cpp build
$torchIndex = if ($cudaMajor -ge 13) { "cu130" } else { "cu128" }  # PyTorch build for ComfyUI

# ---------- 2. where ----------
Step 2 "Choosing the install folder"
$here = $PSScriptRoot
$runningFromClone = $here -and (Test-Path (Join-Path $here "start-all.ps1"))
if (-not $Root) {
    $default = if ($runningFromClone) { $here } else { Join-Path $env:USERPROFILE "RG Studios\Workstation" }
    $Root = Ask "Install the Workstation in" $default
}
$Root = [IO.Path]::GetFullPath($Root)
Ok $Root
if ($Root -like "$env:ProgramFiles*") { Warn "Program Files isn't a good place: the services write logs, data and models into this folder." }

# ---------- 3. which models ----------
$PackInfo = [ordered]@{
    fast     = @{ GB = 6.7;  Text = "Fast chat      Qwen3.5 9B Uncensored (Ollama) - fits fully on an 8-12 GB GPU" }
    vision   = @{ GB = 8.0;  Text = "Vision         Gemma 4 12B (Ollama) - pictures, the webcam, tools" }
    main     = @{ GB = 22.1; Text = "Main           Qwen3.6 35B Heretic (llama.cpp) - best quality; needs 32 GB RAM" }
    images   = @{ GB = 20.7; Text = "Images         Z-Image-Turbo (ComfyUI) - text to image, ~40 s per picture" }
    video    = @{ GB = 52.1; Text = "Video          LTX-2.3 + Wan 2.2 (ComfyUI) - text/image to video with sound" }
    computer = @{ GB = 6.9;  Text = "Computer use   UI-TARS 1.5 7B (llama.cpp) - drives the mouse and keyboard" }
}
Step 3 "Choosing models"
if (-not $Packs) {
    $defaults = @("fast", "images")
    if ($ramGB -ge 32) { $defaults += "main" }
    if ($Yes) { $Packs = $defaults } else {
        $i = 1
        foreach ($k in $PackInfo.Keys) {
            $mark = if ($defaults -contains $k) { "*" } else { " " }
            Say ("   {0}{1}. {2,-9} {3,5:N1} GB  {4}" -f $mark, $i, $k, $PackInfo[$k].GB, $PackInfo[$k].Text.Substring(15))
            $i++
        }
        Say "   (* = suggested for this PC)  Type numbers or names separated by commas, 'all', or 'none'." DarkGray
        $a = Ask "Model packs" ($defaults -join ",")
        $keys = @($PackInfo.Keys)
        $Packs = @(foreach ($t in ($a -split "[,\s]+" | Where-Object { $_ })) {
            if ($t -eq "all") { $keys } elseif ($t -eq "none") { } elseif ($t -match "^\d+$") { $keys[[int]$t - 1] } else { $t.ToLower() }
        })
    }
}
# -Packs fast,images arrives as one string when run with -File (setup.cmd), so split it here too.
$Packs = @(foreach ($t in ($Packs -split "[,\s]+" | Where-Object { $_ })) { if ($t -eq "all") { @($PackInfo.Keys) } else { $t.ToLower() } })
$Packs = @($Packs | Where-Object { $_ -and $_ -ne "none" } | Select-Object -Unique)
foreach ($p in $Packs) { if (-not $PackInfo.Contains($p)) { throw "Unknown model pack '$p'. Choose from: $($PackInfo.Keys -join ', '), all, none" } }
if ($Packs -contains "main" -and $ramGB -lt 32) { Warn "The main model wants 32 GB of RAM; with $ramGB GB it may not load." }
$needGB = 12 + ($Packs | ForEach-Object { $PackInfo[$_].GB } | Measure-Object -Sum).Sum   # ~12 GB for software
$drive = Get-PSDrive ((Split-Path $Root -Qualifier).TrimEnd(":"))
$freeGB = [math]::Round($drive.Free / 1GB)
Ok ("Packs: " + $(if ($Packs) { $Packs -join ", " } else { "none (software only)" }) + " · about $([math]::Round($needGB)) GB needed, $freeGB GB free on $($drive.Name):")
if ($freeGB -lt $needGB) {
    Warn "Not enough free space for everything you picked."
    if (-not (AskYesNo "Continue anyway?" $false)) { exit 1 }
}
if (-not $Yes -and -not (AskYesNo "Ready to install?" $true)) { exit 0 }

# ---------- 4. tools ----------
Step 4 "Installing tools (winget)"
# llama.cpp, PyTorch and ComfyUI need the Visual C++ runtime, which a clean Windows may not have.
Install-Tool "Microsoft.VCRedist.2015+.x64" "Visual C++ runtime" $null "$env:windir\System32\vcruntime140_1.dll"
Install-Tool "Git.Git" "Git" "git"
Install-Tool "astral-sh.uv" "uv (Python environments)" "uv"
Install-Tool "OpenJS.NodeJS.LTS" "Node.js (tool servers)" "node"
Install-Tool "Gyan.FFmpeg" "FFmpeg (audio and video)" "ffmpeg"
Install-Tool "Ollama.Ollama" "Ollama" "ollama"
Install-Tool "eSpeak-NG.eSpeak-NG" "eSpeak NG (voice)" $null "$env:ProgramFiles\eSpeak NG\libespeak-ng.dll"

# ---------- 5. the workstation files ----------
Step 5 "Getting the Workstation"
if (Test-Path (Join-Path $Root "start-all.ps1")) {
    Skip "already here"
} else {
    if ((Test-Path $Root) -and (Get-ChildItem $Root -Force | Select-Object -First 1)) { throw "$Root exists and isn't empty. Pick another folder." }
    New-Item -ItemType Directory -Force (Split-Path $Root) | Out-Null
    git clone --branch $Branch "https://github.com/$Repo.git" $Root
    if ($LASTEXITCODE) { throw "git clone failed" }
    Ok "cloned $Repo"
}
Set-Location $Root
foreach ($d in "apps", "bin", "envs", "logs", "data", "models\gguf", "models\ollama", "models\comfy") {
    New-Item -ItemType Directory -Force (Join-Path $Root $d) | Out-Null
}

# ---------- 6. llama.cpp ----------
Step 6 "llama.cpp (CUDA $cudaTag build)"
$llama = Join-Path $Root "bin\llama.cpp"
if (Test-Path "$llama\llama-server.exe") { Skip "already installed" } else {
    $rels = Invoke-RestMethod "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=30" -Headers @{ "User-Agent" = "rg-installer" }
    $rel = $rels | Where-Object { $_.assets.name -match "^llama-b\d+-bin-win-cuda-$([regex]::Escape($cudaTag))-x64\.zip$" } | Select-Object -First 1
    if (-not $rel) { throw "Couldn't find a llama.cpp Windows CUDA $cudaTag build on GitHub." }
    $tmp = Join-Path $env:TEMP "rg-llama"; New-Item -ItemType Directory -Force $tmp | Out-Null
    foreach ($a in $rel.assets | Where-Object { $_.name -match "^(llama-b\d+|cudart-llama)-bin-win-cuda-$([regex]::Escape($cudaTag))-x64\.zip$" }) {
        $zip = Join-Path $tmp $a.name
        Download $a.browser_download_url $zip
        Expand-Archive $zip -DestinationPath $llama -Force
    }
    if (-not (Test-Path "$llama\llama-server.exe")) { throw "llama.cpp didn't unpack as expected." }
    Ok "llama.cpp $($rel.tag_name)"
}

# ---------- 7. Python environments ----------
Step 7 "Python environments (pinned to the tested versions)"
& uv python install 3.11 3.12 | Out-Null
function New-Env($name, $python, $req, [string[]]$extra) {
    $envDir = Join-Path $Root "envs\$name"
    if (Test-Path "$envDir\Scripts\python.exe") { Skip "$name already set up"; return }
    & uv venv $envDir --python $python -q
    & uv pip install -p $envDir -r (Join-Path $Root "requirements\$req") @extra -q
    if ($LASTEXITCODE) { throw "Installing the $name environment failed" }
    Ok $name
}
New-Env "open-webui" "3.11" "open-webui.txt"
New-Env "tools" "3.12" "tools.txt"

# Kokoro text-to-speech: the FastAPI server at the tested commit, its environment and voice model.
$kokoro = Join-Path $Root "apps\Kokoro-FastAPI"
if (-not (Test-Path "$kokoro\api")) {
    git clone https://github.com/remsky/Kokoro-FastAPI.git $kokoro -q
    git -C $kokoro checkout -q b4ef64b1ce60682debda4fe0a066259e284eb1b4
    Ok "Kokoro-FastAPI"
}
New-Env "kokoro" "3.12" "kokoro.txt" @("--extra-index-url", "https://download.pytorch.org/whl/cpu", "--index-strategy", "unsafe-best-match")
& uv pip install -p (Join-Path $Root "envs\kokoro") --no-deps -e $kokoro -q
$voiceModel = "$kokoro\api\src\models\v1_0"
Download (HF "hexgrad/Kokoro-82M" "kokoro-v1_0.pth") "$voiceModel\kokoro-v1_0.pth"
Download (HF "hexgrad/Kokoro-82M" "config.json") "$voiceModel\config.json"

# ---------- 8. ComfyUI ----------
Step 8 "ComfyUI (images and video)"
# With several Comfy Desktop installs, use the one that has the GGUF nodes, then the most recently used (same as start-all.ps1).
$desk = Get-ChildItem "$env:LOCALAPPDATA\Comfy-Desktop\ComfyUI-Installs" -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path "$($_.FullName)\ComfyUI\.venv\Scripts\python.exe" } |
    Sort-Object @{ Expression = { Test-Path "$($_.FullName)\ComfyUI\custom_nodes\ComfyUI-GGUF" }; Descending = $true },
                @{ Expression = { (Get-Item "$($_.FullName)\ComfyUI\custom_nodes").LastWriteTime }; Descending = $true } |
    Select-Object -First 1
$comfy = Join-Path $Root "apps\ComfyUI"
if ($desk -and -not $NoComfyDesktop -and -not (Test-Path "$comfy\main.py")) {
    Skip "using your Comfy Desktop install ($($desk.Name))"
    $nodes = "$($desk.FullName)\ComfyUI\custom_nodes"; $comfyPy = "$($desk.FullName)\ComfyUI\.venv\Scripts\python.exe"
} else {
    if (-not (Test-Path "$comfy\main.py")) {
        git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git $comfy -q
        Ok "ComfyUI"
    }
    $comfyEnv = Join-Path $Root "envs\comfyui"
    if (-not (Test-Path "$comfyEnv\Scripts\python.exe")) {
        & uv venv $comfyEnv --python 3.12 -q
        Say "    installing PyTorch for CUDA ($torchIndex), about 3 GB…"
        & uv pip install -p $comfyEnv torch torchvision torchaudio --index-url "https://download.pytorch.org/whl/$torchIndex" -q
        & uv pip install -p $comfyEnv -r "$comfy\requirements.txt" -q
        if ($LASTEXITCODE) { throw "Installing ComfyUI's environment failed" }
        Ok "ComfyUI environment"
    } else { Skip "ComfyUI environment already set up" }
    $nodes = "$comfy\custom_nodes"; $comfyPy = "$comfyEnv\Scripts\python.exe"
}
# Custom nodes the workflows use: GGUF model loaders and KJNodes (VAELoaderKJ).
foreach ($n in @(@{ Name = "ComfyUI-GGUF"; Url = "https://github.com/city96/ComfyUI-GGUF.git" },
                 @{ Name = "ComfyUI-KJNodes"; Url = "https://github.com/kijai/ComfyUI-KJNodes.git" })) {
    $dir = Join-Path $nodes $n.Name
    if (Test-Path $dir) { Skip "$($n.Name) already there"; continue }
    git clone --depth 1 $n.Url $dir -q
    if (Test-Path "$dir\requirements.txt") {
        $venv = Split-Path (Split-Path $comfyPy)
        & uv pip install -p $venv -r "$dir\requirements.txt" -q
    }
    Ok $n.Name
}

# ---------- 9. models ----------
Step 9 "Models"
$gguf = Join-Path $Root "models\gguf"
$comfyModels = Join-Path $Root "models\comfy"
$ollamaPacks = @{ fast = "hf.co/LEONW24/Qwen3.5-9B-Uncensored:Q4_K_M"; vision = "gemma4:12b" }
$pulls = @($Packs | Where-Object { $ollamaPacks.ContainsKey($_) } | ForEach-Object { $ollamaPacks[$_] })
if ($pulls) {
    # Pull into the workstation's own model store, using a temporary Ollama server pointed at it.
    $env:OLLAMA_MODELS = Join-Path $Root "models\ollama"
    if (Get-NetTCPConnection -LocalPort 11434 -State Listen -ErrorAction SilentlyContinue) {
        Say "    stopping the Ollama tray app so the models go into the workstation folder…"
        Get-Process "ollama app", ollama -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep 2
    }
    $ollamaExe = (Get-Command ollama -ErrorAction SilentlyContinue).Source
    if (-not $ollamaExe) { $ollamaExe = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe" }
    $srv = Start-Process $ollamaExe "serve" -WindowStyle Hidden -PassThru
    Start-Sleep 4
    foreach ($m in $pulls) { Say "    ollama pull $m"; & $ollamaExe pull $m; if ($LASTEXITCODE) { Warn "couldn't pull $m" } else { Ok $m } }
    Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue
}
if ($Packs -contains "main") {
    Download (HF "Youssofal/Qwen3.6-35B-A3B-Abliterated-Heretic-GGUF" "Qwen3.6-35B-A3B-Abliterated-Heretic-Q4_K_M/Qwen3.6-35B-A3B-Abliterated-Heretic-Q4_K_M.gguf") "$gguf\qwen3.6-35b-a3b-heretic-Q4_K_M.gguf"
    Download (HF "Youssofal/Qwen3.6-35B-A3B-Abliterated-Heretic-GGUF" "mmproj-Qwen3.6-35B-A3B-Abliterated-Heretic.gguf") "$gguf\qwen3.6-35b-a3b-heretic-mmproj.gguf"
}
if ($Packs -contains "computer") {
    Download (HF "Mungert/UI-TARS-1.5-7B-GGUF" "UI-TARS-1.5-7B-q5_k_m.gguf") "$gguf\UI-TARS-1.5-7B-q5_k_m.gguf"
    Download (HF "Mungert/UI-TARS-1.5-7B-GGUF" "UI-TARS-1.5-7B-f16.mmproj") "$gguf\UI-TARS-1.5-7B-f16.mmproj"
    Say "    For the computer-use app itself, install UI-TARS Desktop into apps\ui-tars-desktop: https://github.com/bytedance/UI-TARS-desktop/releases" DarkGray
}
if ($Packs -contains "images") {
    Download (HF "Comfy-Org/z_image_turbo" "split_files/diffusion_models/z_image_turbo_bf16.safetensors") "$comfyModels\diffusion_models\z_image_turbo_bf16.safetensors"
    Download (HF "Comfy-Org/z_image_turbo" "split_files/text_encoders/qwen_3_4b.safetensors") "$comfyModels\text_encoders\qwen_3_4b.safetensors"
    Download (HF "Comfy-Org/z_image_turbo" "split_files/vae/ae.safetensors") "$comfyModels\vae\ae.safetensors"
}
if ($Packs -contains "video") {
    $v = @(
        @("jayn7/WAN2.2-I2V_A14B-DISTILL-LIGHTX2V-4STEP-GGUF", "high_noise_260412/wan2.2_i2v_A14b_high_noise_lightx2v_4step_720p_260412-Q4_K_M.gguf", "unet"),
        @("jayn7/WAN2.2-I2V_A14B-DISTILL-LIGHTX2V-4STEP-GGUF", "low_noise_260412/wan2.2_i2v_A14b_low_noise_lightx2v_4step_720p_260412-Q4_K_M.gguf", "unet"),
        @("Comfy-Org/Wan_2.1_ComfyUI_repackaged", "split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors", "text_encoders"),
        @("Comfy-Org/Wan_2.1_ComfyUI_repackaged", "split_files/vae/wan_2.1_vae.safetensors", "vae"),
        @("unsloth/LTX-2.3-GGUF", "distilled-1.1/ltx-2.3-22b-distilled-1.1-Q4_K_M.gguf", "unet"),
        @("unsloth/LTX-2.3-GGUF", "text_encoders/ltx-2.3-22b-distilled_embeddings_connectors.safetensors", "text_encoders"),
        @("unsloth/LTX-2.3-GGUF", "vae/ltx-2.3-22b-distilled_video_vae.safetensors", "vae"),
        @("unsloth/LTX-2.3-GGUF", "vae/ltx-2.3-22b-distilled_audio_vae.safetensors", "vae"),
        @("unsloth/gemma-3-12b-it-qat-GGUF", "gemma-3-12b-it-qat-UD-Q4_K_XL.gguf", "text_encoders")
    )
    foreach ($f in $v) { Download (HF $f[0] $f[1]) (Join-Path $comfyModels "$($f[2])\$(Split-Path $f[1] -Leaf)") }
}
if (-not $Packs) { Skip "no model packs picked (add them later with: .\install.ps1 -Packs fast,images)" }

# ---------- 10. shortcuts and Prestige ----------
Step 10 "Shortcuts and the Prestige app"
if ($NoShortcuts) { Skip "shortcuts left as they are" } else {
    & (Join-Path $Root "install-shortcut.ps1") | Out-Null
    Ok "Custom AI shortcuts (Desktop and Start Menu)"
}
$prestigeInstalled = Test-Path "$env:ProgramFiles\RG Studios\Prestige\prestige.exe"
if ($prestigeInstalled) { Skip "Prestige already installed" }
elseif (-not $NoPrestige -and (AskYesNo "Install Prestige, the desktop app for the Workstation?" $true)) {
    $rel = Invoke-RestMethod "https://api.github.com/repos/Mr5elfDe5truct/prestige/releases/latest" -Headers @{ "User-Agent" = "rg-installer" }
    $asset = $rel.assets | Where-Object { $_.name -like "*_x64-setup.exe" } | Select-Object -First 1
    $exe = Join-Path $env:TEMP $asset.name
    Download $asset.browser_download_url $exe
    Say "    running the Prestige installer (Windows will ask for permission)…"
    Start-Process $exe -Wait
    Ok "Prestige $($rel.tag_name)"
}

# ---------- 11. smoke test ----------
if (-not $NoTest) {
    Step 11 "Starting everything once to check it works"
    $up = { param($port) [bool](Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) }
    & (Join-Path $Root "start-all.ps1") -NoBrowser | Out-Null
    $checks = [ordered]@{ "Ollama" = 11434; "llama.cpp" = 8081; "Open WebUI" = 8080; "ComfyUI" = 8188; "Kokoro voice" = 8880; "Tool server" = 8200 }
    $deadline = (Get-Date).AddMinutes(4)
    do { Start-Sleep 3; $missing = @($checks.Keys | Where-Object { -not (& $up $checks[$_]) }) } while ($missing -and (Get-Date) -lt $deadline)
    foreach ($k in $checks.Keys) { if (& $up $checks[$k]) { Ok "$k (:$($checks[$k]))" } else { Warn "$k didn't start; see $Root\logs" } }
    & (Join-Path $Root "stop-all.ps1") | Out-Null
    Ok "stopped again"
}

Write-Host ""
Write-Host "  Done. The Workstation is in $Root" -ForegroundColor Green
Write-Host "  Open Prestige (or the 'Custom AI' shortcut) to start it; closing the window stops it." -ForegroundColor Gray
if ($Root -ne (Join-Path $env:USERPROFILE "RG Studios\Workstation")) {
    Write-Host "  In Prestige, set Settings > Workstation folder to $Root (it looks in your user folder by default)." -ForegroundColor Yellow
}
Write-Host "  Add model packs any time: .\install.ps1 -Packs vision,video" -ForegroundColor Gray
Write-Host ""
