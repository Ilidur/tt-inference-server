"""Serving tests for the Qwen3.6/3.8-27B T3K container.

usage: test_long_context.py <jwt> <served-model-name> [suite]
  a  Hermes 17k-token tool-call replay x3 (needs the captured request, see FIXTURE)
  b  needle recall at 32k/64k/100k/125k
  c  padded tool calls at 64k and 120k
  d  two concurrent 60k requests
  e  105k/118k tool calls + 125k needles
  f  temperature-0 determinism of identical requests at 300-6000 tokens (use-after-free regression)
  g  streaming: reasoning stays in `reasoning`, answer in `content`, tools come back as tool_calls
  soak  N back-to-back ~115k tool-call prefills (SOAK_N, default 10) -- exposes the intermittent fabric hang
FIXTURE: path to a captured tool-heavy chat request (env FIXTURE, default ~/qwen36-t3k/test_fixtures/last_tools_req.json).
"""
import json, os, sys, time, random, threading, urllib.request
FIXTURE = os.environ.get("FIXTURE", os.path.expanduser("~/qwen36-t3k/test_fixtures/last_tools_req.json"))
TOK = sys.argv[1]; MODEL = sys.argv[2]; BASE = "http://localhost:8000"
H = {"Content-Type": "application/json", "Authorization": "Bearer " + TOK}
def post(path, body, timeout=1800):
    r = urllib.request.Request(BASE + path, json.dumps(body).encode(), H)
    return json.load(urllib.request.urlopen(r, timeout=timeout))
def ntok(text):
    return post("/tokenize", {"model": MODEL, "prompt": text})["count"]
rnd = random.Random(7)
def line(i): return f"Record {i:06d}: id={rnd.getrandbits(32):08x} status={rnd.choice(['ok','ok','warn','retry'])} note={rnd.choice(['alpha','bravo','delta','sierra','tango'])}-{rnd.randint(100,999)}\n"
_lines = [line(i) for i in range(12000)]
def filler(target):
    lo, hi = 10, len(_lines)
    while lo < hi:
        mid = (lo + hi) // 2
        if ntok("".join(_lines[:mid])) < target: lo = mid + 1
        else: hi = mid
    return _lines[:lo]
def needle_case(target, depth, tag):
    code = f"{rnd.choice(['ZEBRA','FALCON','OTTER','MAPLE'])}-{rnd.randint(1000,9999)}"
    ls = filler(target)
    ls.insert(int(len(ls) * depth), f"IMPORTANT: The vault passcode is {code}.\n")
    msg = "".join(ls) + "\nQuestion: What is the vault passcode mentioned in the records above? Answer with just the passcode."
    t = time.time()
    try:
        o = post("/v1/chat/completions", {"model": MODEL, "messages": [{"role": "user", "content": msg}], "max_tokens": 60, "temperature": 0, "chat_template_kwargs": {"enable_thinking": False}})
        ans = o["choices"][0]["message"].get("content") or ""
        res = "PASS" if code in ans else "FAIL"
        return f"{tag} needle target={target} depth={depth} prompt={o['usage']['prompt_tokens']} {res} (want {code}, got {ans.strip()[:40]!r}) {round(time.time()-t)}s"
    except Exception as e:
        return f"{tag} needle target={target} depth={depth} ERROR {repr(e)[:150]} {round(time.time()-t)}s"
def tool_case(target, tag):
    j = json.load(open(FIXTURE)); j["model"] = MODEL; j["max_tokens"] = 1500; j["stream"] = False; j.pop("stream_options", None)
    base = ntok(json.dumps(j["messages"]))
    if target > base:
        j["messages"].insert(1, {"role": "user", "content": "Reference records (ignore):\n" + "".join(filler(target - base))})
    t = time.time()
    try:
        o = post("/v1/chat/completions", j); c = o["choices"][0]
        n = len(c["message"].get("tool_calls") or [])
        return f"{tag} toolcall target={target} prompt={o['usage']['prompt_tokens']} finish={c['finish_reason']} tool_calls={n} {'PASS' if n else 'FAIL'} {round(time.time()-t)}s"
    except Exception as e:
        return f"{tag} toolcall target={target} ERROR {repr(e)[:150]} {round(time.time()-t)}s"
def out(s): print(s, flush=True)
suite = sys.argv[3] if len(sys.argv) > 3 else "all"
if suite in ("all", "a"):
    for i in range(3): out(tool_case(0, f"A{i}"))
if suite in ("all", "b"):
    for tgt, d in [(32000, .5), (64000, .05), (100000, .5), (125000, .05), (125000, .95)]: out(needle_case(tgt, d, "B"))
if suite in ("all", "c"):
    for tgt in (64000, 64000, 120000, 120000): out(tool_case(tgt, "C"))
if suite in ("all", "d"):
    res = []
    th = [threading.Thread(target=lambda k=k: res.append(needle_case(60000, .5 if k else .1, f"D{k}"))) for k in range(2)]
    [x.start() for x in th]; [x.join() for x in th]; [out(r) for r in res]
if suite == "e":
    for tgt in (105000, 105000, 118000, 118000): out(tool_case(tgt, "E"))
    for tgt, d in [(125000, .5), (125000, .5), (125000, .25)]: out(needle_case(tgt, d, "E"))
if suite == "f":
    # identical temp-0 requests must give identical text; the conv1d use-after-free made them differ
    # once a prompt carried conv_state across a chunk boundary (cliff at ~300 tokens).
    for tgt in (300, 800, 1500, 3000, 6000):
        ls = filler(tgt); msg = "".join(ls) + "\nSummarize the records above in one sentence."
        outs = []
        for _ in range(6):
            o = post("/v1/chat/completions", {"model": MODEL, "messages": [{"role": "user", "content": msg}], "max_tokens": 80, "temperature": 0, "chat_template_kwargs": {"enable_thinking": False}})
            outs.append(o["choices"][0]["message"].get("content") or "")
        u = len(set(outs)); out(f"F determinism target={tgt} unique_outputs={u}/6 {'PASS' if u == 1 else 'FAIL'}")
if suite == "g":
    def stream(body):
        r = urllib.request.Request(BASE + "/v1/chat/completions", json.dumps(body).encode(), H)
        reas = cont = ""; calls = 0
        for ln in urllib.request.urlopen(r, timeout=900):
            ln = ln.decode().strip()
            if not ln.startswith("data:") or ln.endswith("[DONE]"): continue
            c = json.loads(ln[5:])
            if not c.get("choices"): continue
            d = c["choices"][0]["delta"]
            reas += d.get("reasoning") or d.get("reasoning_content") or ""; cont += d.get("content") or ""
            calls += len(d.get("tool_calls") or [])
        return reas, cont, calls
    reas, cont, _ = stream({"model": MODEL, "stream": True, "max_tokens": 1500, "messages": [{"role": "user", "content": "What is 17*23? Think briefly then answer."}]})
    out(f"G reasoning/content split: reasoning={len(reas)}ch content={len(cont)}ch leaked_think_tag={'<think>' in cont or '</think>' in cont} {'PASS' if cont.strip() and '</think>' not in cont else 'FAIL'}")
    tools = [{"type": "function", "function": {"name": "get_weather", "description": "Get weather for a city", "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}]
    reas, cont, n = stream({"model": MODEL, "stream": True, "max_tokens": 1500, "tools": tools, "tool_choice": "auto", "messages": [{"role": "user", "content": "What's the weather in Paris right now? Use the tool."}]})
    out(f"G streamed tool call: tool_calls={n} raw_markup_in_content={'<tool_call>' in cont} {'PASS' if n and '<tool_call>' not in cont else 'FAIL'}")
if suite == "soak":
    n = int(os.environ.get("SOAK_N", "10")); ok = 0
    for i in range(n):
        r = tool_case(115000, f"SOAK{i}"); out(r)
        if "PASS" not in r: break
        ok += 1
    out(f"SOAK completed {ok}/{n} before first failure")
out("DONE")
