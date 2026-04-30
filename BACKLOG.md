# Backlog

## llama-server (lemonade-sdk) usage patterns

`llama-server` is installed alongside Ollama. Ollama handles model management; llama-server
provides native gfx1150 GPU inference (no HSA override needed).

**Quick start:**
```bash
# Run a model directly (OpenAI-compatible API on :8080)
llama-server -m /data/ollama/models/blobs/<sha> -ngl 99 --port 8080

# Or point at a GGUF from the T9 archive
llama-server -m /media/rickard/T9/airgap/models/ollama/deepseek-r1-8b.gguf -ngl 99
```

`-ngl 99` offloads all layers to GPU. Drop to `-ngl 0` for CPU-only.

**When to use llama-server vs Ollama:**
- Ollama: interactive use, `ollama run`, model switching, embedding via API
- llama-server: single-model server, max GPU performance, OpenAI client compatibility

**TODO:** wire llama-server as a named systemd service with a configurable model path.

---

## vLLM / LightLLM airgap support

Add `download_vllm_wheels` function to `prepare_airgap.sh`.

**What's needed:**
- `pip download vllm` → `python/wheels/`
- SafeTensors model weights (not GGUF) for each model to serve
- Corresponding `install_on_t14s.sh` step to install wheels offline

**When to do this:**
- When moving to a machine with dedicated GPU VRAM
- When multi-user / concurrent inference is needed
- T14s Radeon 890M (iGPU, shared RAM) is not ideal — Ollama is better for now

**Models already on disk in SafeTensors format:**
- `defog/sqlcoder-7b-2` — 18 GB, ready to use with vLLM immediately
