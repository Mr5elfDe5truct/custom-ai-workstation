# GPUs: one card, several cards, small cards

The Workstation was built on one RTX 3060 12 GB, but it runs on whatever NVIDIA cards a PC has. On every start,
`start-all.ps1` reads the cards with `nvidia-smi`, decides which card each service runs on, and prints the result:

```
  GPUs (split):
    [0] RTX 2060 6 GB: Ollama, Open WebUI
    [1] RTX 3060 12 GB: voice server, llama.cpp, ComfyUI
    Ollama context 16k; llama.cpp 12 GB presets
```

The plan is saved to `data\runtime\gpu.json`. Prestige reads it to show a meter for every card and to warn against
the right card, and the voice and tool servers read it so they only unload models that share their card.

## Modes

| Mode | What runs where | Good for |
|---|---|---|
| `single` | Everything on the biggest card. The only mode on a PC with one card. | one card; or a second card you want left alone |
| `split` | **Default with two or more cards.** Ollama (fast chat, vision, Live calls) and Open WebUI's embeddings on the second-biggest card; llama.cpp's big model and ComfyUI on the biggest. The voice server (Whisper + VoxCPM2, ~7 GB) joins the small card when it has 8 GB or more, otherwise it stays on the big one. | chatting while images or video render; Live calls beside a loaded big model |
| `pool` | Like `split`, but llama.cpp spreads its model over every card (llama.cpp's `--fit` picks the tensor split from each card's free memory). | models too big for one card |

Each service is pinned with `CUDA_VISIBLE_DEVICES` set to its cards' UUIDs, with `CUDA_DEVICE_ORDER=PCI_BUS_ID`. CUDA
numbers cards fastest-first and `nvidia-smi` by PCI slot, and on mixed cards the two orders differ; UUIDs avoid that.
Ollama also gets `OLLAMA_VULKAN=0`, because otherwise it finds the hidden card again through Vulkan and loads there, slowly.

Pick a mode for one start, or for good:

```powershell
.\start-all.ps1 -GpuMode pool     # this start only
.\install.ps1 -GpuMode split      # the installer asks when it finds several cards, and saves the answer
```

A service that's already running keeps its card, so run `.\stop-all.ps1` before switching modes.

## Small cards

What changes with the VRAM that's actually there:

- **Ollama's context:** 32k on 11 GB or more, 16k on 5.5–11 GB, 8k below that (from the smallest card Ollama runs
  on). Prestige asks for the same context.
- **llama.cpp:** `bin\llama-models.ini` is tuned by hand for one 12 GB card (how many expert layers sit in RAM, and so
  on). On a card outside 11–13.5 GB, or in a pool, `start-all.ps1` leaves those settings out of
  `data\runtime\llama-models.ini` and llama.cpp's `--fit` sizes the offload to the card. Under 10 GB the context is
  also capped at 16k so the VRAM goes to layers rather than cache.
- **The installer** picks Ollama models for the card Ollama will run on: the 9B fast chat and Gemma 4 12B from 10 GB,
  Qwen3-VL 8B for vision on 7.5–10 GB, and Qwen3.5 4B (which also sees pictures) under 7.5 GB. It also warns about
  packs that will run partly from RAM.

## Measured on an RTX 3060 12 GB + RTX 2060 6 GB

The 2060 sits in a PCIe x4 slot, which matters as soon as the cards have to talk to each other.

| Model | Where | Speed |
|---|---|---|
| Qwen3.5 2B (Ollama) | 2060, fully on the card | 80 tok/s |
| Qwen3.5 4B (Ollama) | 2060, fully on the card | 62 tok/s |
| Qwen3-VL 4B (Ollama, 16k) | 2060, 3.7 of 4.7 GB on the card | 33 tok/s |
| Qwen3.5 9B Uncensored (Ollama, 16k) | 2060, 3.6 of 6.5 GB on the card | 7 tok/s |
| Gemma 4 12B (Ollama) | 2060, mostly in RAM | 8 tok/s |
| Qwen3.5 9B Uncensored (Ollama) | 3060 | 48 tok/s |
| Qwen3.6 35B-A3B (llama.cpp, 12 GB presets) | 3060 | 23 tok/s in chat (30 tok/s in llama-bench) |
| Qwen3.6 35B-A3B (llama.cpp, pooled by `--fit`) | 3060 + 2060 | 18 tok/s |

So on this pair, `split` with the 4B models on the 2060 is the fast setup, and `pool` doesn't pay off for models that
already fit the 12 GB card: the MoE ends up waiting on the x4 link. Pool is for models that don't fit one card at all.
With a second card of 8 GB or more, the 9B and the voices fit on it too.

## data\gpu-settings.json

Optional. Every key can be left out ([example](gpu-settings.example.json)):

```json
{
  "mode": "split",
  "bigGpu": "3060",
  "smallGpu": "auto",
  "services": { "ollama": "big", "voice": "small" },
  "exclude": [],
  "ollamaContext": 16384,
  "llamaFit": "auto",
  "tensorSplit": "auto"
}
```

| Key | Values | Default |
|---|---|---|
| `mode` | `auto`, `single`, `split`, `pool` | `auto`: `split` with two or more cards, else `single` |
| `bigGpu`, `smallGpu` | a card's `nvidia-smi` index, its UUID, or part of its name (`"3060"`) | the biggest and the second-biggest card |
| `services` | per service (`ollama`, `openwebui`, `voice`, `llama`, `comfyui`): `"big"`, `"small"`, `"all"`, a card, or a list of cards | as the mode says |
| `exclude` | cards to leave alone, e.g. one kept for games or the display | none |
| `ollamaContext` | tokens | by the card's VRAM (above) |
| `llamaFit` | `auto`, `on`, `off` | `auto`: off on one 11–13.5 GB card, on everywhere else |
| `tensorSplit` | e.g. `"12,6"`, in the order of the llama.cpp cards (big card first) | `auto` (`--fit` decides). A hand-set split turns `--fit` off, so the ini's own offload settings apply |

For example, on a 12 + 6 GB pair, to keep the 9B fast chat and Gemma 4 12B on the big card and use the small one
only for llama.cpp's pool:

```json
{ "mode": "pool", "services": { "ollama": "big", "openwebui": "big" } }
```
