# Backlog

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
