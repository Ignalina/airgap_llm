//! KB-BERT ONNX inference i Rust
//! Sätter HSA_OVERRIDE_GFX_VERSION=11.0.0 automatiskt för Radeon 890M.
//!
//! Bygga:  cargo build --release
//! Köra:   ORT_DYLIB_PATH=/usr/local/lib/libonnxruntime.so \
//!           ./target/release/kb-bert-onnx "Medborgare i Stockholm"

use anyhow::{Context, Result};
use ndarray::{Array2, Array3, Axis};
use ort::{Environment, ExecutionProvider, GraphOptimizationLevel, Session, SessionBuilder};
use tokenizers::Tokenizer;

const ONNX_MODEL: &str = "/data/huggingface/onnx/sentence-bert-swedish-cased/model.onnx";
const TOKENIZER:  &str = "/data/huggingface/onnx/sentence-bert-swedish-cased/tokenizer.json";
const MAX_LEN:    usize = 512;

fn main() -> Result<()> {
    // Radeon 890M: override GFX version för ROCm-kompatibilitet
    std::env::set_var("HSA_OVERRIDE_GFX_VERSION", "11.0.0");

    let text = std::env::args().nth(1)
        .unwrap_or_else(|| "Hej världen".to_string());

    // Tokenisera
    let tokenizer = Tokenizer::from_file(TOKENIZER)
        .context("Kunde inte ladda tokenizer")?;
    let encoding = tokenizer.encode(text.as_str(), true)
        .map_err(|e| anyhow::anyhow!("{}", e))?;

    let ids:  Vec<i64> = encoding.get_ids().iter().map(|&x| x as i64).collect();
    let mask: Vec<i64> = encoding.get_attention_mask().iter().map(|&x| x as i64).collect();
    let len = ids.len().min(MAX_LEN);

    let input_ids  = Array2::from_shape_vec((1, len), ids[..len].to_vec())?;
    let attn_mask  = Array2::from_shape_vec((1, len), mask[..len].to_vec())?;
    let token_type = Array2::<i64>::zeros((1, len));

    // ONNX Runtime session (ROCm om tillgängligt, annars CPU)
    let env = Environment::builder()
        .with_name("kb-bert")
        .build()?
        .into_arc();

    let session = SessionBuilder::new(&env)?
        .with_optimization_level(GraphOptimizationLevel::Level3)?
        .with_execution_providers([
            ExecutionProvider::ROCm(Default::default()),  // Radeon 890M
            ExecutionProvider::CPU(Default::default()),   // fallback
        ])?
        .commit_from_file(ONNX_MODEL)?;

    // Inference
    let outputs = session.run(ort::inputs![
        "input_ids"      => input_ids.view(),
        "attention_mask" => attn_mask.view(),
        "token_type_ids" => token_type.view(),
    ]?)?;

    // Mean pooling över token-dimensionen → sentence embedding
    let hidden: Array3<f32> = outputs["last_hidden_state"]
        .try_extract_tensor()?
        .into_dimensionality()?;
    let embedding = hidden.mean_axis(Axis(1)).unwrap();

    // L2-normalisering
    let norm = embedding.mapv(|x| x * x).sum().sqrt();
    let normalized = embedding.mapv(|x| x / norm);

    println!("Text:      {}", text);
    println!("Dim:       {}", normalized.len());
    println!("Embedding: [{:.4}, {:.4}, {:.4}, ...]",
        normalized[[0, 0]], normalized[[0, 1]], normalized[[0, 2]]);

    Ok(())
}
