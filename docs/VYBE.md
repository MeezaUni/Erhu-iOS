# Offline music discovery

VYBE embeds the listener's own artists, genres, tagged tempo and an excerpt of saved lyrics.
It searches those descriptions on the phone. Music, queries and lyrics are never uploaded.
Titles and album names have exact lookup routes; their words do not contaminate mood embeddings.
Missing tags are left unknown. The model does not listen to audio or establish a track's mood.

The iOS encoder is **all-MiniLM-L6-v2**, a 22.7M-parameter, 384-dimensional sentence transformer,
converted to Core ML for iOS 17+. Its uncased WordPiece vocabulary and model ship in the app;
there is no first-run download, Python, ONNX runtime or additional inference framework.
Apple's Core ML selects the available CPU, GPU or Neural Engine. Indexing runs off the main
thread, resumes from disk and only embeds changed descriptions. The model loads lazily.
Changing model identity or document version invalidates incompatible cached vectors.

Android uses **EmbeddingGemma 300M**, supplied by the listener as a roughly 184 MB MediaPipe
int4/int8 bundle. That file is already quantized and is tied to a different runtime. The iOS
version uses the smaller encoder to keep installation and runtime costs low; it does not claim
quality parity with EmbeddingGemma or derive its weights from Gemma.

## Compression and validation

The final Core ML package uses **6-bit k-means weight palettes** with FP16 computation. It is
about **17 MB**, plus a 232 KB vocabulary. The tested 4-bit package was 11.4 MB, but 6-bit
compression preserved vectors more closely: minimum cosine agreement 0.9957 versus 0.9457
on an initial 11-description check. These are agreement measurements, not general accuracy scores.

Eight fixed music-style queries retained the intended top result among ten contrasting styles
in both the source encoder and decoded 6-bit encoder. Native XCTest checks the bundled model,
Swift tokenizer parity, finite normalized inference, agreement against original FP32 reference
vectors, the eight style queries and a 25 MB ceiling for the compiled model. These tests do not
replace iPhone testing of latency, battery consumption or relevance on a real music library.

Metadata adds explicit controls:

- Genre aliases such as R&B/rhythm and blues, hip-hop/hiphop/rap, lo-fi and drum and bass.
- Exclusions of a known artist or genre, such as “chill R&B, no rap” or “without Drake”.
- Tagged BPM constraints: “under 100 BPM”, “120–150 BPM”, or “around 90 BPM” (±5).
- Release years and decades, such as “released in 2016” or “music from the 90s”.
- Exact artist, album and title names, including artist diacritics and featured credits.
- A small artist/album repetition penalty among close semantic matches; an explicitly named
  artist retains priority. Constraints never infer a missing BPM or year.

The query is rerun when initial indexing finishes, so a search made while learning the library
does not get stuck with incomplete results. The screen also offers a search button and dismisses
the keyboard on submission.

## Reproducing the model

Use Python 3.12 in a virtual environment. Install torch 2.5.1+cpu from the official PyTorch CPU
index, then coremltools 8.3.0, transformers 4.46.3, numpy 1.26.4, onnx 1.17.0,
onnxruntime 1.20.1, scikit-learn 1.5.1 and protobuf 4.25.5.

The input folder contains model.onnx from
[`clems4ever/all-minilm-l6-v2-go`](https://github.com/clems4ever/all-minilm-l6-v2-go/tree/98aaab590a822d60ed359f7f8cb726e40daae4f4),
path `all_minilm_l6_v2/model.onnx`, and config.json/vocab.txt from
[`Xyntopia/all-MiniLM-L6-v2`](https://github.com/Xyntopia/all-MiniLM-L6-v2/tree/48a5a372879ed2ed147ab84836e345977276d9b2).
Both identify the original Sentence Transformers model. The direct Hugging Face endpoint was
unavailable from the development network, so these public, pinned mirrors supplied the assets.

The ONNX SHA-256 is
`994a58868f7abacacbf2192aa0aae8f56da8c4505dbde2740c861b24426ede6b`.
The exporter verifies this hash, reconstructs BERT weights without loading a pickle or executing
remote model code, checks ONNX/PyTorch agreement, exports fixed 128-token inputs with masked
mean pooling and L2 normalization, compresses weights and measures decoded-weight agreement.

Run `python Tools/export_vybe_model.py SOURCE_FOLDER OUTPUT_FOLDER/VybeSentence.mlpackage`.
Copy the package into `Erhu/Resources/Vybe`, reference-vectors.json into the test fixtures as
vybe-reference-vectors.json, and retain the compression report. The generated files are checked
in so a normal app build neither downloads a model nor runs conversion tooling.

Model provenance and the bundled Apache 2.0 license are recorded in
[`ThirdParty/VYBE-MODEL-NOTICE.md`](../ThirdParty/VYBE-MODEL-NOTICE.md).
