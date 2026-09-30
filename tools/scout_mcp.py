"""Workstation MCP server: research scouting (Reddit, Hugging Face, GitHub), webcam snapshots, video jobs.

Run through mcpo (see tools/mcpo-config.json); each function becomes a tool in Open WebUI.
"""
import base64
import datetime as dt
from pathlib import Path

import httpx
from mcp.server.fastmcp import FastMCP

ROOT = Path(__file__).resolve().parent.parent
REPORTS = ROOT / "reports"
SNAPSHOTS = ROOT / "data" / "webcam"
UA = {"User-Agent": "custom-ai-workstation-scout/1.0"}

mcp = FastMCP("workstation")


def _get(url: str, params: dict | None = None):
    r = httpx.get(url, params=params, headers=UA, timeout=30, follow_redirects=True)
    r.raise_for_status()
    return r.json()


def _reddit_rss(url: str, params: dict) -> str:
    # Reddit blocks anonymous .json requests, but the Atom feeds stay open.
    import xml.etree.ElementTree as ET

    import time

    for attempt in range(4):  # Reddit rate-limits bursts with 429
        r = httpx.get(url, params=params, headers=UA, timeout=30, follow_redirects=True)
        if r.status_code != 429:
            break
        time.sleep(10 * (attempt + 1))
    r.raise_for_status()
    ns ={"a": "http://www.w3.org/2005/Atom"}
    entries = ET.fromstring(r.content).findall("a:entry", ns)
    return "\n".join(f"- {e.findtext('a:title', '', ns)} {e.find('a:link', ns).get('href')}" for e in entries)


@mcp.tool()
def reddit_top(subreddit: str = "LocalLLaMA", period: str = "week", limit: int = 15) -> str:
    """Top posts from a subreddit. period: day, week, month, year, all."""
    return _reddit_rss(f"https://www.reddit.com/r/{subreddit}/top/.rss", {"t": period, "limit": limit})


@mcp.tool()
def reddit_search(query: str, subreddit: str = "LocalLLaMA", limit: int = 15) -> str:
    """Search a subreddit for posts from the past year."""
    return _reddit_rss(f"https://www.reddit.com/r/{subreddit}/search.rss",
                       {"q": query, "restrict_sr": 1, "sort": "relevance", "t": "year", "limit": limit})


@mcp.tool()
def hf_models(search: str = "", sort: str = "trendingScore", limit: int = 20, gguf_only: bool = True) -> str:
    """Hugging Face models. sort: trendingScore, downloads, likes, lastModified."""
    params = {"sort": sort, "direction": -1, "limit": limit}
    if search:
        params["search"] = search
    if gguf_only:
        params["filter"] = "gguf"
    data = _get("https://huggingface.co/api/models", params)
    return "\n".join(f"- {m['id']} (likes {m.get('likes', 0)}, downloads {m.get('downloads', 0)}) "
                     f"https://huggingface.co/{m['id']}" for m in data)


@mcp.tool()
def github_search(query: str, days: int = 30, limit: int = 15) -> str:
    """GitHub repos matching query, created or pushed in the last N days, sorted by stars."""
    since = (dt.date.today() - dt.timedelta(days=days)).isoformat()
    data = _get("https://api.github.com/search/repositories",
                {"q": f"{query} pushed:>{since}", "sort": "stars", "order": "desc", "per_page": limit})
    return "\n".join(f"- {r['full_name']} ★{r['stargazers_count']}: {r.get('description') or ''} {r['html_url']}"
                     for r in data["items"])


@mcp.tool()
def scout_report() -> str:
    """Build a dated report of new local-AI models and projects and save it under reports/."""
    sections = [
        ("r/LocalLLaMA this week", lambda: reddit_top("LocalLLaMA")),
        ("r/StableDiffusion this week", lambda: reddit_top("StableDiffusion")),
        ("r/comfyui this week", lambda: reddit_top("comfyui")),
        ("Trending GGUF models on Hugging Face", lambda: hf_models()),
        ("Trending diffusion models on Hugging Face", lambda: hf_models("video", gguf_only=False)),
        ("GitHub: local LLM agents", lambda: github_search("local llm agent")),
        ("GitHub: ComfyUI", lambda: github_search("comfyui")),
    ]
    out = [f"# Scout report {dt.date.today()}\n"]
    for title, fn in sections:
        try:
            body = fn()
        except Exception as e:  # keep the report going if one source fails
            body = f"(failed: {e})"
        out.append(f"## {title}\n{body}\n")
    text = "\n".join(out)
    REPORTS.mkdir(exist_ok=True)
    path = REPORTS / f"scout-{dt.date.today()}.md"
    path.write_text(text, encoding="utf-8")
    return f"Saved to {path}\n\n{text}"


@mcp.tool()
def webcam_snapshot(camera_index: int = 0) -> str:
    """Take one photo from the webcam. Returns the saved file path and a base64 JPEG."""
    import subprocess
    import sys

    SNAPSHOTS.mkdir(parents=True, exist_ok=True)
    path = SNAPSHOTS / f"snap-{dt.datetime.now():%Y%m%d-%H%M%S}.jpg"
    # DirectShow hangs when opened from the MCP server's worker thread, so capture in a fresh process.
    code = (
        "import cv2,sys\n"
        f"cap=cv2.VideoCapture({int(camera_index)},cv2.CAP_DSHOW)\n"
        "ok=False\n"
        "for _ in range(5): ok,f=cap.read()\n"
        "cap.release()\n"
        "sys.exit(0 if ok and cv2.imwrite(sys.argv[1],cv2.resize(f,(1280,720))) else 1)\n"
    )
    try:
        r = subprocess.run([sys.executable, "-c", code, str(path)], timeout=30, capture_output=True,
                           stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return "The webcam did not respond within 30 seconds."
    if r.returncode != 0:
        return "Could not read from the webcam."
    return f"Saved {path}\ndata:image/jpeg;base64,{base64.b64encode(path.read_bytes()).decode()}"


COMFY = "http://127.0.0.1:8188"
WORKFLOWS = ROOT / "workflows"


@mcp.tool()
def make_video(prompt: str, image_path: str = "") -> str:
    """Queue a video in ComfyUI. With image_path: animates that image (Wan 2.2, ~10 min, 5 s, no sound).
    Without: text-to-video with sound (LTX-2.3, ~6 min, 4 s). Returns a job id for video_status."""
    import json

    if image_path:
        wf = json.loads((WORKFLOWS / "wan22-i2v-4step.api.json").read_text())
        wf["6"]["inputs"]["text"] = prompt
        p = Path(image_path)
        up = httpx.post(f"{COMFY}/upload/image", files={"image": (p.name, p.read_bytes())}, timeout=60)
        up.raise_for_status()
        wf["9"]["inputs"]["image"] = up.json()["name"]
    else:
        wf = json.loads((WORKFLOWS / "ltx23-t2v-distilled.api.json").read_text())
        wf["5"]["inputs"]["text"] = prompt
    for node in wf.values():  # new seed each time
        for key in ("seed", "noise_seed"):
            if key in node["inputs"]:
                node["inputs"][key] = int(dt.datetime.now().timestamp())
    r = httpx.post(f"{COMFY}/prompt", json={"prompt": wf}, timeout=30)
    r.raise_for_status()
    return f"Queued video job {r.json()['prompt_id']}. It will be saved in {ROOT / 'data' / 'comfy-output' / 'video'}."


@mcp.tool()
def video_status(job_id: str) -> str:
    """Check a make_video job. Returns the output file path when finished."""
    h = httpx.get(f"{COMFY}/history/{job_id}", timeout=30).json()
    if job_id not in h:
        q = httpx.get(f"{COMFY}/queue", timeout=30).json()
        running = any(job_id == item[1] for item in q.get("queue_running", []))
        return "Rendering now." if running else "Waiting in the queue."
    job = h[job_id]
    if job["status"].get("status_str") != "success":
        return f"Failed: {job['status'].get('messages', [])[-1:]}"
    files = [f"{ROOT / 'data' / 'comfy-output' / o['subfolder'] / o['filename']}"
             for out in job["outputs"].values() for o in out.get("images", [])]
    return "Done: " + ", ".join(files)


if __name__ == "__main__":
    mcp.run()
