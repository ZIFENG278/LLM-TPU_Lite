#!/bin/bash
set -x
models=
mode="int4"
folder="tmp"
quantize_args="--quantize W4F16"
addr_args=""
name=""
num_layers=
out_model=$name.bmodel
seq_length=
hidden_size=
num_core=

while [[ $# -gt 0 ]]; do
    key="$1"

    case $key in
    --mode)
        mode="$2"
        shift 2
        ;;
    --name)
        name="$2"
        shift 2
        ;;
    --addr_mode)
        addr_mode="$2"
        shift 2
        ;;
    --seq_length)
        seq_length="$2"
        shift 2
        ;;
    --num_core)
        num_core="$2"
        shift 2
        ;;
    *)
        echo "Invalid option: $key" >&2
        exit 1
        ;;
    :)
        echo "Option -$OPTARG requires an argument." >&2
        exit 1
        ;;
    esac
done

if [[ -z "$seq_length" ]]; then
    echo "Error: --seq_length is required." >&2
    exit 1
fi

if [[ -z "$num_core" ]]; then
    num_core=1
    echo "num_core set as default: 1" >&2
    exit 1
fi

if [ "$name" = "molmo-7b" ]; then
  num_layers=28
  hidden_size=3584
  echo "Compile Molmo-7B-D"
else
  >&2 echo -e "Error: Invalid name $name, the input name must be \033[31mmolmo-7b\033[0m"
  exit 1
fi

if [ x$mode == x"int8" ]; then
    quantize_args="--quantize W8F16"
elif [ x$mode == x"f16" ]; then
    quantize_args="--quantize F16"
elif [ x$mode == x"int4" ]; then
    quantize_args="--quantize W4F16 --q_group_size 64"
else
    echo "Error, unknown quantize mode"
    exit 1
fi

out_model=${name}_${mode}_seq${seq_length}_${num_core}core.bmodel

if [ x$addr_mode == x"io_alone" ]; then
    addr_args="--addr_mode io_alone"
fi

outdir=${folder}/embedding
mkdir -p $outdir
pushd $outdir

model_transform.py \
    --model_name embedding \
    --model_def ../onnx/embedding.pt \
    --input_shapes [[1,${seq_length}]] \
    --input_types "int32" \
    --mlir embedding.mlir

model_deploy.py \
    --mlir embedding.mlir \
    --quantize F16 \
    --quant_input \
    --chip bm1688 \
    --model embedding.bmodel

model_transform.py \
    --model_name embedding_cache \
    --model_def ../onnx/embedding.pt \
    --input_shapes [[1,1]] \
    --input_types "int32" \
    --mlir embedding_cache.mlir

model_deploy.py \
    --mlir embedding_cache.mlir \
    --quantize F16 \
    --quant_input \
    --quant_output \
    --chip bm1688 \
    --model embedding_cache.bmodel

models=$models' '$outdir'/embedding.bmodel '$outdir'/embedding_cache.bmodel '

rm -f *.npz
popd

echo $models

outdir=${folder}/$mode/lm_head
mkdir -p $outdir
pushd $outdir

model_transform.py \
    --model_name lm_head \
    --model_def ../../onnx/lm_head_with_topk.pt \
    --input_shapes [[1,${hidden_size}]] \
    --mlir lm_head.mlir

model_deploy.py \
    --mlir lm_head.mlir \
    $quantize_args \
    --quant_input \
    --chip bm1688 \
    --num_core $num_core \
    --model lm_head.bmodel

models=${models}${outdir}'/lm_head.bmodel '

rm -f *.npz
popd
echo $models

outdir=${folder}/$mode/block
mkdir -p $outdir
pushd $outdir
process_block()
{
    i=$1
    model_transform.py \
        --model_name block_$i \
        --model_def ../../onnx/block_$i.onnx \
        --mlir block_$i.mlir

    model_deploy.py \
        --mlir block_$i.mlir \
        $quantize_args \
        --quant_input \
        --quant_output \
        --chip bm1688 \
        --num_core $num_core \
        $device_args \
        --model block_$i.bmodel

    model_transform.py \
        --model_name block_cache_$i \
        --model_def ../../onnx/block_cache_$i.onnx \
        --mlir block_cache_$i.mlir

    model_deploy.py \
        --mlir block_cache_$i.mlir \
        $quantize_args \
        --quant_input \
        --quant_output \
        --chip bm1688 \
        --num_core $num_core \
        $device_args \
        $addr_args \
        --model block_cache_$i.bmodel
}

for ((i=0; i<$num_layers; i++)); do
    process_block $i &
    models=${models}${outdir}'/block_'$i'.bmodel '$outdir'/block_cache_'$i'.bmodel '
    sleep 45
done

rm -f *.npz *.onnx
popd
echo $models


outdir=${folder}/$mode/vit
mkdir -p $outdir
pushd $outdir

model_transform.py \
  --model_name vit \
  --model_def ../../onnx/vit/vision_transformer.onnx \
  --mlir vit.mlir 

model_deploy.py \
  --mlir vit.mlir \
  --quantize F16 \
  --quant_output \
  --chip bm1688 \
  --num_core $num_core \
  --model vit.bmodel

models=${models}${outdir}'/vit.bmodel '

rm -f *.npz *.onnx
popd
echo $models

model_tool --combine $models -o $out_model
