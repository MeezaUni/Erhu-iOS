"""Export the Apache-2.0 all-MiniLM-L6-v2 encoder to an iOS 17 Core ML package.

Run in the pinned environment from docs/VYBE.md. Inputs are local, verified ONNX,
config.json and vocab.txt files; no model download or Python runtime ships in the app.
"""
import argparse
import hashlib
import json
from pathlib import Path

import coremltools as ct
import numpy as np
import onnx
import onnxruntime as ort
import torch
from onnx import numpy_helper
from transformers import BertConfig, BertModel, BertTokenizerFast


class SentenceModel(torch.nn.Module):
    def __init__(self, bert):
        super().__init__()
        self.bert = bert

    def forward(self, input_ids, attention_mask):
        hidden = self.bert.embeddings(input_ids=input_ids, token_type_ids=torch.zeros_like(input_ids))
        # The float32 minimum overflows to -inf in Core ML FP16, making 0 * -inf NaN
        # for real tokens. This finite bias is equivalent for softmax and FP16-safe.
        bias = (1 - attention_mask[:, None, None, :].to(hidden.dtype)) * -10000.0
        hidden = self.bert.encoder(hidden, attention_mask=bias, return_dict=False)[0]
        mask = attention_mask.unsqueeze(-1).to(hidden.dtype)
        pooled = (hidden * mask).sum(1) / mask.sum(1).clamp(min=1, max=128)
        norm = pooled.square().sum(dim=1, keepdim=True).sqrt().clamp(min=1e-6, max=65504)
        return pooled / norm


def load_bert(folder):
    graph = onnx.load(str(folder / "model.onnx")).graph
    weights = {item.name: numpy_helper.to_array(item).copy() for item in graph.initializer}
    state = {name.removeprefix("model.0.auto_model."): torch.from_numpy(value)
             for name, value in weights.items() if name.startswith("model.0.auto_model.")}
    for node in graph.node:
        if node.op_type != "MatMul" or node.input[1] not in weights:
            continue
        name = node.name.removeprefix("/model/model.0/auto_model/").removesuffix("/MatMul")
        state[name.replace("/", ".") + ".weight"] = torch.from_numpy(weights[node.input[1]].T.copy())
    config = BertConfig.from_json_file(str(folder / "config.json"))
    config._attn_implementation = "eager"
    bert = BertModel(config, add_pooling_layer=False).eval()
    bert.load_state_dict(state, strict=True)
    return bert


def validate_compression(compressed, model, tokens, expected):
    """Measure decoded palette weights with PyTorch; native Core ML is checked by XCTest."""
    decoded = ct.optimize.coreml.decompress_weights(compressed)
    weights = {op.name: op.outputs[0].val for op in decoded._mil_program.functions["main"].operations
               if op.op_type == "const"}
    matched = 0
    with torch.no_grad():
        for name, parameter in model.named_parameters():
            prefix = name.replace(".", "_")
            key = next((prefix + suffix for suffix in ["_to_fp16_palettized", "_to_fp16", ""]
                        if prefix + suffix in weights), None)
            if key and tuple(weights[key].shape) == tuple(parameter.shape):
                parameter.copy_(torch.from_numpy(weights[key].astype(np.float32)))
                matched += 1
        assert matched == len(list(model.named_parameters())) - 2, "Every unfused parameter must be checked"
        # Fixed position/type lookups were folded into constants during conversion.
        position = next(v for k, v in weights.items() if k.startswith("position_embeddings")
                        and isinstance(v, np.ndarray) and v.shape == (1, 128, 384))
        token_type = next(v for k, v in weights.items() if k.startswith("token_type_embeddings")
                          and isinstance(v, np.ndarray) and v.shape == (1, 128, 384))
        model.bert.embeddings.position_embeddings.weight[:128].copy_(torch.from_numpy(position[0].astype(np.float32)))
        model.bert.embeddings.token_type_embeddings.weight[0].copy_(torch.from_numpy(token_type[0, 0].astype(np.float32)))
        actual = model(tokens.input_ids, tokens.attention_mask).numpy()
    return np.sum(expected * actual, axis=1).tolist()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--bits", type=int, default=6, choices=[4, 6, 8])
    args = parser.parse_args()
    source_hash = hashlib.sha256((args.source / "model.onnx").read_bytes()).hexdigest()
    assert source_hash == "994a58868f7abacacbf2192aa0aae8f56da8c4505dbde2740c861b24426ede6b", "Unexpected source weights"
    torch.set_num_threads(4)
    torch.manual_seed(0)
    tokenizer = BertTokenizerFast(vocab_file=str(args.source / "vocab.txt"), do_lower_case=True)
    texts = ["Dark atmospheric hip-hop", "Mellow soul music for a quiet evening",
             "Fast energetic electronic music for running", "A piano instrumental with no vocals",
             "Artist: Frank Ocean. Genres: alternative r&b, soul. Tempo: 80 BPM",
             "Café—Beyoncé’s R&B, 你好世界!", "  Music\nwith\todd spacing and lo-fi punctuation.  "]
    tokens = tokenizer(texts, padding="max_length", truncation=True, max_length=128, return_tensors="pt")
    model = SentenceModel(load_bert(args.source)).eval()
    with torch.no_grad():
        expected = model(tokens.input_ids, tokens.attention_mask).numpy()
    runtime = ort.InferenceSession(str(args.source / "model.onnx"), providers=["CPUExecutionProvider"])
    original = runtime.run(["sentence_embedding"], {name: tensor.numpy() for name, tensor in tokens.items()})[0]
    original /= np.linalg.norm(original, axis=1, keepdims=True)
    agreement = np.sum(expected * original, axis=1)
    print("PyTorch/ONNX cosine agreement:", agreement.tolist(), flush=True)
    assert min(agreement) > 0.9999, "Weight reconstruction must preserve the source model"
    traced = torch.jit.trace(model, (tokens.input_ids[:1], tokens.attention_mask[:1]))
    converted = ct.convert(traced, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS17,
                           inputs=[ct.TensorType(name="input_ids", shape=(1, 128), dtype=np.int32),
                                   ct.TensorType(name="attention_mask", shape=(1, 128), dtype=np.int32)],
                           outputs=[ct.TensorType(name="embedding")])
    for op in converted._mil_program.functions["main"].operations:
        if op.op_type == "const":
            value = op.outputs[0].val
            if isinstance(value, (np.ndarray, np.generic)) and np.issubdtype(value.dtype, np.floating):
                assert np.isfinite(value).all(), f"Non-finite converted constant: {op.name}"
    config = ct.optimize.coreml.OptimizationConfig(global_config=ct.optimize.coreml.OpPalettizerConfig(
        mode="kmeans", nbits=args.bits, granularity="per_tensor", weight_threshold=2048))
    compressed = ct.optimize.coreml.palettize_weights(converted, config=config)
    palette_agreement = validate_compression(compressed, model, tokens, expected)
    print("Compressed/reference cosine agreement:", palette_agreement, flush=True)
    assert min(palette_agreement) > (0.99 if args.bits >= 6 else 0.93), "Compression changed embeddings too much"
    compressed.author = "Sentence Transformers; Core ML adaptation for Erhu"
    compressed.license = "Apache License 2.0"
    compressed.short_description = f"Offline VYBE sentence embeddings; 384 dimensions, {args.bits}-bit palettes, 128 tokens."
    compressed.version = f"minilm-l6-v2-p{args.bits}-v2"
    compressed.input_description["input_ids"] = "BERT uncased WordPiece IDs, padded to 128 tokens."
    compressed.input_description["attention_mask"] = "1 for real tokens including CLS/SEP, 0 for padding."
    compressed.output_description["embedding"] = "Mean-pooled, L2-normalized 384-dimensional sentence vector."
    args.destination.parent.mkdir(parents=True, exist_ok=True)
    compressed.save(str(args.destination))
    package_bytes = sum(p.stat().st_size for p in args.destination.rglob("*") if p.is_file())
    print("Package bytes:", package_bytes, flush=True)
    # Reference fixtures verify Swift tokenization, mean pooling and native Core ML inference.
    fixture = [{"text": text, "ids": tokens.input_ids[i].tolist(), "embedding": expected[i].tolist()}
               for i, text in enumerate(texts)]
    (args.destination.parent / "reference-vectors.json").write_text(json.dumps(fixture, indent=2) + "\n")
    report = {"sourceSHA256": source_hash, "bits": args.bits, "packageBytes": package_bytes,
              "onnxTorchCosine": agreement.tolist(), "paletteCosine": palette_agreement}
    (args.destination.parent / "compression-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Source SHA-256:", source_hash, flush=True)


if __name__ == "__main__":
    main()
