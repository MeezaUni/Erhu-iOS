"""Convert a local fine-tuned MiniLM to the existing iOS VYBE input/output contract.

This does not modify the shipped model or weaken the original pinned-ONNX exporter.
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('source', type=Path)
    p.add_argument('output', type=Path)
    args = p.parse_args()
    import coremltools as ct
    import numpy as np
    import torch
    from transformers import BertModel, BertTokenizerFast
    from sentence_transformers import SentenceTransformer
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from export_vybe_model import SentenceModel, validate_compression
    expected_vocab = Path(__file__).resolve().parents[2] / 'Erhu/Resources/Vybe/vybe-vocab.txt'
    vocab = args.source / 'vocab.txt'
    if vocab.read_bytes() != expected_vocab.read_bytes():
        p.error('Vocabulary differs from the iOS tokenizer. Do not replace the app model with this export.')
    weights = args.source / 'model.safetensors'
    digest = hashlib.sha256(weights.read_bytes()).hexdigest()
    torch.set_num_threads(4); torch.manual_seed(0)
    bert = BertModel.from_pretrained(str(args.source), local_files_only=True, use_safetensors=True,
                                    add_pooling_layer=False, attn_implementation='eager').eval()
    if bert.config.hidden_size != 384 or bert.config.num_hidden_layers != 6:
        p.error('Only the current MiniLM-L6 architecture is supported')
    model = SentenceModel(bert).eval()
    texts = ['Dark atmospheric hip-hop', 'Mellow soul music for a quiet evening',
             'Fast energetic electronic music for running', 'A piano instrumental with no vocals',
             'Artist: Frank Ocean. Genres: alternative r&b, soul. Tempo: 80 BPM',
             'Café—Beyoncé’s R&B, 你好世界!', '  Music\nwith\todd spacing and lo-fi punctuation.  ']
    tokenizer = BertTokenizerFast(vocab_file=str(vocab), do_lower_case=True)
    tokens = tokenizer(texts, padding='max_length', truncation=True, max_length=128, return_tensors='pt')
    with torch.no_grad():
        expected = model(tokens.input_ids, tokens.attention_mask).numpy()
    teacher = SentenceTransformer(str(args.source), device='cpu', local_files_only=True, trust_remote_code=False)
    teacher.max_seq_length = 128
    reference = teacher.encode(texts, normalize_embeddings=True)
    agreement = np.sum(expected * reference, axis=1)
    assert np.isfinite(expected).all() and min(agreement) > 0.9999, 'Pooling/tokenization differs from the trained model'
    del teacher
    traced = torch.jit.trace(model, (tokens.input_ids[:1], tokens.attention_mask[:1]))
    converted = ct.convert(traced, convert_to='mlprogram', minimum_deployment_target=ct.target.iOS17,
        inputs=[ct.TensorType(name='input_ids', shape=(1, 128), dtype=np.int32),
                ct.TensorType(name='attention_mask', shape=(1, 128), dtype=np.int32)],
        outputs=[ct.TensorType(name='embedding', dtype=np.float32)], compute_precision=ct.precision.FLOAT32)
    for op in converted._mil_program.functions['main'].operations:
        if op.op_type == 'const' and isinstance(op.outputs[0].val, (np.ndarray, np.generic)):
            value = op.outputs[0].val
            if np.issubdtype(value.dtype, np.floating):
                assert np.isfinite(value).all(), f'Non-finite Core ML constant: {op.name}'
    config = ct.optimize.coreml.OptimizationConfig(global_config=ct.optimize.coreml.OpPalettizerConfig(
        mode='uniform', nbits=8, granularity='per_tensor', weight_threshold=2048))
    compressed = ct.optimize.coreml.palettize_weights(converted, config=config)
    palette = validate_compression(compressed, model, tokens, expected)
    assert min(palette) > 0.99, 'Compression changed the model too much'
    model_id = 'minilm-local-' + digest[:12] + '-p8-fp32'
    compressed.author = 'Sentence Transformers; local fine-tune and Erhu Core ML adaptation'
    compressed.license = 'Apache License 2.0'
    compressed.version = model_id
    args.output.mkdir(parents=True, exist_ok=True)
    compressed.save(str(args.output / 'VybeSentence.mlpackage'))
    (args.output / 'reference-vectors.json').write_text(json.dumps([
        {'text': text, 'ids': tokens.input_ids[i].tolist(), 'embedding': expected[i].tolist()}
        for i, text in enumerate(texts)], indent=2) + '\n')
    (args.output / 'export-report.json').write_text(json.dumps({'modelIdentity': model_id,
        'weightsSHA256': digest, 'teacherCosine': agreement.tolist(), 'paletteCosine': palette}, indent=2) + '\n')
    print('Exported', model_id, '— native iPhone inference and real-library relevance still need validation.')


if __name__ == '__main__':
    main()
