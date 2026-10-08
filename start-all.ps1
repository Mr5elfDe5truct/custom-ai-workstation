# Starts the Custom AI workstation. Open http://localhost:8080 when it finishes.
#   .\start-all.ps1            everything
#   .\start-all.ps1 -NoComfy   skip the headless ComfyUI (use this if you prefer the Comfy Desktop app)
#   .\start-all.ps1 -NoBrowser don't open the app window at the end
#   .\start-all.ps1 -Theme neon default theme: dragon, neon, glass, hud or off (Ctrl+Alt+T switches in the app)
#   .\start-all.ps1 -GpuMode pool  with several GPUs: split (default), pool or single, for this start only
#                                  (data\gpu-settings.json sets it for good; see docs\GPUS.md)
param([switch]$NoComfy, [switch]$NoBrowser,
      [ValidateSet("dragon", "neon", "glass", "hud", "off")][string]$Theme = "dragon",
      [ValidateSet("", "auto", "single", "split", "pool")][string]$GpuMode = "")

$Root = $PSScriptRoot
$Logs = Join-Path $Root "logs"
New-Item -ItemType Directory -Force $Logs | Out-Null

# ---------- configs for this folder ----------
# bin\llama-models.ini and tools\mcpo-config.json use {ROOT} (this folder) and {HOME} (the user's profile), so the
# workstation runs from wherever it's installed. The real files are written to data\runtime on every start.
$Runtime = Join-Path $Root "data\runtime"
New-Item -ItemType Directory -Force $Runtime | Out-Null
function Expand-Template($src, $dst, [switch]$Json) {
    $r = $Root; $h = $env:USERPROFILE
    if ($Json) { $r = $r.Replace('\', '\\'); $h = $h.Replace('\', '\\') }
    $text = (Get-Content -Raw $src).Replace('{ROOT}', $r).Replace('{HOME}', $h)
    [IO.File]::WriteAllText($dst, $text, (New-Object Text.UTF8Encoding $false))
}
# Which GPU each service runs on (scripts\gpu-config.ps1), saved for Prestige and the voice and tool servers.
. "$Root\scripts\gpu-config.ps1"
$GpuPlan = Get-GpuPlan $Root $GpuMode
# Each service's cards (and ComfyUI's second-card parts), as start-all.ps1 last saved them.
$placement = {
    if (-not (Test-Path "$Runtime\gpu.json")) { return @{} }
    $j = Get-Content -Raw "$Runtime\gpu.json" | ConvertFrom-Json
    $p = @{}
    foreach ($s in $j.services.PSObject.Properties) { $p[$s.Name] = @($s.Value) -join "," }
    if ($p.comfyui) { $p.comfyui += "|" + (@($j.comfyAux) -join ",") }
    $p
}
$before = & $placement
Save-GpuPlan $GpuPlan "$Runtime\gpu.json"
$after = & $placement
# Services whose cards changed: one that's already running stays on its old card until it restarts.
$GpuMoved = @(if ($before.Count) { $after.Keys | Where-Object { $before[$_] -ne $after[$_] } })
Expand-Template "$Root\bin\llama-models.ini" "$Runtime\llama-models.ini"
# On anything but one 12 GB card, the ini's hand-tuned offload settings give way to llama.cpp's --fit.
[IO.File]::WriteAllText("$Runtime\llama-models.ini", (Convert-LlamaIni (Get-Content -Raw "$Runtime\llama-models.ini") $GpuPlan),
    (New-Object Text.UTF8Encoding $false))
# The tool server's config, with any tools added from Prestige's tool store (scripts\tool-config.ps1).
. "$Root\scripts\tool-config.ps1"
Write-ToolConfig $Root $Runtime

# ComfyUI: the one install.ps1 puts in apps\ComfyUI, or else an existing Comfy Desktop install.
$ComfyDir = $null; $ComfyPython = $null
if (Test-Path "$Root\apps\ComfyUI\main.py") {
    $ComfyDir = "$Root\apps\ComfyUI"; $ComfyPython = "$Root\envs\comfyui\Scripts\python.exe"
} else {
    # With several Comfy Desktop installs, use the one that has the GGUF nodes, then the most recently used.
    $desk = Get-ChildItem "$env:LOCALAPPDATA\Comfy-Desktop\ComfyUI-Installs" -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path "$($_.FullName)\ComfyUI\.venv\Scripts\python.exe" } |
        Sort-Object @{ Expression = { Test-Path "$($_.FullName)\ComfyUI\custom_nodes\ComfyUI-GGUF" }; Descending = $true },
                    @{ Expression = { (Get-Item "$($_.FullName)\ComfyUI\custom_nodes").LastWriteTime }; Descending = $true } |
        Select-Object -First 1
    if ($desk) { $ComfyDir = "$($desk.FullName)\ComfyUI"; $ComfyPython = "$ComfyDir\.venv\Scripts\python.exe" }
}
# Model folders ComfyUI should see: the workstation's models\comfy, plus Comfy Desktop's shared models if present.
# models\comfy-fast is optional: when models\comfy links to a slower disk, keep the models you use most there.
$yaml = "# Written by start-all.ps1 on every start.`n"
foreach ($dir in "comfy", "comfy-fast") {
    if ($dir -ne "comfy" -and -not (Test-Path "$Root\models\$dir")) { continue }
    $yaml += @"
workstation_$($dir.Replace('-', '_')):
  base_path: $Root\models\$dir
  checkpoints: checkpoints/
  diffusion_models: |
    diffusion_models/
    unet/
  unet: unet/
  text_encoders: text_encoders/
  clip: text_encoders/
  vae: vae/
  loras: loras/
  latent_upscale_models: latent_upscale_models/
  upscale_models: upscale_models/
  clip_vision: clip_vision/
  geometry_estimation: geometry_estimation/
  background_removal: background_removal/
  model_patches: model_patches/
  audio_encoders: audio_encoders/

"@
}
$shared ="$env:LOCALAPPDATA\Comfy-Desktop\ComfyUI-Shared\models"
if (Test-Path $shared) {
    $yaml += @"

comfy_desktop_shared:
  base_path: $shared
  is_default: true
  checkpoints: checkpoints/
  diffusion_models: diffusion_models/
  unet: unet/
  text_encoders: text_encoders/
  clip: clip/
  clip_vision: clip_vision/
  vae: vae/
  loras: loras/
  upscale_models: upscale_models/
  latent_upscale_models: latent_upscale_models/
  audio_encoders: audio_encoders/
  model_patches: model_patches/
  controlnet: controlnet/
  embeddings: embeddings/
"@
}
[IO.File]::WriteAllText("$Runtime\comfy-extra-models.yaml", $yaml, (New-Object Text.UTF8Encoding $false))

function Test-Port($port) {
    [bool](Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
}

# $gpuService: the service in the GPU plan whose cards this process may use (none: it doesn't use the GPU).
function Start-Bg($name, $port, $exe, $argList, $workDir = $Root, $gpuService = $null) {
    if (Test-Port $port) {
        $where = if ($gpuService -and $GpuMoved -contains $gpuService) { "; it stays on the GPU it started on (stop-all.ps1 and start again to move it)" } else { "" }
        Write-Host "  $name already running (port $port)$where"; return
    }
    if ($gpuService) { Set-ServiceGpus $GpuPlan $gpuService } else { Remove-Item Env:CUDA_VISIBLE_DEVICES -ErrorAction SilentlyContinue }
    Start-Process -FilePath $exe -ArgumentList $argList -WorkingDirectory $workDir -WindowStyle Hidden `
        -RedirectStandardOutput "$Logs\$name.log" -RedirectStandardError "$Logs\$name.err.log"
    Write-Host "  started $name (port $port)"
}

Write-Host "Starting Custom AI workstation..."
Write-Host (Format-GpuPlan $GpuPlan)

# 1. Ollama: Gemma 4 (webcam/vision), Qwen3.5-9B uncensored, coders. Unloads after 5 min idle.
#    With several GPUs it runs on the small card (split), so chat stays loaded while ComfyUI renders on the big one.
$env:OLLAMA_MODELS = "$Root\models\ollama"
$env:OLLAMA_KEEP_ALIVE = "5m"
# Ollama picks 4096 tokens on a 12 GB card, which the memory + tool prompts overflow (~6k tokens
# for a bare "Hello" in voice mode). 32k with a q8 KV cache still fits each model on a 12 GB card; the GPU plan
# gives smaller cards 16k (8k under 5.5 GB) so the model stays on the GPU.
$env:OLLAMA_CONTEXT_LENGTH = if ($GpuPlan) { "$($GpuPlan.OllamaContext)" } else { "32768" }
$env:OLLAMA_FLASH_ATTENTION = "1"
$env:OLLAMA_KV_CACHE_TYPE = "q8_0"
Start-Bg "ollama" 11434 "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe" "serve" $Root "ollama"

# 2. llama.cpp router: Qwen3.6-35B and Qwen3.8-27B uncensored + UI-TARS, loaded on demand, one at a time,
#    unloaded after 3 min idle so ComfyUI gets the GPU back.
Start-Bg "llama-server" 8081 "$Root\bin\llama.cpp\llama-server.exe" @(
    "--models-preset", "`"$Runtime\llama-models.ini`"", "--models-max", "1",
    "--sleep-idle-seconds", "180", "--host", "127.0.0.1", "--port", "8081") $Root "llama"

# 3. Kokoro text-to-speech (CPU).
$k = "$Root\apps\Kokoro-FastAPI"
$env:PHONEMIZER_ESPEAK_LIBRARY = "C:\Program Files\eSpeak NG\libespeak-ng.dll"
$env:PYTHONUTF8 = "1"
$env:PROJECT_ROOT = $k
$env:USE_GPU = "false"
$env:PYTHONPATH = "$k;$k\api"
$env:MODEL_DIR = "src/models"
$env:VOICES_DIR = "src/voices/v1_0"
$env:WEB_PLAYER_PATH = "$k\web"
Start-Bg "kokoro" 8880 "$Root\envs\kokoro\Scripts\python.exe" `
    "-m uvicorn api.src.main:app --host 127.0.0.1 --port 8880" $k
Remove-Item Env:PYTHONPATH

# 3b. Voice server (voice pack): Whisper large-v3-turbo speech-to-text and VoxCPM2 text-to-speech on the GPU,
#     each loaded on first use and unloaded when idle.
$Voice = Test-Path "$Root\envs\voice\Scripts\python.exe"
if ($Voice) {
    $env:HF_HUB_DISABLE_SYMLINKS_WARNING = "1"
    Start-Bg "voice" 8890 "$Root\envs\voice\Scripts\python.exe" "`"$Root\tools\voice_server.py`"" $Root "voice"
}

# 3c. Phonon server (transcribe pack): Phonon-2 speech-to-text on the CPU, the Whisper API shape on :8891. Prestige's
#     Transcribe uses it (tools\transcribe.py), and Live calls can listen with it instead of Whisper. ~2 GB of RAM, no VRAM.
if (Test-Path "$Root\envs\transcribe\Scripts\fermion.exe") {
    $env:HF_HUB_DISABLE_SYMLINKS_WARNING = "1"
    Start-Bg "phonon" 8891 "$Root\envs\transcribe\Scripts\fermion.exe" "serve phonon-2 --port 8891" $Root
}

# 4. Tool server: research scout, webcam, video jobs, web fetch, files, shell (Desktop Commander), browser (Playwright),
#    plus tools added from Prestige's tool store. --hot-reload picks up added and removed tools while it runs.
Start-Bg "mcpo" 8200 "$Root\envs\tools\Scripts\mcpo.exe" (Get-McpoArgs $Runtime)

# 5. ComfyUI (images + video), headless, using Comfy Desktop's install and both model folders.
#    --disable-smart-memory moves models off the GPU after each job so the chat models can use it.
if (-not $NoComfy -and $ComfyDir) {
    # The Workstation's own node: with two cards for ComfyUI, text encoders, VAEs and the LTX upscaler go on the second
    # (it does nothing otherwise). Copied on every start so it follows this folder's version.
    Copy-Item "$Root\tools\comfy_nodes\workstation_gpus" "$ComfyDir\custom_nodes" -Recurse -Force
    Start-Bg "comfyui" 8188 $ComfyPython @(
        "main.py", "--listen", "127.0.0.1", "--port", "8188", "--disable-smart-memory",
        "--extra-model-paths-config", "`"$Runtime\comfy-extra-models.yaml`"",
        "--output-directory", "`"$Root\data\comfy-output`"") $ComfyDir "comfyui"
    Remove-Item Env:WORKSTATION_COMFY_AUX_DEVICE, Env:WORKSTATION_COMFY_AUX_PARTS -ErrorAction SilentlyContinue
} elseif (-not $NoComfy) {
    Write-Host "  ComfyUI isn't installed (run install.ps1), so images and video are off"
}

# 6. Open WebUI (single user, only reachable from this PC).
$env:DATA_DIR = "$Root\data\open-webui"
$env:WEBUI_AUTH = "False"
$env:OLLAMA_BASE_URL = "http://127.0.0.1:11434"
$env:OPENAI_API_BASE_URLS = "http://127.0.0.1:8081/v1"
$env:OPENAI_API_KEYS = "none"
# Long-term memory shared by every model: saved facts are injected into each chat, and every 4 turns
# the model reviews the conversation and saves anything worth remembering.
$env:ENABLE_MEMORIES = "True"
$env:ENABLE_MEMORY_SYSTEM_CONTEXT = "True"
$env:ENABLE_MEMORY_BACKGROUND_REVIEW = "True"
$env:MEMORIES_REVIEW_INTERVAL_TURNS = "4"
$env:MEMORIES_USER_CHAR_LIMIT = "6000"
$env:MEMORIES_CONTEXT_CHAR_LIMIT = "6000"
$env:ENABLE_EVALUATION_ARENA_MODELS = "False"
$env:ENABLE_WEB_SEARCH = "True"
$env:WEB_SEARCH_ENGINE = "duckduckgo"
$env:WHISPER_MODEL = "base"
if ($Voice) {
    # Speech-to-text through the voice server (Whisper large-v3-turbo on the GPU); the built-in Whisper above runs
    # on the CPU, where turbo takes ~25 s a sentence. Existing installs are switched over once by the script below.
    $env:AUDIO_STT_ENGINE = "openai"
    $env:AUDIO_STT_OPENAI_API_BASE_URL = "http://127.0.0.1:8890/v1"
    $env:AUDIO_STT_OPENAI_API_KEY = "none"
    $env:AUDIO_STT_MODEL = "whisper-large-v3-turbo"
    if (-not (Test-Port 8080)) {
        & "$Root\envs\open-webui\Scripts\python.exe" "$Root\scripts\owui-voice-config.py" "$Root\data\open-webui\webui.db"
    }
}
$env:AUDIO_TTS_ENGINE = "openai"
$env:AUDIO_TTS_OPENAI_API_BASE_URL = "http://127.0.0.1:8880/v1"
$env:AUDIO_TTS_OPENAI_API_KEY = "none"
$env:AUDIO_TTS_MODEL = "kokoro"
$env:AUDIO_TTS_VOICE = "af_heart"
$env:ENABLE_IMAGE_GENERATION = "True"
$env:IMAGE_GENERATION_ENGINE = "comfyui"
$env:COMFYUI_BASE_URL = "http://127.0.0.1:8188"
$env:TOOL_SERVER_CONNECTIONS = '[{"url":"http://127.0.0.1:8200/workstation","path":"openapi.json","auth_type":"none","key":"","config":{"enable":true},"info":{"id":"workstation","name":"workstation"}},{"url":"http://127.0.0.1:8200/fetch","path":"openapi.json","auth_type":"none","key":"","config":{"enable":true},"info":{"id":"fetch","name":"fetch"}},{"url":"http://127.0.0.1:8200/filesystem","path":"openapi.json","auth_type":"none","key":"","config":{"enable":true},"info":{"id":"filesystem","name":"filesystem"}},{"url":"http://127.0.0.1:8200/desktop","path":"openapi.json","auth_type":"none","key":"","config":{"enable":true},"info":{"id":"desktop","name":"desktop"}},{"url":"http://127.0.0.1:8200/browser","path":"openapi.json","auth_type":"none","key":"","config":{"enable":true},"info":{"id":"browser","name":"browser"}}]'
# Theme: Open WebUI serves /static/custom.css and /static/loader.js on every page, refilling its static folder
# from frontend\static at startup. Copy ours into both so they survive updates and apply without a restart.
$owui = "$Root\envs\open-webui\Lib\site-packages\open_webui"
$loader = "window.CAI_DEFAULT_THEME = '$Theme';`n" + (Get-Content -Raw "$Root\theme\loader.js")
foreach ($dir in "$owui\frontend\static", "$owui\static") {
    if (Test-Path $dir) {
        Copy-Item "$Root\theme\custom.css" "$dir\custom.css" -Force
        Set-Content -Path "$dir\loader.js" -Value $loader -Encoding UTF8
    }
}
Start-Bg "open-webui" 8080 "$Root\envs\open-webui\Scripts\open-webui.exe" "serve --host 127.0.0.1 --port 8080" $Root "openwebui"
Remove-Item Env:CUDA_VISIBLE_DEVICES -ErrorAction SilentlyContinue

Write-Host "Waiting for Open WebUI..."
for ($i = 0; $i -lt 90; $i++) {
    if (Test-Port 8080) { break }; Start-Sleep 2
}
if (-not $NoBrowser) { & "$Root\open-app.ps1" -NoStart }
Write-Host "Ready."
Write-Host "  Chat:     http://localhost:8080"
Write-Host "  ComfyUI:  http://localhost:8188"
Write-Host "  Logs:     $Logs"
