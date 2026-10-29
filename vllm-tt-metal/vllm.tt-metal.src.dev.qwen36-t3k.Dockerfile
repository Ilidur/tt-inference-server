# syntax=docker/dockerfile:1
# SPDX-License-Identifier: Apache-2.0
#
# Qwen3.6-35B-A3B on Wormhole T3K — custom build.
#
# Unlike vllm.tt-metal.src.dev.Dockerfile, this does NOT clone+build tt-metal from GitHub:
# the fix for Qwen3.6-35B-A3B on Wormhole (gdn_conv_channel_chunks gating) lives only on the
# local `ign/qwen_3.6_27B_dFLASH` branch checkout at ~/qwen36-t3k/tt-metal on this box, already
# built (build/lib + python_env present). We COPY that pre-built tree in directly instead of
# re-cloning/re-compiling it, and only clone+install vllm-tt-plugin (public, no local changes).
#
# TT_METAL_SRC_IMAGE must be a local image whose root is ~/qwen36-t3k/tt-metal's contents
# (built by build_qwen36_35b_t3k_image.sh from a throwaway `FROM scratch / COPY . /` Dockerfile,
# since this box's podman has no --build-context support for a named local-dir context).
#
# Base image: plain ubuntu:22.04, not tt-metal's own ci-build toolchain image. We don't compile
# tt-metal in this Dockerfile (it's already built on the host and COPYed in below) and this box's
# podman has no buildx/bake support to build that toolchain image anyway. All we need is a base
# matching the host's own OS/glibc (Ubuntu 22.04.5, glibc 2.35) that the prebuilt .so's link
# against, plus the runtime/build deps installed explicitly below.

ARG TT_METAL_DOCKERFILE_URL=ubuntu:22.04

FROM ${TT_METAL_DOCKERFILE_URL} AS runtime

ARG TT_VLLM_COMMIT_SHA_OR_TAG
ARG VLLM_TT_PLUGIN_SRC_IMAGE
ARG CONTAINER_APP_UID=1000
ARG DEBIAN_FRONTEND=noninteractive
ARG CONTAINER_APP_USERNAME=container_app_user
ARG HOME_DIR=/home/${CONTAINER_APP_USERNAME}
ARG APP_DIR="${HOME_DIR}/app"

ENV SHELL=/bin/bash \
    TZ=America/Los_Angeles \
    CONTAINER_APP_USERNAME=${CONTAINER_APP_USERNAME} \
    ARCH_NAME=wormhole_b0 \
    TT_METAL_HOME=${HOME_DIR}/tt-metal \
    CONFIG=Release \
    TT_METAL_ENV=dev \
    VLLM_TARGET_DEVICE="tt" \
    vllm_tt_plugin_dir=${HOME_DIR}/vllm-tt-plugin \
    LOGURU_LEVEL=INFO \
    TT_METAL_LOGS_PATH=${HOME_DIR}/logs \
    RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo
ENV PYTHONPATH=${TT_METAL_HOME}:${APP_DIR} \
    PYTHON_ENV_DIR=${TT_METAL_HOME}/python_env \
    LD_LIBRARY_PATH=${TT_METAL_HOME}/build/lib:/opt/openmpi-v5.0.7-ulfm/lib \
    PATH="$CARGO_HOME/bin:$PATH"

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-venv python3-dev git build-essential wget curl ca-certificates \
    libgl1 libsndfile1 libffi-dev libssl-dev protobuf-compiler libprotobuf-dev pkg-config \
    nano acl jq vim htop screen tmux unzip zip iputils-ping rsync \
    libopenmpi3 \
    && rm -rf /var/lib/apt/lists/* && apt-get clean \
    && useradd -u ${CONTAINER_APP_UID} -s /bin/bash -d ${HOME_DIR} ${CONTAINER_APP_USERNAME} \
    && mkdir -p ${HOME_DIR} ${APP_DIR} ${HOME_DIR}/logs \
    && chown -R ${CONTAINER_APP_USERNAME}:${CONTAINER_APP_USERNAME} ${HOME_DIR} \
    && echo "source ${PYTHON_ENV_DIR}/bin/activate" >> ${HOME_DIR}/.bashrc

RUN mkdir -p "${RUSTUP_HOME}" "${CARGO_HOME}" \
    && chown -R ${CONTAINER_APP_UID}:${CONTAINER_APP_UID} "${RUSTUP_HOME}" "${CARGO_HOME}" \
    && chmod -R 775 "${RUSTUP_HOME}" "${CARGO_HOME}"
RUN /bin/bash -c "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --no-modify-path \
    && . ${CARGO_HOME}/env && rustup update"

# Pre-built tt-metal source tree, already compiled and with the WH GDN-chunking fix committed
# (dd1efe0f553 on ign/qwen_3.6_27B_dFLASH). Supplied as a prebuilt local image (this podman is too
# old for `docker build --build-context`), not cloned.
ARG TT_METAL_SRC_IMAGE
COPY --from=${TT_METAL_SRC_IMAGE} --chown=${CONTAINER_APP_USERNAME}:${CONTAINER_APP_USERNAME} \
    / ${TT_METAL_HOME}

# ttnn's compiled extension (_ttnn.so) links libmpi.so.40 from the box's custom ULFM (fault-tolerant
# MPI) build at /opt/openmpi-v5.0.7-ulfm, not apt's libopenmpi3 -- needed for tt-metal's fabric
# control plane. Ship the same tree so the container resolves the identical library it was built
# against (see LD_LIBRARY_PATH above).
ARG OPENMPI_SRC_IMAGE
COPY --from=${OPENMPI_SRC_IMAGE} / /opt/openmpi-v5.0.7-ulfm

# python_env/bin/python(3) are symlinks to the host's uv-managed interpreter
# (~/.local/share/uv/python/cpython-3.10-.../python3.10) -- absolute paths that don't exist in
# this image. Must be fixed before anything sources the venv (both here and in the official
# Dockerfile's runtime stage, though there it's the venv's COPY from the builder stage that
# breaks it; here it's this COPY). System python3 here is also 3.10 (matches the venv's ABI).
RUN cd ${PYTHON_ENV_DIR}/bin \
    && rm -f python python3 \
    && ln -s /usr/bin/python3 python3 \
    && ln -s python3 python \
    && chmod -R +x ${PYTHON_ENV_DIR}/bin

# ttnn (and tt_lib/tracy/triage) are installed editable, pointing at the host's absolute build
# path (/home/ttuser/qwen36-t3k/tt-metal). Two places bake that path in and both survive the COPY
# unchanged, silently: the *.pth files just add a now-nonexistent dir to sys.path (ttnn imports as
# an empty namespace package, so `import ttnn` succeeds but `ttnn.device` etc. 404s), and
# setuptools' generated editable finder (__editable__.ttnn-*.py) has its own separate MAPPING
# dict of package -> absolute path serving the actual imports. Rewrite both to ${TT_METAL_HOME}
# and drop the stale __pycache__ so a cached copy of the old MAPPING isn't loaded instead.
RUN SITE_PACKAGES="${PYTHON_ENV_DIR}/lib/python3.10/site-packages" \
    && OLD_HOME="/home/ttuser/qwen36-t3k/tt-metal" \
    && grep -rl "${OLD_HOME}" "${SITE_PACKAGES}" --include="*.pth" --include="*.py" \
       | xargs -r sed -i "s|${OLD_HOME}|${TT_METAL_HOME}|g" \
    && find "${SITE_PACKAGES}/__pycache__" -iname "__editable___ttnn*" -delete

ENV UV_HTTP_RETRIES=10

# vllm-tt-plugin owns the vLLM version pin/dependency overrides -- install via its own script,
# same as the official Dockerfile, against the already-built tt-metal venv. Unlike the official
# Dockerfile, this COPYs a pre-built local checkout (same COPY --from=<scratch image> trick as
# TT_METAL_SRC_IMAGE above, for the same reason -- this podman has no --build-context) rather than
# git-cloning tenstorrent/vllm-tt-plugin's main branch: the GDN state-paging commits this image
# needs (MambaSpec acceptance/allocation, per-layer mamba block tables, decode-time threading --
# see docs/DESIGN_qwen36_prefix_caching.md) are local and unpushed, pending PR submission.
ARG VLLM_TT_PLUGIN_SRC_IMAGE
COPY --from=${VLLM_TT_PLUGIN_SRC_IMAGE} --chown=${CONTAINER_APP_USERNAME}:${CONTAINER_APP_USERNAME} \
    / ${vllm_tt_plugin_dir}
RUN /bin/bash -c "cd ${vllm_tt_plugin_dir} \
    && source ${PYTHON_ENV_DIR}/bin/activate \
    && uv pip install --upgrade pip \
    && source docs/install-vllm-tt.sh \
    && rm -rf ${vllm_tt_plugin_dir}/.git \
    && { uv cache clean || echo 'WARN: uv cache clean failed'; true; }"

COPY --chown=${CONTAINER_APP_USERNAME}:${CONTAINER_APP_USERNAME} \
    "vllm-tt-metal/src" "${APP_DIR}/src"
COPY --chown=${CONTAINER_APP_USERNAME}:${CONTAINER_APP_USERNAME} \
    "vllm-tt-metal/requirements.txt" "${APP_DIR}/requirements.txt"
COPY --chown=${CONTAINER_APP_USERNAME}:${CONTAINER_APP_USERNAME} \
    "utils" "${APP_DIR}/utils"
COPY --chown=${CONTAINER_APP_USERNAME}:${CONTAINER_APP_USERNAME} \
    "VERSION" "${APP_DIR}/VERSION"

RUN /bin/bash -c "source ${PYTHON_ENV_DIR}/bin/activate \
    && uv pip install --no-cache-dir -r ${APP_DIR}/requirements.txt \
    && uv cache clean" \
    && chown -R ${CONTAINER_APP_USERNAME}:${CONTAINER_APP_USERNAME} ${PYTHON_ENV_DIR} \
    && chmod -R +x ${PYTHON_ENV_DIR}/bin

USER ${CONTAINER_APP_USERNAME}

ENV TT_METAL_LOGS_PATH=/home/container_app_user/logs \
    CACHE_ROOT=/home/container_app_user/cache_root \
    MODEL_SPECS_JSON_PATH=/home/container_app_user/model_specs/model_spec.json \
    VLLM_TARGET_DEVICE=tt \
    WH_ARCH_YAML=wormhole_b0_80_arch_eth_dispatch.yaml

RUN mkdir -p ${CACHE_ROOT}
RUN mkdir -p /home/container_app_user/model_specs
COPY --chown=container_app_user:container_app_user \
    model_spec.json ${MODEL_SPECS_JSON_PATH}

WORKDIR "${APP_DIR}/src"

ENTRYPOINT ["/bin/bash", "-c", "source ${PYTHON_ENV_DIR}/bin/activate && exec python run_vllm_api_server.py \"$@\"", "--"]
