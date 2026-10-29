#!/bin/bash
# Launch the Qwen3.6/3.8-27B "slots" serving container on the T3K box and wait for /health.
#   usage: serve.sh <image> <hf-model> <spec.json> <max_model_len> <max_num_seqs> [container-name]
#   e.g.   serve.sh localhost/qwen36-35b-a3b-t3k:<tag> Qwen/Qwen3.8-27B ~/qwen36-t3k/specs/qwen3.8-27b-128k.json 131072 2
# Stops only the named container (not every running one), resets the cards, then starts it.
# Prints READY, or DIED if the container exits first. Engine logs go to ~/qwen36-t3k/logs/<name>.log.
set -u
IMAGE=$1; MODEL=$2; SPEC=$3; MML=$4; SEQS=$5; NAME=${6:-tt-38b-slots}
W=${MODEL#*/}
mkdir -p ~/qwen36-t3k/logs
docker stop "$NAME" >/dev/null 2>&1; docker rm -f "$NAME" >/dev/null 2>&1; sleep 5
source ~/.tenstorrent-venv/bin/activate; tt-smi -r >/dev/null 2>&1
docker run -d --name "$NAME" --env-file ~/.local/lib/tt-inference-server/.env --ipc host \
  --device /dev/tenstorrent:/dev/tenstorrent --mount type=bind,src=/dev/hugepages-1G,dst=/dev/hugepages-1G \
  --publish 0.0.0.0:8000:8000 --volume "volume_id_qwen36_blackhole-$W:/home/container_app_user/cache_root" \
  --mount "type=bind,src=$HOME/qwen36-t3k/weights/$W,dst=/home/container_app_user/readonly_weights_mount/$W,readonly" \
  --mount "type=bind,src=$SPEC,dst=/home/container_app_user/model_specs/model_spec.json,readonly" \
  -e "MODEL_WEIGHTS_DIR=/home/container_app_user/readonly_weights_mount/$W" \
  "$IMAGE" --model "$MODEL" --tt-device t3k \
  --block-size 64 --max-model-len "$MML" --max-num-seqs "$SEQS" --max-num-batched-tokens "$MML" >/dev/null 2>&1
(docker logs -f "$NAME" > ~/qwen36-t3k/logs/"$NAME".log 2>&1 &)
for i in $(seq 1 120); do
  curl -s -o /dev/null -w "%{http_code}" localhost:8000/health | grep -q 200 && { echo READY; exit 0; }
  docker ps -q -f name="$NAME" | grep -q . || { echo DIED; exit 1; }
  sleep 15
done
echo TIMEOUT; exit 1
