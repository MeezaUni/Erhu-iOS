"""Reproduce compatibility candidates without downloading or retraining any weights."""
import argparse
import hashlib
from pathlib import Path
import numpy as np
import coremltools as ct


def fp32_output(source, target):
    spec = ct.models.utils.load_spec(source / 'Data/com.apple.CoreML/model.mlmodel')
    block = next(iter(spec.mlProgram.functions['main'].block_specializations.values()))
    output = next(o for o in block.operations for v in o.outputs if v.name == 'embedding')
    variable = next(v for v in output.outputs if v.name == 'embedding')
    variable.name = 'embedding_fp16'
    dtype = block.operations.add(); dtype.type = 'const'
    dtype.attributes['name'].immediateValue.tensor.strings.values.append('embedding_output_dtype')
    value = dtype.attributes['val']; value.type.tensorType.dataType = ct.proto.MIL_pb2.STRING
    value.immediateValue.tensor.strings.values.append('fp32')
    node = dtype.outputs.add(); node.name = 'embedding_output_dtype'; node.type.tensorType.dataType = ct.proto.MIL_pb2.STRING
    cast = block.operations.add(); cast.type = 'cast'
    cast.attributes['name'].immediateValue.tensor.strings.values.append('embedding_output_fp32')
    cast.inputs['x'].arguments.add().name = 'embedding_fp16'
    cast.inputs['dtype'].arguments.add().name = 'embedding_output_dtype'
    node = cast.outputs.add(); node.CopyFrom(variable); node.name = 'embedding'
    node.type.tensorType.dataType = ct.proto.MIL_pb2.FLOAT32
    spec.description.output[0].type.multiArrayType.dataType = ct.proto.FeatureTypes_pb2.ArrayFeatureType.FLOAT32
    ct.models.MLModel(spec, weights_dir=str(source / 'Data/com.apple.CoreML/weights'), skip_model_load=True).save(str(target))


def float32_program(model):
    from coremltools.converters.mil.mil import Builder as mb, Function, Program
    old = model._mil_program.functions['main']
    placeholders = {name: mb.placeholder(shape=tuple(var.shape), dtype=var.dtype) for name, var in old.inputs.items()}
    with Function(placeholders, opset_version=ct.target.iOS17) as function:
        mapped = {var: function.inputs[name] for name, var in old.inputs.items()}
        def remap(value):
            if isinstance(value, (list, tuple)): return type(value)(remap(v) for v in value)
            return mapped[value]
        for op in old.operations:
            if op.op_type == 'const':
                value = op.outputs[0].val
                if isinstance(value, (np.ndarray, np.generic)) and value.dtype == np.float16: value = value.astype(np.float32)
                if isinstance(value, str) and value == 'fp16': value = 'fp32'
                result = mb.const(val=value, name=op.name)
            else:
                result = getattr(mb, op.op_type)(name=op.name, **{key: remap(value) for key, value in op.inputs.items()})
            values = result if isinstance(result, (list, tuple)) else [result]
            mapped.update(zip(op.outputs, values))
        function.set_outputs([mapped[v] for v in old.outputs])
    program = Program(); program.add_function('main', function)
    return ct.convert(program, convert_to='mlprogram', minimum_deployment_target=ct.target.iOS17,
                      compute_precision=ct.precision.FLOAT32, skip_model_load=True)


def repack(model):
    weights = {op.name: np.array(op.outputs[0].val, copy=True)
               for op in model._mil_program.functions['main'].operations
               if op.op_type == 'const' and isinstance(op.outputs[0].val, np.ndarray)
               and op.outputs[0].val.dtype.kind == 'f' and op.outputs[0].val.size >= 2048
               and np.unique(op.outputs[0].val).size <= 256}
    assert len(weights) >= 30, 'Expected real transformer weights'
    def exact_palette(weight):
        unique, indices = np.unique(weight, return_inverse=True)
        assert len(unique) <= 256 and np.isfinite(unique).all()
        lut = np.zeros(256, dtype=weight.dtype); lut[:len(unique)] = unique
        return lut, indices.astype(np.uint8).reshape(-1)
    config = ct.optimize.coreml.OpPalettizerConfig(mode='custom', lut_function=exact_palette, granularity='per_tensor', weight_threshold=2048)
    packed = ct.optimize.coreml.palettize_weights(model, config=ct.optimize.coreml.OptimizationConfig(op_name_configs={name: config for name in weights}))
    restored = ct.optimize.coreml.decompress_weights(packed)
    actual = [op.outputs[0].val for op in restored._mil_program.functions['main'].operations
              if op.op_type == 'const' and isinstance(op.outputs[0].val, np.ndarray)]
    def digest(array):
        return hashlib.sha256(str(array.shape).encode() + array.dtype.str.encode() + array.tobytes()).hexdigest()
    actual_hashes = {digest(array) for array in actual}
    for name, expected in weights.items():
        assert digest(expected) in actual_hashes, f'Repacking changed {name}'
    print(f'VARIANT_MODEL exact repack verified for {len(weights)} weight tensors')
    return packed


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('source', type=Path); p.add_argument('destination', type=Path)
    args = p.parse_args(); args.destination.mkdir(parents=True, exist_ok=True)
    fp32_output(args.source, args.destination / 'MiniLMIO32.mlpackage')
    model = ct.models.MLModel(str(args.source), skip_model_load=True)
    dense = ct.optimize.coreml.decompress_weights(model)
    packed = repack(dense)
    target = args.destination / 'MiniLM8Bit.mlpackage'; packed.save(str(target))
    fp32_output(target, args.destination / 'MiniLM8BitIO32.mlpackage')
    repack(float32_program(dense)).save(str(args.destination / 'MiniLM32.mlpackage'))


if __name__ == '__main__': main()
