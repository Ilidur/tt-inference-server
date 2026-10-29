#!/bin/bash
# Builds the custom vllm-tt-metal image for Qwen3.6-35B-A3B on Wormhole T3K,
# reusing the already-built ~/qwen36-t3k/tt-metal checkout (fix committed as
# dd1efe0f553 on ign/qwen_3.6_27B_dFLASH) instead of cloning+recompiling tt-metal.
set -euo pipefail

REPO_ROOT=~/.local/lib/tt-inference-server
TT_METAL_SRC=~/qwen36-t3k/tt-metal
VLLM_TT_PLUGIN_SRC=~/qwen36-t3k/vllm-tt-plugin
# The actual source we ship: tt-metal's HEAD (prefix-caching Phases 1-5, see
# docs/DESIGN_qwen36_prefix_caching.md) and vllm-tt-plugin's local branch carrying the
# companion MambaSpec/block-table commits those phases depend on -- both unpushed, so both
# are baked from a local checkout rather than git-cloned, same as TT_METAL_SRC already was.
TT_METAL_COMMIT="$(cd "${TT_METAL_SRC}" && git rev-parse --short=12 HEAD)"
TT_VLLM_COMMIT_SHA_OR_TAG="$(cd "${VLLM_TT_PLUGIN_SRC}" && git rev-parse --short=12 HEAD)"
IMAGE_TAG="localhost/qwen36-35b-a3b-t3k:${TT_METAL_COMMIT}-${TT_VLLM_COMMIT_SHA_OR_TAG}"
TT_METAL_SRC_IMAGE="localhost/tt-metal-src-qwen36:${TT_METAL_COMMIT}"
VLLM_TT_PLUGIN_SRC_IMAGE="localhost/vllm-tt-plugin-src-qwen36:${TT_VLLM_COMMIT_SHA_OR_TAG}"
OPENMPI_SRC="/opt/openmpi-v5.0.7-ulfm"
OPENMPI_SRC_IMAGE="localhost/openmpi-ulfm-src:v5.0.7"
TT_METAL_DOCKERFILE_URL="ubuntu:22.04"

cd "$REPO_ROOT"

echo "== Step 1: package the pre-built ~/qwen36-t3k/tt-metal tree as a local image =="
# podman 3.4.4 on this box has no buildx / --build-context support, so the local source tree is
# packaged as a tiny scratch image (COPY-only) and pulled in downstream via COPY --from=<image>,
# which works on any docker/podman version. This also avoids tt-metal's own ci-build toolchain
# image entirely -- we don't compile tt-metal here, it's already built, and the runtime image
# only needs runtime libs + vllm-tt-plugin's own build deps (both installed explicitly below).
if ! docker inspect --type=image "${TT_METAL_SRC_IMAGE}" > /dev/null 2>&1; then
    printf 'FROM scratch\nCOPY . /\n' > /tmp/Dockerfile.tt_metal_src
    docker build -t "${TT_METAL_SRC_IMAGE}" -f /tmp/Dockerfile.tt_metal_src "${TT_METAL_SRC}"
else
    echo "source image already present: ${TT_METAL_SRC_IMAGE}"
fi

echo "== Step 1b: package /opt/openmpi-v5.0.7-ulfm (ttnn._ttnn.so's actual libmpi.so.40, not apt's libopenmpi3) =="
if ! docker inspect --type=image "${OPENMPI_SRC_IMAGE}" > /dev/null 2>&1; then
    printf 'FROM scratch\nCOPY . /\n' > /tmp/Dockerfile.openmpi_src
    docker build -t "${OPENMPI_SRC_IMAGE}" -f /tmp/Dockerfile.openmpi_src "${OPENMPI_SRC}"
else
    echo "source image already present: ${OPENMPI_SRC_IMAGE}"
fi

echo "== Step 1c: package the local ~/qwen36-t3k/vllm-tt-plugin checkout as a local image =="
if ! docker inspect --type=image "${VLLM_TT_PLUGIN_SRC_IMAGE}" > /dev/null 2>&1; then
    printf 'FROM scratch\nCOPY . /\n' > /tmp/Dockerfile.vllm_tt_plugin_src
    docker build -t "${VLLM_TT_PLUGIN_SRC_IMAGE}" -f /tmp/Dockerfile.vllm_tt_plugin_src "${VLLM_TT_PLUGIN_SRC}"
else
    echo "source image already present: ${VLLM_TT_PLUGIN_SRC_IMAGE}"
fi

echo "== Step 2: regenerate model_spec.json (includes Qwen3.6-35B-A3B/T3K entry) =="
# MODEL_SPECS_ENV defaults to "prod" (workflows/model_specs/prod/), which never sees our
# workflows/model_specs/dev/llm.yaml edit at all -- must be dev to pick it up.
MODEL_SPECS_ENV=dev python3 -c "
import sys
from pathlib import Path
project_root = Path('${REPO_ROOT}')
if project_root not in sys.path:
    sys.path.insert(0, str(project_root))
from scripts.build_docker_images import generate_model_specs_json
generate_model_specs_json()
"

echo "== Step 3: build the qwen36-35b-a3b-t3k image =="
docker build \
    -t "${IMAGE_TAG}" \
    --build-arg TT_METAL_SRC_IMAGE="${TT_METAL_SRC_IMAGE}" \
    --build-arg OPENMPI_SRC_IMAGE="${OPENMPI_SRC_IMAGE}" \
    --build-arg TT_METAL_DOCKERFILE_URL="${TT_METAL_DOCKERFILE_URL}" \
    --build-arg TT_VLLM_COMMIT_SHA_OR_TAG="${TT_VLLM_COMMIT_SHA_OR_TAG}" \
    --build-arg VLLM_TT_PLUGIN_SRC_IMAGE="${VLLM_TT_PLUGIN_SRC_IMAGE}" \
    --build-arg CONTAINER_APP_UID=1000 \
    . -f vllm-tt-metal/vllm.tt-metal.src.dev.qwen36-t3k.Dockerfile

echo "✅ built ${IMAGE_TAG}"
