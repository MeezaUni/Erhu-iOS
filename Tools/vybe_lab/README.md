# Local VYBE training kit

This kit fine-tunes the current **Apache-2.0 MiniLM** model. It does not train
EmbeddingGemma or make an unsupported `.task` file compatible with Core ML.
The current app model is unchanged. No training or relevance improvement is
claimed until you supply data and run the experiment.

A CPU laptop can fine-tune this 22M-parameter model. A supported GPU is optional;
start with batch size 4 if memory is limited. Actual runtime depends on your CPU,
RAM, GPU and dataset. You need Python 3.12, disk space for Python/PyTorch and an
internet connection for the initial public-model download. The scripts do not
upload your music, examples or weights.

## Prepare examples

Copy the **format** in `examples.jsonl`, then write your own `music-pairs.jsonl`.
The three supplied rows are illustrations, not sufficient training data.
Each line needs:

- `query`: something you would actually type into VYBE.
- `positive`: the description of a track you want recommended.
- `negative`: a plausible but wrong recommendation for that query.
- `group`: keep paraphrases of the same intent in one group, avoiding evaluation leakage.

Use the metadata/lyrics descriptions VYBE actually has, rather than invented
facts about a track. Missing metadata cannot be fixed by bigger weights alone.
Use at least 20 examples across six groups to run; hundreds of diverse human
judgements and an independently curated test set are more useful. Do not train
the model to memorize track names: the app resolves those separately.

## Install and train

From the repository root, create/activate a Python 3.12 virtual environment.
On Linux/Windows without an NVIDIA GPU, first install the CPU wheel:

```sh
python -m pip install torch==2.5.1 --index-url https://download.pytorch.org/whl/cpu
python -m pip install -r Tools/vybe_lab/requirements.txt
python Tools/vybe_lab/train.py music-pairs.jsonl --validate-only
python Tools/vybe_lab/train.py music-pairs.jsonl trained-minilm --device cpu --batch-size 4
```

On macOS, install `torch==2.5.1` from the normal PyPI index instead. For NVIDIA,
follow PyTorch's official installation instructions for a compatible 2.5.1 CUDA
wheel and use `--device cuda`. Supported Apple Silicon can use `--device mps`.
Training leaves held-out query groups untouched and writes a before/after
triplet-accuracy report. A tiny test set or improved training loss does not prove
better recommendations on a real music collection.

## Export for Erhu

```sh
python Tools/vybe_lab/export_trained.py trained-minilm exported-vybe
```

The exporter only loads local safetensors, requires the existing app vocabulary,
checks teacher/pooling agreement, exports the existing 128-token/384-dimensional
Core ML interface and verifies 6-bit compression agreement. The original pinned
ONNX exporter retains its existing source-hash checks. Core ML conversion can run
on supported Python hosts; native compilation/inference requires Apple's tools.

Send/share `exported-vybe` plus `erhu-training-report.json` from the trained folder
for review. The actual training examples can stay private. Before shipping, we
must run native reference-vector and relevance checks, retain Apache notices,
and change `CompactSentenceEmbedder.modelIdentity` to the generated identity so
old search vectors cannot be mixed with the new model. No app update or model
replacement happens automatically when you run these scripts.

The kit's Python syntax/data validation can be checked without model downloads.
A complete fine-tune/export has not been run in the Linux development workspace;
it needs the ML environment and real examples described above.
