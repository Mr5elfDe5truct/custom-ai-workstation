# Starts the Custom AI workstation. Open http://localhost:8080 when it finishes.
#   .\start-all.ps1            everything
#   .\start-all.ps1 -NoComfy   skip the headless ComfyUI (use this if you prefer the Comfy Desktop app)
#   .\start-all.ps1 -NoBrowser don't open the app window at the end
param([switch]$NoComfy, [switch]$NoBrowser)

$Root = $PSScriptRoot
$Logs = Join-Path $Root "logs"
New-Item -ItemType Directory -Force $Logs | Out-Null
$ComfyInstall = "$env:LOCALAPPDATA\Comfy-Desktop\ComfyUI-Installs\My Anime Workflow"

function Test-Port($port) {
    [bool](Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
}

function Start-Bg($name, $port, $exe, $argList, $workDir = $Root) {
    if (Test-Port $port) { Write-Host "  $name already running (port $port)"; return }
    Start-Process -FilePath $exe -ArgumentList $argList -WorkingDirectory $workDir -WindowStyle Hidden `
        -RedirectStandardOutput "$Logs\$name.log" -RedirectStandardError "$Logs\$name.err.log"
    Write-Host "  started $name (port $port)"
}

Write-Host "Starting Custom AI workstation..."

# 1. Ollama: Gemma 4 (webcam/vision), Qwen3.5-9B uncensored, coders. Unloads after 5 min idle.
$env:OLLAMA_MODELS = "$Root\models\ollama"
$env:OLLAMA_KEEP_ALIVE = "5m"
Start-Bg "ollama" 11434 "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe" "serve"

# 2. llama.cpp router: Qwen3.6-35B uncensored + UI-TARS, loaded on demand, one at a time,
#    unloaded after 3 min idle so ComfyUI gets the GPU back.
Start-Bg "llama-server" 8081 "$Root\bin\llama.cpp\llama-server.exe" @(
    "--models-preset", "`"$Root\bin\llama-models.ini`"", "--models-max", "1",
    "--sleep-idle-seconds", "180", "--host", "127.0.0.1", "--port", "8081")

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

# 4. Tool server: research scout, webcam, video jobs, web fetch, files, shell (Desktop Commander), browser (Playwright).
Start-Bg "mcpo" 8200 "$Root\envs\tools\Scripts\mcpo.exe" `
    "--host 127.0.0.1 --port 8200 --config `"$Root\tools\mcpo-config.json`""

# 5. ComfyUI (images + video), headless, using Comfy Desktop's install and both model folders.
#    --disable-smart-memory moves models off the GPU after each job so the chat models can use it.
if (-not $NoComfy) {
    Start-Bg "comfyui" 8188 "$ComfyInstall\ComfyUI\.venv\Scripts\python.exe" @(
        "main.py", "--listen", "127.0.0.1", "--port", "8188", "--disable-smart-memory",
        "--extra-model-paths-config", "`"$Root\bin\comfy-extra-models.yaml`"",
        "--output-directory", "`"$Root\data\comfy-output`"") "$ComfyInstall\ComfyUI"
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
$env:AUDIO_TTS_ENGINE = "openai"
$env:AUDIO_TTS_OPENAI_API_BASE_URL = "http://127.0.0.1:8880/v1"
$env:AUDIO_TTS_OPENAI_API_KEY = "none"
$env:AUDIO_TTS_MODEL = "kokoro"
$env:AUDIO_TTS_VOICE = "af_heart"
$env:ENABLE_IMAGE_GENERATION = "True"
$env:IMAGE_GENERATION_ENGINE = "comfyui"
$env:COMFYUI_BASE_URL = "http://127.0.0.1:8188"
$env:TOOL_SERVER_CONNECTIONS = '[{"url":"http://127.0.0.1:8200/workstation","path":"openapi.json","auth_type":"none","key":"","config":{"enable":true},"info":{"id":"workstation","name":"workstation"}},{"url":"http://127.0.0.1:8200/fetch","path":"openapi.json","auth_type":"none","key":"","config":{"enable":true},"info":{"id":"fetch","name":"fetch"}},{"url":"http://127.0.0.1:8200/filesystem","path":"openapi.json","auth_type":"none","key":"","config":{"enable":true},"info":{"id":"filesystem","name":"filesystem"}},{"url":"http://127.0.0.1:8200/desktop","path":"openapi.json","auth_type":"none","key":"","config":{"enable":true},"info":{"id":"desktop","name":"desktop"}},{"url":"http://127.0.0.1:8200/browser","path":"openapi.json","auth_type":"none","key":"","config":{"enable":true},"info":{"id":"browser","name":"browser"}}]'
Start-Bg "open-webui" 8080 "$Root\envs\open-webui\Scripts\open-webui.exe" "serve --host 127.0.0.1 --port 8080"

Write-Host "Waiting for Open WebUI..."
for ($i = 0; $i -lt 90; $i++) {
    if (Test-Port 8080) { break }; Start-Sleep 2
}
if (-not $NoBrowser) { & "$Root\open-app.ps1" -NoStart }
Write-Host "Ready."
Write-Host "  Chat:     http://localhost:8080"
Write-Host "  ComfyUI:  http://localhost:8188"
Write-Host "  Logs:     $Logs"
