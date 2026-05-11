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
BASE=/var/run/media/rickard/T9/airgap
#BASE=/media/rickard/T9/airgap
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


download_python_wheels() {
    info "Python wheels (offline cache)"

    mkdir -p $BASE/python/wheels

    pip download \
        --dest $BASE/python/wheels \
        -r $BASE/python/requirements_offline.txt
}

# ============================================================
# 1. Ollama — installera binären och spara till arkivet
# ============================================================
download_ollama() {
    info "Ollama (airgap install)"

    local dest="$BASE/archive/binaries"
    local tmp_cpu="/tmp/ollama/cpu"
    local cpu_tar="ollama-linux-amd64.tar.zst"
    local rocm_tar="ollama-linux-amd64-rocm.tar.zst"

    mkdir -p "$dest"
    mkdir -p "$tmp_cpu"

    check_file() {
        local file=$1 url=$2

        if [[ -f "$dest/$file" ]]; then
            skip "  $file (cached)"
        else
            missing "  $file"
            [[ $DRY -eq 0 ]] && curl -L "$url" -o "$dest/$file"
        fi
    }

    # ============================================================
    # 1. Ladda båda (airgap cache)
    # ============================================================
    check_file "$cpu_tar"  "https://github.com/ollama/ollama/releases/latest/download/$cpu_tar"
    check_file "$rocm_tar" "https://github.com/ollama/ollama/releases/latest/download/$rocm_tar"

    [[ $DRY -ne 0 ]] && return

    # ============================================================
    # 2. CPU runtime ONLY (unpack)
    # ============================================================
    rm -rf "$tmp_cpu"
    mkdir -p "$tmp_cpu"

    info "Packar upp CPU runtime..."
    tar --zstd -xf "$dest/$cpu_tar" -C "$tmp_cpu"

    chmod +x "$tmp_cpu/bin/ollama"

    # ============================================================
    # 3. ROCm = ONLY AIRGAP STORE (NO UNPACK)
    # ============================================================
    cp "$dest/$rocm_tar" "$BASE/archive"

    # ============================================================
    # 4. USER BIN SYMLINK
    # ============================================================
    ln -sf "$tmp_cpu/bin/ollama" "$HOME/.local/bin/ollama"


    log "Ollama aktiv: $HOME/.local/bin/ollama"
    "$HOME/.local/bin/ollama" --version 2>/dev/null || true
}
# ============================================================
# 3. LLM-modeller via Ollama
# ============================================================
pull_llm_models() {
    info "LLM-modeller (Ollama -> T9 AIRGAP)"

    export OLLAMA_MODELS="$BASE/models/ollama"
    nohup env OLLAMA_MODELS="$OLLAMA_MODELS" ollama serve >/tmp/ollama.log 2>&1 &

    gguf_path() {
        case "$1" in
            deepseek-r1:8b)        echo "$BASE/models/ollama/deepseek-r1-8b-q4.gguf" ;;
            deepseek-r1:14b)       echo "$BASE/models/ollama/deepseek-r1-14b-q4.gguf" ;;
            mistral:7b)            echo "$BASE/models/ollama/mistral-7b-q4.gguf" ;;
            sqlcoder:7b)           echo "$BASE/models/ollama/sqlcoder-7b-q5.gguf" ;;
            *)                     echo "" ;;
        esac
    }

    ensure_model() {
        local model=$1 desc=$2
        local gguf
        gguf=$(gguf_path "$model")

        # already installed
        if ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$model"; then
            skip "  $model ($desc)"
            return
        fi

        # GGUF path (offline T9 source)
        if [[ -f "$gguf" ]]; then
            info "  creating $model from GGUF ($desc)"

            cat > "/tmp/${model}.Modelfile" <<EOF
FROM $gguf
EOF

            ollama create "$model" -f "/tmp/${model}.Modelfile"
            return
        fi

        # online fallback
        info "  pulling $model ($desc)"
        ollama pull "$model"
    }
echo "--- Reasoning ---"
ensure_model "deepseek-r1:8b"  "snabb reasoning"
ensure_model "deepseek-r1:14b" "tung reasoning"

echo "--- GPU tiers ---"
ensure_model "qwen3-coder:30b"     "qwen3-coder"       # 24GB GPU sweet spot, ~17GB at Q4
# ensure_model "qwen3-coder-next"  "qwen3-coder-next"  # multi-GPU / CPU+RAM offload only (80B total)
ensure_model "qwen2.5:14b"         "medium"

echo "--- General ---"
ensure_model "llama3.1:8b"         "liten"
ensure_model "mistral:7b-instruct" "fallback"
ensure_model "mistral:7b"          "general"
ensure_model "phi3:mini"           "snabb chat"
ensure_model "nomic-embed-text"    "embeddings"

    log "OLLAMA DONE -> $BASE/models/ollama"
}
# ============================================================
# 4. HuggingFace-modeller
# ============================================================
download_hf_models() {
    info "HF-modeller -> T9 AIRGAP"

    export HF_HOME="$BASE/huggingface"
    pip install huggingface_hub[cli]

    download_repo() {
        local repo=$1 dir=$2

        if [[ -d "$dir" && -n "$(ls -A "$dir" 2>/dev/null)" ]]; then
            skip "  $repo (exists)"
            return
        fi

        info "  laddar $repo"

        mkdir -p "$dir"

        # RESUME via huggingface cache (ingen overwrite-logik)
        huggingface-cli download "$repo" \
            --local-dir "$dir" \
            --resume-download
    }

    download_repo "KBLab/bert-base-swedish-cased" "$BASE/huggingface/KBLab_bert-base-swedish-cased"
    download_repo "KBLab/sentence-bert-swedish-cased" "$BASE/huggingface/KBLab_sentence-bert-swedish-cased"
    download_repo "defog/sqlcoder-7b-2" "$BASE/huggingface/defog_sqlcoder-7b-2"

    log "HF DONE -> $BASE/huggingface"
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
    local repo_root; repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    info "llama.cpp ROCm gfx1150 (lemonade-sdk — bundles ROCm 7)"

    local existing
    existing=$(ls "$dest"/llama-*-ubuntu-rocm-gfx1150*.zip 2>/dev/null | head -1)
    if [[ -n "$existing" ]]; then
        skip "  $(basename "$existing")  ($(du -sh "$existing" | cut -f1))"
        return
    fi

    missing "  llama-*-ubuntu-rocm-gfx1150*.zip  SAKNAS"
    [[ $DRY -eq 1 ]] && return

    go run "$repo_root/cmd/llamacpp-download" --dest "$dest"
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
    wheels)
        download_python_wheels
        ;;
    ollama)
        download_ollama
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
        download_python_wheels
        download_ollama
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
