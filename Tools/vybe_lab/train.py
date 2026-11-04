"""Fine-tune the existing Apache-2.0 MiniLM model on human-labelled music queries.

No training data is uploaded. --validate-only works without ML dependencies.
"""
import argparse
import hashlib
import json
import random
import time
from pathlib import Path


def load_examples(path):
    rows = []
    for number, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
        if not line.strip():
            continue
        row = json.loads(line)
        for key in ('query', 'positive', 'negative'):
            if not isinstance(row.get(key), str) or not row[key].strip():
                raise ValueError(f'Line {number}: {key} must be a non-empty string')
            if len(row[key]) > 12000:
                raise ValueError(f'Line {number}: {key} is too long')
        if row['positive'].strip() == row['negative'].strip():
            raise ValueError(f'Line {number}: positive and negative must differ')
        rows.append(row)
    if not rows:
        raise ValueError('Provide real, human-labelled examples; the file is empty')
    return rows


def split_examples(rows, seed=42):
    # Keep repeated queries/paraphrase groups on one side of the split.
    def group(row):
        return str(row.get('group') or row['query']).strip().casefold()
    groups = sorted({group(row) for row in rows})
    if len(groups) < 6:
        raise ValueError('Use at least six distinct query groups; put paraphrases in the same group')
    random.Random(seed).shuffle(groups)
    held_out = set(groups[:max(1, len(groups) // 5)])
    return ([r for r in rows if group(r) not in held_out], [r for r in rows if group(r) in held_out])


def accuracy(model, rows):
    import numpy as np
    query = model.encode([r['query'] for r in rows], normalize_embeddings=True)
    positive = model.encode([r['positive'] for r in rows], normalize_embeddings=True)
    negative = model.encode([r['negative'] for r in rows], normalize_embeddings=True)
    return float(np.mean(np.sum(query * positive, axis=1) > np.sum(query * negative, axis=1)))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('data', type=Path)
    p.add_argument('output', type=Path, nargs='?', default=Path('trained-minilm'))
    p.add_argument('--base', default='sentence-transformers/all-MiniLM-L6-v2')
    p.add_argument('--epochs', type=int, default=2)
    p.add_argument('--batch-size', type=int, default=8)
    p.add_argument('--device', choices=['cpu', 'cuda', 'mps'])
    p.add_argument('--validate-only', action='store_true')
    args = p.parse_args()
    rows = load_examples(args.data)
    train, held_out = split_examples(rows)
    print(f'{len(train)} training / {len(held_out)} held-out examples; query groups are kept separate')
    if args.validate_only:
        return
    if len(rows) < 20:
        p.error('Use at least 20 real examples. Hundreds of representative examples are preferable.')
    if args.epochs < 1 or args.batch_size < 1:
        p.error('Epochs and batch size must be positive')
    if args.output.exists() and any(args.output.iterdir()):
        p.error('Output folder is not empty; choose a new folder to retain previous weights')
    import torch
    from sentence_transformers import SentenceTransformer, InputExample, losses
    from torch.utils.data import DataLoader
    torch.manual_seed(42)
    model = SentenceTransformer(args.base, device=args.device, trust_remote_code=False)
    model.max_seq_length = 128
    config = model[0].auto_model.config
    if config.model_type != 'bert' or config.hidden_size != 384 or config.num_hidden_layers != 6:
        p.error('This kit exports only the existing MiniLM-L6 384-dimensional architecture')
    baseline = accuracy(model, held_out)
    examples = [InputExample(texts=[r['query'], r['positive'], r['negative']]) for r in train]
    loader = DataLoader(examples, shuffle=True, batch_size=min(args.batch_size, len(examples)))
    objective = losses.TripletLoss(model=model, triplet_margin=0.2)
    started = time.time()
    model.fit(train_objectives=[(loader, objective)], epochs=args.epochs,
              warmup_steps=min(100, len(loader) * args.epochs // 10),
              optimizer_params={'lr': 2e-5}, show_progress_bar=True)
    tuned = accuracy(model, held_out)
    model.save(str(args.output), safe_serialization=True)
    report = {'base': args.base, 'seed': 42, 'maxSequenceLength': 128,
              'trainingExamples': len(train), 'heldOutExamples': len(held_out),
              'baselineTripletAccuracy': baseline, 'trainedTripletAccuracy': tuned,
              'trainingSeconds': time.time() - started,
              'dataSHA256': hashlib.sha256(args.data.read_bytes()).hexdigest()}
    (args.output / 'erhu-training-report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    print('A small held-out score is not proof of general music relevance. Test your actual library.')


if __name__ == '__main__':
    main()
