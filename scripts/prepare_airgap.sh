#!/usr/bin/env bash
# ============================================================
# prepare_airgap.sh — Kör på ONLINE-maskin
# Laddar ner allt till T9-disken inför airgap-installation.
#
# Användning:
#   bash prepare_airgap.sh                   # kör allt
#   bash prepare_airgap.sh --dry-run         # visa vad som saknas, ladda inget
#   bash prepare_airgap.sh ollama            # bara Ollama + LLM-modeller
#   bash prepare_airgap.sh ollama --dry-run  # dry-run för Ollama-sektionen
#   bash prepare_airgap.sh hf               # bara HuggingFace-modeller
#   bash prepare_airgap.sh containers       # bara container-images
# ============================================================
set -euo pipefail

BASE=/media/rickard/T9/airgap
GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()     { echo -e "${GREEN}[✓]${NC} $1"; }
info()    { echo -e "${BLUE}[→]${NC} $1"; }
skip()    { echo -e "${YELLOW}[s]${NC} $1"; }
missing() { echo -e "${RED}[✗]${NC} $1"; }

# Detect --dry-run anywhere in args
DRY=0
ARGS=()
for arg in "$@"; do
    [[ "$arg" == "--dry-run" ]] && DRY=1 || ARGS+=("$arg")
done
[[ $DRY -eq 1 ]] && echo -e "${YELLOW}DRY RUN — ingenting laddas ner${NC}\n"

# ============================================================
# 1. Ollama — installera binären och spara till arkivet
# ============================================================
download_ollama() {
    info "Ollama-binärer"

    local dest="$BASE/archive/binaries"

    check_file() {
        local file=$1 url=$2
        if [[ -f "$dest/$file" ]]; then
            skip "  $file  (finns redan, $(du -sh "$dest/$file" | cut -f1))"
        else
            missing "  $file  SAKNAS"
            [[ $DRY -eq 0 ]] && { curl -L "$url" -o "$dest/$file"; log "  Sparad: $file"; }
        fi
    }

    check_file "ollama-linux-amd64.tar.zst"      "https://github.com/ollama/ollama/releases/latest/download/ollama-linux-amd64.tar.zst"
    check_file "ollama-linux-amd64-rocm.tar.zst" "https://github.com/ollama/ollama/releases/latest/download/ollama-linux-amd64-rocm.tar.zst"

    # Always reinstall from the freshly downloaded tarball and restart server
    if [[ $DRY -eq 0 ]]; then
        pkill ollama 2>/dev/null || true
        sleep 1
        tar --zstd -C /usr -xf "$dest/ollama-linux-amd64.tar.zst"
        log "  Ollama installerat: $(ollama --version 2>/dev/null | head -1)"
    else
        if command -v ollama &>/dev/null; then
            skip "  ollama installerat: $(ollama --version 2>/dev/null | head -1)"
        else
            missing "  ollama ej installerat lokalt"
        fi
    fi
}

# ============================================================
# 2. Starta Ollama-servern (om den inte redan kör)
# ============================================================
start_ollama() {
    [[ $DRY -eq 1 ]] && return
    if ollama list &>/dev/null; then
        skip "Ollama server redan igång"
        return
    fi
    info "Startar Ollama server..."
    ollama serve &>/dev/null &
    local tries=0
    until ollama list &>/dev/null; do
        sleep 2
        tries=$((tries + 1))
        [[ $tries -gt 15 ]] && { echo "Ollama startade inte"; exit 1; }
    done
    log "Ollama server igång"
}

# ============================================================
# 3. LLM-modeller via Ollama
# ============================================================
pull_llm_models() {
    info "LLM-modeller (Ollama)"

    check_model() {
        local model=$1 desc=$2
        if ollama list 2>/dev/null | grep -q "^${model}[: ]"; then
            skip "  $model  ($desc)"
        elif [[ $DRY -eq 1 ]]; then
            missing "  $model  ($desc)"
        else
            info "  Laddar $model  ($desc)..."
            ollama pull "$model"
            log "  $model klar"
        fi
    }

    echo "  --- Reasoning ---"
    check_model "deepseek-r1:8b"   "5 GB  — snabb reasoning"
    check_model "deepseek-r1:14b"  "9 GB  — tung reasoning"

    # text-analysis GPU-tiers (selectModelGPU i hardware/detector.go)
    # Väljs automatiskt baserat på VRAM/GTT — ladda alla tiers för portabilitet.
    echo "  --- text-analysis: GPU-modeller (llama-server / HIP) ---"
    check_model "llama3.1:70b"        "43 GB — GPU ≥ 40 GB  (t.ex. APU 53 GB GTT)"
    check_model "qwen2.5:32b"         "19 GB — GPU ≥ 22 GB"
    check_model "qwen2.5:14b"         "8.5 GB — GPU ≥ 10 GB"
    check_model "llama3.1:8b"         "4.7 GB — GPU ≥ 5 GB"
    check_model "mistral:7b-instruct" "4.1 GB — GPU < 5 GB / CPU-fallback"

    # Register a local GGUF as an Ollama model (skips registry)
    create_from_gguf() {
        local name=$1 gguf=$2 desc=$3
        if ollama list 2>/dev/null | grep -q "^${name}[: ]"; then
            skip "  $name  ($desc)"
        elif [[ ! -f "$gguf" ]]; then
            missing "  $name  GGUF saknas: $gguf"
        else
            info "  Skapar $name från lokal GGUF  ($desc)..."
            local mf
            mf=$(mktemp /tmp/Modelfile.XXXXXX)
            printf 'FROM %s\n' "$gguf" > "$mf"
            ollama create "$name" -f "$mf"
            rm -f "$mf"
            log "  $name klar"
        fi
    }

    echo "  --- General / SQL ---"
    check_model "mistral:7b"  "4.5 GB — general purpose"
    create_from_gguf "sqlcoder" \
        "$BASE/models/ollama/sqlcoder-7b-q5.gguf" \
        "4.5 GB — SQL-generering (lokal GGUF)"

    echo "  --- Små modeller (passar 16 GB RAM) ---"
    check_model "phi3:mini"        "2.3 GB — snabb chat"
    check_model "qwen2.5:3b"       "2.0 GB — svenska / flerspråkigt"
    check_model "nomic-embed-text" "0.3 GB — embeddings / RAG"

    if [[ $DRY -eq 0 ]]; then
        log "Alla LLM-modeller klara"
        ollama list
    fi
}

# ============================================================
# 4. HuggingFace-modeller
# ============================================================
download_hf_models() {
    info "HuggingFace-modeller"

    local models=(
        "KBLab/bert-base-swedish-cased:$BASE/huggingface/KBLab_bert-base-swedish-cased"
        "KBLab/sentence-bert-swedish-cased:$BASE/huggingface/KBLab_sentence-bert-swedish-cased"
        "defog/sqlcoder-7b-2:$BASE/huggingface/defog_sqlcoder-7b-2"
    )

    for entry in "${models[@]}"; do
        local repo="${entry%%:*}"
        local dest="${entry##*:}"
        if [[ -d "$dest" && -n "$(ls -A "$dest" 2>/dev/null)" ]]; then
            skip "  $repo  ($(du -sh "$dest" | cut -f1))"
        else
            missing "  $repo  SAKNAS → $dest"
        fi
    done

    if [[ $DRY -eq 0 ]]; then
        if ! python3 -c "import huggingface_hub" 2>/dev/null; then
            info "Installerar huggingface_hub..."
            pip install huggingface_hub --quiet
        fi
        python3 << PYEOF
from huggingface_hub import snapshot_download
import os

models = [
    ("KBLab/bert-base-swedish-cased",      "$BASE/huggingface/KBLab_bert-base-swedish-cased"),
    ("KBLab/sentence-bert-swedish-cased",  "$BASE/huggingface/KBLab_sentence-bert-swedish-cased"),
    ("defog/sqlcoder-7b-2",                "$BASE/huggingface/defog_sqlcoder-7b-2"),
]
ignore = ["*.msgpack", "*.h5", "flax_model*", "tf_model*"]

for repo, dest in models:
    if os.path.isdir(dest) and os.listdir(dest):
        print(f"  [s] {repo} finns redan")
        continue
    print(f"  [→] Laddar {repo}...")
    snapshot_download(
        repo_id=repo,
        local_dir=dest,
        ignore_patterns=ignore,
        local_dir_use_symlinks=False,
        resume_download=True,
    )
    print(f"  [✓] Klar: {dest}")
PYEOF
        log "HuggingFace-modeller klara"
    fi
}

# ============================================================
# 5. Container images med Podman
# ============================================================
pull_container_images() {
    info "Container-images (Podman)"

    local images=(
        "falkordb/falkordb:latest"
        "docker.io/openmetadata/openmetadata-server:latest"
        "docker.io/openmetadata/openmetadata-ingestion:latest"
        "docker.io/postgres:16-alpine"
        "docker.io/redis:7-alpine"
    )

    if [[ $DRY -eq 0 ]] && ! command -v podman &>/dev/null; then
        echo "  Podman ej installerat — hoppar över"
        return
    fi

    mkdir -p "$BASE/docker"

    for img in "${images[@]}"; do
        local safe tar
        safe=$(echo "$img" | tr '/:.' '___-')
        tar="$BASE/docker/${safe}.tar"
        if [[ -f "$tar" ]]; then
            skip "  $img  ($(du -sh "$tar" | cut -f1))"
        else
            missing "  $img  SAKNAS → $(basename "$tar")"
            if [[ $DRY -eq 0 ]]; then
                podman pull "$img"
                podman save "$img" -o "$tar"
                log "  Sparad: $(basename "$tar")"
            fi
        fi
    done

    if [[ $DRY -eq 0 ]]; then
        log "Container-images klara"
    fi
}

# ============================================================
# 6. llama.cpp ROCm — pre-built gfx1150 binary (lemonade-sdk)
#    Bundles ROCm 7 runtime — no separate ROCm install needed.
#    Native gfx1150 kernels — better than HSA_OVERRIDE workaround.
# ============================================================
download_llamacpp_rocm() {
    local dest="$BASE/archive/binaries"
    local api="https://api.github.com/repos/lemonade-sdk/llamacpp-rocm/releases/latest"

    info "llama.cpp ROCm gfx1150 (lemonade-sdk — bundles ROCm 7)"

    local existing
    existing=$(ls "$dest"/llama-*-ubuntu-rocm-gfx1150*.zip 2>/dev/null | head -1)
    if [[ -n "$existing" ]]; then
        skip "  $(basename "$existing")  ($(du -sh "$existing" | cut -f1))"
        return
    fi

    missing "  llama-*-ubuntu-rocm-gfx1150*.zip  SAKNAS"
    [[ $DRY -eq 1 ]] && return

    info "  Hämtar release-info från GitHub..."
    local asset_url
    asset_url=$(curl -s "$api" \
        | grep -o '"browser_download_url": "[^"]*ubuntu-rocm-gfx1150[^"]*\.zip"' \
        | grep -o 'https://[^"]*')

    if [[ -z "$asset_url" ]]; then
        echo "  Kunde inte hitta gfx1150 Ubuntu-asset i senaste release"; return 1
    fi

    local filename
    filename=$(basename "$asset_url")
    info "  Laddar ner: $filename (~440 MB)..."
    curl -L "$asset_url" -o "$dest/$filename"
    log "  Sparad: $filename  ($(du -sh "$dest/$filename" | cut -f1))"
}

# ============================================================
# 7. ROCm .deb packages — valfri, för andra GPU-konfigurationer
#    (T14s: använd download_llamacpp_rocm istället — enklare)
# ============================================================
download_rocm_debs() {
    local ROCM_VERSION="7.2.2"
    local dest="$BASE/archive/apt/rocm-${ROCM_VERSION}"
    local count

    info "ROCm ${ROCM_VERSION} .deb-paket (AMD GPU-stack)"

    count=$(ls "$dest"/*.deb 2>/dev/null | wc -l)
    if [[ $count -gt 0 ]]; then
        skip "  $count .deb-filer finns redan ($(du -sh "$dest" | cut -f1))"
        [[ $DRY -eq 1 ]] && return
        return
    fi

    missing "  ROCm .deb-filer SAKNAS → $dest"
    [[ $DRY -eq 1 ]] && return

    mkdir -p "$dest"

    info "  Lägger till AMD apt-repo tillfälligt..."
    local CODENAME
    CODENAME=$(lsb_release -cs)
    mkdir -p /etc/apt/keyrings
    wget -q https://repo.radeon.com/rocm/rocm.gpg.key -O /tmp/rocm.gpg.key
    gpg --dearmor < /tmp/rocm.gpg.key > /etc/apt/keyrings/rocm.gpg
    chmod 644 /etc/apt/keyrings/rocm.gpg
    rm /tmp/rocm.gpg.key

    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] \
https://repo.radeon.com/rocm/apt/${ROCM_VERSION} ${CODENAME} main" \
        > /etc/apt/sources.list.d/rocm-download.list
    echo -e 'Package: *\nPin: release o=repo.radeon.com\nPin-Priority: 600' \
        > /etc/apt/preferences.d/rocm-pin-600
    apt-get update -qq

    info "  Laddar ner ROCm-paket + beroenden (~3-5 GB)..."
    apt-get install --download-only -y --no-install-recommends \
        rocm-hip-sdk \
        rocm-opencl-runtime \
        rocm-smi-lib \
        rocminfo

    # Copy everything apt downloaded into our archive
    find /var/cache/apt/archives -maxdepth 1 -name "*.deb" | while read -r deb; do
        cp "$deb" "$dest/"
    done

    # Set up a local apt repo index so T14s can install with apt offline
    info "  Bygger lokal apt-index..."
    ( cd "$dest" && dpkg-scanpackages . 2>/dev/null | gzip > Packages.gz )

    count=$(ls "$dest"/*.deb | wc -l)
    log "  $count .deb-filer sparade → $dest"

    # Clean up temp repo
    rm -f /etc/apt/sources.list.d/rocm-download.list \
          /etc/apt/preferences.d/rocm-pin-600
    apt-get update -qq
}

# ============================================================
# Main
# ============================================================
TARGET="${ARGS[0]:-all}"

case "$TARGET" in
    ollama)
        download_ollama
        start_ollama
        pull_llm_models
        ;;
    hf)
        download_hf_models
        ;;
    containers)
        pull_container_images
        ;;
    llamacpp)
        download_llamacpp_rocm
        ;;
    rocm)
        download_rocm_debs
        ;;
    all)
        download_ollama
        start_ollama
        pull_llm_models
        download_hf_models
        pull_container_images
        download_llamacpp_rocm   # native gfx1150, replaces rocm debs for T14s
        ;;
    *)
        echo "Användning: $0 [all|ollama|hf|containers|llamacpp|rocm] [--dry-run]"
        exit 1
        ;;
esac

echo ""
[[ $DRY -eq 1 ]] && echo -e "${YELLOW}Dry run klar — kör utan --dry-run för att ladda ner${NC}" \
                 || log "Förberedelse klar — T9-disken är redo för airgap-installation"
