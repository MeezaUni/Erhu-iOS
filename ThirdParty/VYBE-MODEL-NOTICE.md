# VYBE sentence model

The bundled `VybeSentence.mlpackage` and `vybe-vocab.txt` derive from
**sentence-transformers/all-MiniLM-L6-v2**, distributed under the Apache License 2.0.

Original model: https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2

Source mirrors used for conversion:

- https://github.com/clems4ever/all-minilm-l6-v2-go at
  `98aaab590a822d60ed359f7f8cb726e40daae4f4` (ONNX model).
- https://github.com/Xyntopia/all-MiniLM-L6-v2 at
  `48a5a372879ed2ed147ab84836e345977276d9b2` (BERT config and vocabulary).

The Erhu adaptation reconstructs the encoder, uses masked mean pooling and L2 normalization,
limits inputs to 128 tokens, converts to an iOS 17 Core ML program with FP16 computation and
compresses weights using 6-bit k-means palettes. It does not fine-tune the original model.

The license and this model attribution ship in
`Erhu/Resources/Vybe/vybe-model-license.txt`. Conversion and validation are described in
[`docs/VYBE.md`](../docs/VYBE.md).
