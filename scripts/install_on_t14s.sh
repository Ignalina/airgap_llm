#!/usr/bin/env bash
# ============================================================
# KÖR DETTA PÅ T14s (OFFLINE)
# Installerar hela stacken från /airgap
# ============================================================
set -euo pipefail

BASE=/media/rickard/T9/airgap
GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${BLUE}[→]${NC} $1"; }

# 1. APT-paket
info "Installerar APT-paket..."
sudo dpkg -i $BASE/archive/apt/*.deb 2>/dev/null || true
sudo apt-get install -f -y 2>/dev/null || true
log "APT klar"

# 2. Rust
info "Installerar Rust..."
chmod +x $BASE/archive/toolchain/rustup-init
RUSTUP_HOME=/usr/local/rustup \
CARGO_HOME=/usr/local/cargo \
$BASE/archive/toolchain/rustup-init \
    --no-modify-path \
    --default-toolchain stable \
    -y
echo 'export PATH="/usr/local/cargo/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc || true
log "Rust installerat: $(rustc --version 2>/dev/null || echo 'starta ny terminal')"

# 3. Cargo vendor config
info "Konfigurerar Cargo offline..."
mkdir -p ~/.cargo
cat >> ~/.cargo/config.toml << 'EOF'
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "/media/rickard/T9/airgap/rust/vendor"
EOF
log "Cargo offline konfigurerat"

# 4. Python wheels
info "Installerar Python-paket (offline)..."
pip install \
    --no-index \
    --find-links $BASE/python/wheels \
    -r $BASE/python/requirements_offline.txt \
    --break-system-packages 2>/dev/null || \
pip install \
    --no-index \
    --find-links $BASE/python/wheels \
    -r $BASE/python/requirements_offline.txt
log "Python-paket installerade"

# 5. llama-server — native gfx1150 (lemonade-sdk, bundles ROCm 7)
LLAMA_ZIP=$(ls $BASE/archive/binaries/llama-*-ubuntu-rocm-gfx1150*.zip 2>/dev/null | head -1)
if [[ -n "$LLAMA_ZIP" ]]; then
    info "Installerar llama-server (native gfx1150, ROCm 7 inbyggt)..."
    mkdir -p /opt/llamacpp-rocm
    unzip -o "$LLAMA_ZIP" -d /opt/llamacpp-rocm/
    chmod +x /opt/llamacpp-rocm/llama-server
    ln -sf /opt/llamacpp-rocm/llama-server /usr/local/bin/llama-server
    echo 'export PATH="/opt/llamacpp-rocm:$PATH"' >> ~/.bashrc
    log "llama-server: $(llama-server --version 2>/dev/null | head -1 || echo 'klar')"
else
    info "llama-server zip saknas — kör: prepare_airgap.sh llamacpp"
fi

# 5b. ROCm .deb (valfri — för annan GPU-hw eller torch/candle med ROCm)
ROCM_DEBS=$(ls -d $BASE/archive/apt/rocm-* 2>/dev/null | head -1)
if [[ -n "$ROCM_DEBS" && -f "$ROCM_DEBS/Packages.gz" ]]; then
    info "Installerar ROCm från lokal apt-repo ($ROCM_DEBS)..."
    echo "deb [trusted=yes] file://${ROCM_DEBS} ./" \
        > /etc/apt/sources.list.d/local-rocm.list
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        rocm-hip-sdk rocm-opencl-runtime rocm-smi-lib rocminfo
    rm /etc/apt/sources.list.d/local-rocm.list
    apt-get update -qq
    log "ROCm installerat"
else
    info "ROCm .deb-paket saknas — hoppar över (valfri för T14s, llama-server behöver det ej)"
fi

# 6. Ollama
info "Installerar Ollama..."
sudo tar --zstd -C /usr -xf $BASE/archive/binaries/ollama-linux-amd64.tar.zst
sudo tar --zstd -C /usr -xf $BASE/archive/binaries/ollama-linux-amd64-rocm.tar.zst 2>/dev/null || true

# Systemd service
sudo tee /etc/systemd/system/ollama.service > /dev/null << 'EOF'
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=/usr/bin/ollama serve
User=ollama
Group=ollama
Restart=always
Environment="HSA_OVERRIDE_GFX_VERSION=11.0.0"
Environment="OLLAMA_MODELS=/data/ollama/models"

[Install]
WantedBy=multi-user.target
EOF
sudo useradd -r -s /bin/false -m -d /usr/share/ollama ollama 2>/dev/null || true
sudo systemctl daemon-reload
sudo systemctl enable ollama
sudo systemctl start ollama
log "Ollama installerat och startat"

# 6. Ladda GGUF-modeller till Ollama
info "Laddar LLM-modeller till Ollama..."
sleep 3  # Vänta på Ollama startup

# Skapa Modelfile för varje GGUF
for gguf in $BASE/models/ollama/*.gguf; do
    model_name=$(basename $gguf .gguf)
    cat > /tmp/${model_name}.Modelfile << EOF
FROM $gguf
EOF
    ollama create $model_name -f /tmp/${model_name}.Modelfile
    log "Laddad: $model_name"
done

# 7. Container images
if command -v podman &>/dev/null; then
    info "Laddar container-images med Podman..."
    for tar in $BASE/docker/*.tar; do
        podman load -i "$tar"
        log "Podman: $(basename $tar)"
    done
else
    echo "  Podman ej installerat — hoppar över container-images"
fi

# 8. DuckDB
info "Installerar DuckDB CLI..."
unzip -o $BASE/archive/binaries/duckdb_cli.zip -d /usr/local/bin/
chmod +x /usr/local/bin/duckdb
log "DuckDB: $(duckdb --version)"

# 9. pqrs
info "Installerar pqrs..."
tar -xzf $BASE/archive/binaries/pqrs-linux.tar.gz -C /tmp/
cp /tmp/pqrs /usr/local/bin/ 2>/dev/null || true
chmod +x /usr/local/bin/pqrs 2>/dev/null || true

# 10. HuggingFace modeller -> lokal katalog
info "Sätter upp HuggingFace offline..."
mkdir -p /data/huggingface
cp -r $BASE/huggingface/* /data/huggingface/ 2>/dev/null || true

# Konfigurera HF offline-läge
echo 'export TRANSFORMERS_OFFLINE=1' >> ~/.bashrc
echo 'export HF_DATASETS_OFFLINE=1' >> ~/.bashrc
echo 'export HF_HOME=/data/huggingface' >> ~/.bashrc

# HSA_OVERRIDE_GFX_VERSION sätts INTE globalt — llama-server (lemonade) har native gfx1150
# och skulle prestera sämre med overriden. Overriden sätts bara i Ollamas systemd-service.
# Om torch/candle/burn behöver ROCm på gfx1150, sätt overriden manuellt per process.
echo 'export ROCR_VISIBLE_DEVICES=0' >> ~/.bashrc

# 11. Verifiera
echo ""
echo "════════════════════════════════════════"
echo "  VERIFIERING"
echo "════════════════════════════════════════"
echo -n "Rust:    "; rustc --version 2>/dev/null || echo "SAKNAS — starta ny terminal"
echo -n "Cargo:   "; cargo --version 2>/dev/null || echo "SAKNAS"
echo -n "Python:  "; python3 --version
echo -n "Ollama:       "; ollama --version 2>/dev/null || echo "SAKNAS"
echo -n "llama-server: "; llama-server --version 2>/dev/null | head -1 || echo "SAKNAS"
echo -n "DuckDB:       "; duckdb --version 2>/dev/null || echo "SAKNAS"
echo -n "Podman:  "; podman --version 2>/dev/null || echo "EJ INSTALLERAT"
echo ""
echo "Ollama-modeller:"
ollama list 2>/dev/null || echo "  (starta Ollama först)"
echo ""
echo "════════════════════════════════════════"
echo "  KLAR! Starta ny terminal och testa:"
echo "  ollama run deepseek-r1:14b"
echo "  cargo build --release"
echo "════════════════════════════════════════"
