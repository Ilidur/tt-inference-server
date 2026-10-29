#!/bin/bash
# Launch a Qwen3.6/3.8 T3K serving container and wait for /health.
#   usage: serve.sh <image> <hf-model> [container-name]
#   e.g.   serve.sh localhost/qwen36-35b-a3b-t3k:<tag> Qwen/Qwen3.8-27B
# Context length, sequence count and KV pool come from the model's T3K entry in the catalog baked into
# the image (workflows/model_specs/dev/llm.yaml), so there is nothing to pass or generate here.
# Weights are read from ~/qwen36-t3k/weights/<model name>. Stops only the named container (not every
# running one), resets the cards, then starts it. Prints READY, or DIED/TIMEOUT. Engine log:
# ~/qwen36-t3k/logs/<name>.log.
set -u
IMAGE=$1; MODEL=$2; NAME=${3:-tt-38b-slots}
W=${MODEL#*/}
mkdir -p ~/qwen36-t3k/logs
docker stop "$NAME" >/dev/null 2>&1; docker rm -f "$NAME" >/dev/null 2>&1; sleep 5
source ~/.tenstorrent-venv/bin/activate; tt-smi -r >/dev/null 2>&1
docker run -d --name "$NAME" --env-file ~/.local/lib/tt-inference-server/.env --ipc host \
  --device /dev/tenstorrent:/dev/tenstorrent --mount type=bind,src=/dev/hugepages-1G,dst=/dev/hugepages-1G \
  --publish 0.0.0.0:8000:8000 --volume "volume_id_qwen36_blackhole-$W:/home/container_app_user/cache_root" \
  --mount "type=bind,src=$HOME/qwen36-t3k/weights/$W,dst=/home/container_app_user/readonly_weights_mount/$W,readonly" \
  -e "MODEL_WEIGHTS_DIR=/home/container_app_user/readonly_weights_mount/$W" \
  "$IMAGE" --model "$MODEL" --tt-device t3k >/dev/null 2>&1
(docker logs -f "$NAME" > ~/qwen36-t3k/logs/"$NAME".log 2>&1 &)
for i in $(seq 1 120); do
  curl -s -o /dev/null -w "%{http_code}" localhost:8000/health | grep -q 200 && { echo READY; exit 0; }
  docker ps -q -f name="$NAME" | grep -q . || { echo DIED; exit 1; }
  sleep 15
done
echo TIMEOUT; exit 1
