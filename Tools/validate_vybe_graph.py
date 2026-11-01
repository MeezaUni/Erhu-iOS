"""Evaluate exported Core ML operations locally; native XCTest remains authoritative.

Run with the pinned conversion tools: python Tools/validate_vybe_graph.py PACKAGE REFERENCES.
This exercises the converted FP16 masking/pooling operations as well as decoded weights.
"""
import json
import sys

import coremltools as ct
import numpy as np


def assign(variable, value):
    variable._sym_val = variable._sym_type()
    variable._sym_val.val = value


def main():
    model = ct.models.MLModel(sys.argv[1], skip_model_load=True)
    decoded = ct.optimize.coreml.decompress_weights(model)
    function = decoded._mil_program.functions["main"]
    with open(sys.argv[2]) as source:
        references = json.load(source)
    agreements = []
    for reference in references:
        ids = np.array([reference["ids"]], dtype=np.int32)
        assign(function.inputs["input_ids"], ids)
        assign(function.inputs["attention_mask"], (ids != 0).astype(np.int32))
        for operation in function.operations:
            if operation.op_type == "const":
                continue
            values = operation.value_inference()
            if len(operation.outputs) == 1:
                values = [values]
            for output, value in zip(operation.outputs, values):
                assign(output, value)
        result = function.outputs[0].val.astype(np.float32).reshape(-1)
        expected = np.array(reference["embedding"])
        cosine = float(result @ expected / np.linalg.norm(result) / np.linalg.norm(expected))
        print(reference["text"], cosine, flush=True)
        assert np.isfinite(cosine) and cosine > 0.985, "Converted operations must preserve embeddings"
        agreements.append(cosine)
    print("Converted graph minimum cosine agreement:", min(agreements), flush=True)


if __name__ == "__main__":
    main()
