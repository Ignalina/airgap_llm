#!/bin/bash
# Verifiera att allt fungerar OFFLINE på T14s
echo "=== AIRGAP VERIFIERING ==="

PASS=0; FAIL=0

check() {
    local name=$1
    local cmd=$2
    if eval "$cmd" &>/dev/null; then
        echo "  ✓ $name"
        ((PASS++))
    else
        echo "  ✗ $name — SAKNAS"
        ((FAIL++))
    fi
}

echo "--- Rust stack ---"
check "rustc"           "rustc --version"
check "cargo"           "cargo --version"
check "arrow crate"     "grep -r 'arrow' $BASE/rust/ | head -1"

echo "--- Python stack ---"
check "python3"         "python3 --version"
check "pyarrow"         "python3 -c 'import pyarrow'"
check "lancedb"         "python3 -c 'import lancedb'"
check "sentence-transformers" "python3 -c 'from sentence_transformers import SentenceTransformer'"
check "sdv"             "python3 -c 'import sdv'"
check "faker"           "python3 -c 'from faker import Faker'"
check "ollama"          "python3 -c 'import ollama'"
check "duckdb"          "python3 -c 'import duckdb'"

echo "--- LLM ---"
check "ollama binary"   "ollama --version"
check "deepseek-r1:8b"  "ollama list | grep deepseek-r1"
check "mistral"         "ollama list | grep mistral"

echo "--- Databaser ---"
check "duckdb CLI"      "duckdb --version"
check "FalkorDB"        "podman ps | grep falkor || podman images | grep falkor"

echo "--- HuggingFace ---"
check "KB-BERT"         "ls /data/huggingface/KBLab_bert-base-swedish-cased/config.json"

echo ""
echo "=== RESULTAT: $PASS OK, $FAIL SAKNAS ==="
