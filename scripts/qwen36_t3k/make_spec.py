"""Write a serving model_spec.json for a dense 27B checkpoint with a 2 x 128K KV pool.

usage: make_spec.py <image> <hf-model> <out.json> [kv-pool-tokens=262144]

Takes the spec baked into <image>, clones its Qwen/Qwen3.6-27B T3K entry under <hf-model> (e.g.
Qwen/Qwen3.8-27B, same architecture, different weights) and sets QWEN36_MAX_TOKENS_ALL_USERS. The
catalog's 524288 OOMs DRAM at engine start on T3K; 262144 (2 x 128K) fits, 4 x 128K does not.
"""
import json, subprocess, sys

image, model, out = sys.argv[1:4]
pool = sys.argv[4] if len(sys.argv) > 4 else "262144"
cid = subprocess.check_output(["docker", "create", image]).decode().strip()
try:
    raw = subprocess.check_output(["docker", "cp", f"{cid}:/home/container_app_user/model_specs/model_spec.json", "-"])
finally:
    subprocess.run(["docker", "rm", cid], stdout=subprocess.DEVNULL)
import io, tarfile
spec = json.load(tarfile.open(fileobj=io.BytesIO(raw)).extractfile("model_spec.json"))
base = "Qwen/Qwen3.6-27B"
entry = json.loads(json.dumps(spec["model_specs"][base]).replace(base.split("/")[1], model.split("/")[1]))
s = entry["T3K"]["vLLM"]["qwen36_blackhole"]
s["device_model_spec"]["env_vars"]["QWEN36_MAX_TOKENS_ALL_USERS"] = pool
s["env_vars"]["QWEN36_MAX_TOKENS_ALL_USERS"] = pool
spec["model_specs"][model] = entry
json.dump(spec, open(out, "w"))
print("wrote", out, s["hf_model_repo"], "pool", pool)
