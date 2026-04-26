# Design — Airgap Stack

## What this is

A self-contained AI/data stack that installs fully offline on a ThinkPad T14s.
Everything is downloaded once on an internet-connected machine and stored on a T9 external drive.
The target machine never touches the internet.

---

## Two-phase workflow

```
Online machine                     T14s (offline)
──────────────────────────────     ──────────────────────────────
prepare_airgap.sh                  install_on_t14s.sh
  ├─ downloads Ollama binaries  →    ├─ installs from /airgap
  ├─ pulls LLM models           →    ├─ registers models in Ollama
  ├─ downloads HuggingFace      →    ├─ copies to /data/huggingface
  └─ saves container images     →    └─ loads into Podman
```

---

## Scripts

| Script | Machine | Run once or many times |
|---|---|---|
| `prepare_airgap.sh` | Online | Many times — skips what already exists |
| `install_on_t14s.sh` | T14s offline | Many times — mostly idempotent* |
| `verify_airgap.sh` | T14s offline | Anytime — read-only check |
| `build_iceberg.sh` | T14s offline | One-off — only if Iceberg JAR needed |

*Exception: `~/.bashrc` and `~/.cargo/config.toml` get duplicate lines on re-run.

---

## prepare_airgap.sh — functions

```
prepare_airgap.sh [target] [--dry-run]

targets: all (default) | ollama | hf | containers
```

| Function | What it does |
|---|---|
| `download_ollama` | Downloads CPU + ROCm tarballs to `archive/binaries/`, installs locally |
| `start_ollama` | Starts `ollama serve` in background, waits until ready |
| `pull_llm_models` | Pulls 7 models via `ollama pull`, skips existing |
| `download_hf_models` | Downloads 3 HuggingFace repos via `snapshot_download`, resumes partials |
| `pull_container_images` | Pulls 5 images via Podman, saves as `.tar`, skips existing |

`--dry-run` shows what exists `[s]` and what is missing `[✗]` without downloading anything.

---

## Models

| Model | Size | Made by | Use |
|---|---|---|---|
| deepseek-r1:14b | ~9 GB | DeepSeek AI · MIT | Heavy reasoning, math, logic |
| deepseek-r1:8b | ~5 GB | DeepSeek AI · MIT | Reasoning, fits 16 GB easily |
| mistral:7b | ~4.5 GB | Mistral AI · Apache 2.0 | General chat, summarisation |
| sqlcoder2 | ~4.5 GB | Defog AI · Apache 2.0 | Natural language → SQL |
| phi3:mini | ~2.3 GB | Microsoft · MIT | Fast chat, coding, low RAM |
| qwen2.5:3b | ~2.0 GB | Alibaba · Qwen License | Multilingual, Swedish |
| nomic-embed-text | ~0.3 GB | Nomic AI · Apache 2.0 | Embeddings for RAG/search |

All are open-weight — weights are public and free to run locally.

---

## Directory layout

```
/airgap/
├── archive/
│   ├── apt/          .deb packages for offline apt install
│   └── binaries/     Ollama tarballs, DuckDB, pqrs, ONNX runtime
├── docker/           Podman/Docker .tar images
├── git/              Source repos (Iceberg etc.)
├── huggingface/      HuggingFace model snapshots
├── models/
│   └── ollama/       GGUF files (raw model weights)
├── python/
│   ├── wheels/       Python .whl files for offline pip
│   └── requirements_offline.txt
├── rust/
│   ├── toolchain/    rustup-init + stdlib tarballs
│   └── vendor/       All Cargo crates pre-vendored
└── scripts/          This directory
```

---

## ROCm note

The T14s has a Radeon 890M (gfx1150, RDNA 3.5).
ROCm does not officially support gfx1150, so we override it to gfx1100 (RDNA 3.0):

```bash
export HSA_OVERRIDE_GFX_VERSION=11.0.0
```

This is set permanently in `~/.bashrc` by `install_on_t14s.sh` and in the Ollama systemd service.
