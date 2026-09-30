<p align="center">
  <img src="docs/assets/banner.svg" alt="Custom AI Workstation" width="100%">
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-a78bfa?style=for-the-badge"></a>
  <img alt="Windows 11" src="https://img.shields.io/badge/Windows%2011-native-0078D4?style=for-the-badge&logo=windows11&logoColor=white">
  <img alt="RTX 3060 12 GB" src="https://img.shields.io/badge/GPU-RTX%203060%2012%20GB-76B900?style=for-the-badge&logo=nvidia&logoColor=white">
  <img alt="100% local" src="https://img.shields.io/badge/cloud-none-f472b6?style=for-the-badge">
  <br>
  <img alt="Open WebUI" src="https://img.shields.io/badge/Open%20WebUI-chat-1e1b4b?style=flat-square">
  <img alt="llama.cpp" src="https://img.shields.io/badge/llama.cpp-router-0f172a?style=flat-square">
  <img alt="Ollama" src="https://img.shields.io/badge/Ollama-models-0f172a?style=flat-square&logo=ollama">
  <img alt="ComfyUI" src="https://img.shields.io/badge/ComfyUI-images%20%2B%20video-0f172a?style=flat-square">
  <img alt="MCP" src="https://img.shields.io/badge/MCP-tools-0f172a?style=flat-square">
  <img alt="PowerShell" src="https://img.shields.io/badge/PowerShell-scripts-5391FE?style=flat-square&logo=powershell&logoColor=white">
  <img alt="Python" src="https://img.shields.io/badge/Python-3.12-3776AB?style=flat-square&logo=python&logoColor=white">
</p>

<p align="center">
  <b>One folder, one script, one 12 GB GPU.</b><br>
  A free, local, uncensored, agentic AI that chats, sees through your webcam, talks back, uses tools,
  drives your mouse and keyboard, and makes images and videos with sound.<br>
  Nothing leaves the machine except the web lookups the AI makes with its research tools.
</p>

---

## ✨ Showcase

Everything below was generated on the workstation itself (RTX 3060 12 GB, 32 GB RAM).

<table>
  <tr>
    <td align="center" width="50%">
      <img src="docs/assets/sample-ltx23-t2v.gif" alt="LTX-2.3 text-to-video sample" width="100%"><br>
      <b>Text → video with sound</b> · LTX-2.3 distilled<br>
      <sub>4 s, 768×512, ~6 min · <a href="docs/assets/sample-ltx23-t2v.mp4">▶ watch with audio (MP4)</a></sub>
    </td>
    <td align="center" width="50%">
      <img src="docs/assets/sample-wan22-i2v.gif" alt="Wan 2.2 image-to-video sample" width="100%"><br>
      <b>Image → video</b> · Wan 2.2 I2V, LightX2V 4-step<br>
      <sub>5 s, 832×480, ~10 min, animated from the still below</sub>
    </td>
  </tr>
  <tr>
    <td align="center">
      <img src="docs/assets/sample-fox.jpg" alt="Z-Image-Turbo sample: fox reading a book" width="100%"><br>
      <b>Image from the chat window</b> · Z-Image-Turbo<br>
      <sub>1024×1024, ~30–45 s, asked for in Open WebUI</sub>
    </td>
    <td align="center">
      <img src="docs/assets/sample-cabin.jpg" alt="Z-Image-Turbo sample: snowy cabin" width="100%"><br>
      <b>Text → image</b> · Z-Image-Turbo<br>
      <sub>the start frame for the Wan 2.2 clip above</sub>
    </td>
  </tr>
</table>

## 🧠 What it can do

| | Feature | How |
|---|---|---|
| 💬 | **Chat with uncensored models** | Qwen3.6 35B-A3B (MoE with experts in system RAM), Qwen3.5 9B, Gemma 4 |
| 👀 | **Webcam vision** | Open WebUI video call with Gemma 4, or the `webcam_snapshot` tool mid-chat |
| 🎙️ | **Voice in and out** | faster-whisper speech-to-text, Kokoro text-to-speech |
| 🧰 | **Tools** | web search, web fetch, files, PowerShell (guarded), Playwright browser control |
| 🔭 | **Research scout** | Reddit, Hugging Face trending GGUFs and GitHub search, plus a Markdown scout report |
| 🖱️ | **Computer use** | UI-TARS Desktop driven by a local UI-TARS-1.5-7B |
| 🖼️ | **Images** | Z-Image-Turbo through ComfyUI, from the image button or by asking |
| 🎬 | **Video** | LTX-2.3 text-to-video with audio, Wan 2.2 image-to-video, as background jobs |
| 🗂️ | **Shared long-term memory** | every model reads and writes the same memory; chats are saved |

## 🏗️ How it fits together

<p align="center"><img src="docs/assets/architecture.svg" alt="Architecture diagram" width="100%"></p>

| Port | Service | Notes |
|---|---|---|
| 8080 | Open WebUI | the app you use |
| 11434 | Ollama | Gemma 4, Qwen3.5 9B, coders; unloads after 5 min idle |
| 8081 | llama.cpp router | Qwen3.6 35B and UI-TARS, one at a time; unloads after 3 min idle (`bin/llama-models.ini`) |
| 8188 | ComfyUI (headless) | uses Comfy Desktop's install; frees the GPU after each job |
| 8880 | Kokoro | text-to-speech on CPU |
| 8200 | mcpo tool server | research, webcam, fetch, video jobs, files, shell, browser (`tools/mcpo-config.json`) |

The 12 GB GPU holds one big model at a time. Everything unloads when idle, so chat, images and video take turns.

## 🖥️ Hardware and models

**Reference PC:** NVIDIA RTX 3060 12 GB · AMD Ryzen 7 2700X · 32 GB RAM · Windows 11 · NVMe for chat models, HDD for video models.

| Role | Model | Runner | Size on disk | Speed on the 3060 |
|---|---|---|---|---|
| Main agent, uncensored, tools + vision | Qwen3.6-35B-A3B Heretic Q4_K_M (25 of 40 expert layers in RAM) | llama.cpp | ~21 GB | ~25–30 tok/s |
| Fast, fully on GPU, uncensored | Qwen3.5-9B Uncensored Q4_K_M | Ollama | 6.7 GB | fast |
| Vision / webcam | Gemma 4 (12B and e4b) | Ollama | 7–10 GB | good |
| Computer use | UI-TARS-1.5-7B Q5_K_M | llama.cpp | ~5.5 GB | on demand |
| Images | Z-Image-Turbo | ComfyUI | — | ~30–45 s at 1024² |
| Text → video + audio | LTX-2.3 22B distilled Q4_K_M | ComfyUI + GGUF | ~20 GB | ~6 min for 4 s |
| Image → video | Wan 2.2 I2V A14B LightX2V 4-step Q4_K_M | ComfyUI + GGUF | ~25 GB | ~10 min for 5 s |
| Speech | faster-whisper `base`, Kokoro 82M | Open WebUI, Kokoro-FastAPI | small | CPU |

## 🚀 Quick start

This repo holds the glue: launch scripts, configs, ComfyUI workflows, and the custom tool server. The apps and
model weights are installed separately (see [PLAN.md](PLAN.md) for the full build log and every source).

**1. Prerequisites** (all free): NVIDIA driver, [uv](https://github.com/astral-sh/uv), Python 3.12, Node.js, git,
ffmpeg, [Ollama](https://ollama.com), [Comfy Desktop](https://www.comfy.org/download) with the
[ComfyUI-GGUF](https://github.com/city96/ComfyUI-GGUF) node, and eSpeak NG for Kokoro.

**2. Clone and add the apps** into the same folder:

```powershell
git clone https://github.com/Mr5elfDe5truct/custom-ai-workstation "Custom AI"
cd "Custom AI"
uv venv envs\open-webui --python 3.12; uv pip install -p envs\open-webui open-webui
uv venv envs\tools --python 3.12;      uv pip install -p envs\tools mcpo mcp httpx opencv-python mcp-server-fetch
# llama.cpp Windows CUDA build  -> bin\llama.cpp\
# Kokoro-FastAPI (+ envs\kokoro) -> apps\Kokoro-FastAPI\
# UI-TARS Desktop                -> apps\ui-tars-desktop\
```

**3. Get the models:** GGUFs into `models\gguf\`, `ollama pull` the Ollama models, and the video models with
`bash scripts/download-video-models.sh` (resumable).

**4. Point the configs at your paths:** `bin/llama-models.ini`, `bin/comfy-extra-models.yaml` and
`tools/mcpo-config.json` use absolute Windows paths from the reference PC.

**5. Start it:**

```powershell
.\start-all.ps1          # starts everything and opens Open WebUI in its own app window
.\stop-all.ps1           # stops everything and closes the app window (leaves Comfy Desktop alone)
.\install-shortcut.ps1   # adds "Custom AI" and "Stop Custom AI" shortcuts (Custom AI starts services if needed)
.\start-computer-use.ps1 # opens UI-TARS Desktop so the AI can use your mouse and keyboard
```

If PowerShell blocks the script: `powershell -ExecutionPolicy Bypass -File .\start-all.ps1`.

**Desktop app:** Open WebUI opens in its own window with no tabs or address bar (Chrome, or Edge if Chrome isn't
installed), using a separate profile in `data\app-profile` so it gets its own taskbar entry.

- Run `.\install-shortcut.ps1` once to add a **Custom AI** shortcut to the Desktop and Start Menu. It starts the
  services if they aren't running, then opens the window.
- **Closing the window shuts everything down** (it runs `stop-all.ps1`). To keep the services up after closing,
  open it with `.\open-app.ps1 -KeepRunning`.
- The **Stop Custom AI** Start Menu shortcut stops everything without opening the window.
- Open WebUI is still at http://localhost:8080 in any browser.

**Themes:** Open WebUI gets a custom look, **Dragon Red & Gold** by default (black and crimson with gold highlights and a red glow).
Three more are built in: **Cyberpunk Neon**, **Glass** (frosted panels over a colored backdrop) and **Terminal HUD** (green on black).

<p align="center"><img src="docs/assets/theme-dragon-chat.jpg" alt="Dragon Red &amp; Gold theme" width="80%"></p>

- Switch with the palette button in the bottom-right corner, or press **Ctrl+Alt+T** to cycle. The choice is remembered.
- Pick the startup default with `.\start-all.ps1 -Theme dragon|neon|glass|hud|off` (`off` is Open WebUI's own look).
- Themes apply in Open WebUI's dark mode (Settings → General → Theme: Dark or System). OLED Dark overrides the colors.
- The theme lives in `theme/`. `start-all.ps1` copies it into Open WebUI's `custom.css` and `loader.js` on every start,
  so it survives `uv pip install -U open-webui`.

## 💡 Using it

- **Pick a model** at the top of the chat. Qwen3.6 35B is the best all-rounder; its first message after idling takes ~30–60 s to load.
- **Talk to it** with the mic and voice-mode buttons. Answers are spoken with Kokoro.
- **Webcam:** voice mode → camera icon starts a video call (use Gemma 4). Or ask "take a webcam photo and tell me what you see".
- **Images:** the image button under the message box, or just ask for one.
- **Video:** "make a video of …" (LTX-2.3) or "animate this image: C:\path\to.png" (Wan 2.2). It returns a job id; ask "is video &lt;id&gt; done?".
- **Research:** "what's new on r/LocalLLaMA this week", "find trending GGUF models under 10 GB", or "run a scout report".
- **Files and commands:** "list what's in my Downloads", "run `nvidia-smi`". The shell blocks disk, format, registry, shutdown and user-account commands, and the model asks before deleting, installing or changing settings.
- **Browser control:** enable the **browser** tool for a chat, then "open github.com/ggml-org/llama.cpp/releases and tell me the newest tag".
- **Memory:** say "remember that …". Every 4 messages the model also saves anything worth keeping. Manage it in Settings → Personalization → Memory.

### Computer use (UI-TARS)

Run `.\start-computer-use.ps1`. First time only, in UI-TARS settings set VLM Provider **Hugging Face for UI-TARS-1.5**,
Base URL **http://127.0.0.1:8081/v1**, API Key **none**, Model **ui-tars-1.5-7b**. Choose **Local Computer**, type a
task and watch it. The stop button ends it; it only runs while the app is open.

### Adding things later

- New Ollama model: `ollama pull <name>` (stored in `models\ollama`).
- New GGUF for llama.cpp: put it in `models\gguf` and add a section to `bin\llama-models.ini`.
- New ComfyUI workflow for chat: export "API" format from ComfyUI into `workflows\`.

## 📁 Repository layout

```
start-all.ps1 · stop-all.ps1 · start-computer-use.ps1   launch and stop everything
open-app.ps1 · install-shortcut.ps1                     Open WebUI app window and Desktop/Start Menu shortcut
bin/llama-models.ini         llama.cpp router presets (Qwen3.6, UI-TARS)
bin/comfy-extra-models.yaml  ComfyUI model folders
tools/scout_mcp.py           MCP server: Reddit/HF/GitHub scout, webcam snapshot, video jobs
tools/mcpo-config.json       MCP servers exposed to Open WebUI through mcpo
workflows/*.api.json         ComfyUI API workflows (Z-Image-Turbo, LTX-2.3, Wan 2.2)
scripts/                     video model downloader, ComfyUI workflow runner
theme/custom.css · loader.js  Open WebUI themes and the theme switcher
docs/assets/                 README art and samples
PLAN.md                      design notes, component choices and sources
```

Model weights, virtual envs, apps, chats, memory, logs and generated media stay on the PC and are git-ignored.

## 🙏 Credits

**Developed and written by Ryan B. Gyles.**

Built on the shoulders of these open projects: [Open WebUI](https://github.com/open-webui/open-webui),
[llama.cpp](https://github.com/ggml-org/llama.cpp), [Ollama](https://github.com/ollama/ollama),
[ComfyUI](https://github.com/comfyanonymous/ComfyUI) and [ComfyUI-GGUF](https://github.com/city96/ComfyUI-GGUF),
[mcpo](https://github.com/open-webui/mcpo), [Kokoro-FastAPI](https://github.com/remsky/Kokoro-FastAPI),
[faster-whisper](https://github.com/SYSTRAN/faster-whisper), [UI-TARS Desktop](https://github.com/bytedance/UI-TARS-desktop),
[Desktop Commander](https://github.com/wonderwhy-er/DesktopCommanderMCP), [Playwright MCP](https://github.com/microsoft/playwright-mcp)
and the [MCP servers](https://github.com/modelcontextprotocol/servers).
Models by Qwen, Google (Gemma), ByteDance (UI-TARS), Lightricks (LTX), Wan-AI, Tongyi (Z-Image), and the community
quantizers at unsloth, QuantStack, jayn7, mradermacher and Youssofal.

## 📜 License

[MIT](LICENSE) © 2026 Ryan B. Gyles. Third-party apps and model weights keep their own licenses.
