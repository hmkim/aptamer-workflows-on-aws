#!/usr/bin/env python3
"""RaptGen-UI API end-to-end test (stdlib only).

Walks the same path the UI uses: Viewer -> VAE Trainer -> GMM Trainer -> Bayesian Optimization,
against the bundled RAPT1 HT-SELEX sample (initdb/RAPT1_4R.fastq of RaptGen-UI).

  e2e_api.py [--base-url http://127.0.0.1:18042] [--epochs 30] [--min-count 1] [--fastq PATH]

Run it on the UI host (SSM session) or through the SSM port forward
(--base-url http://localhost:18042 plus a local copy of the FASTQ). It creates
models named e2e-RAPT1-<epochs>ep and e2e-gmm in the UI; delete them afterwards.
Set RESUME_PUID to continue after a client-side interruption of a VAE job.
"""
import argparse, collections, json, os, sys, time, urllib.request

_ap = argparse.ArgumentParser(description="RaptGen-UI API end-to-end test")
_ap.add_argument("--base-url", default="http://127.0.0.1:18042")
_ap.add_argument("--epochs", type=int, default=30)
_ap.add_argument("--min-count", type=int, default=1)
_ap.add_argument("--fastq", default="/opt/raptgen-ui/RaptGen-UI/initdb/RAPT1_4R.fastq")
_args = _ap.parse_args()
BASE = _args.base_url.rstrip("/")
FASTQ = _args.fastq
EPOCHS = _args.epochs
T0 = time.time()


def log(step, msg):
    print(f"[{time.time()-T0:7.1f}s] {step}: {msg}", flush=True)


def call(method, path, body=None, timeout=600):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        txt = r.read().decode()
        return r.status, (json.loads(txt) if txt and txt != "null" else None)


def poll(path, done, every=10, limit=7200):
    start = time.time()
    while time.time() - start < limit:
        _, j = call("GET", path)
        if done(j):
            return j
        time.sleep(every)
    raise SystemExit(f"timeout polling {path}")


# 0. health
_, j = call("GET", "/api/train/device/process")
log("devices", j)

# 1. Viewer with bundled RAPT1 model
_, j = call("GET", "/api/data/VAE-model-names")
vae = {e["name"]: e["uuid"] for e in j["entries"]}
log("viewer.models", list(vae))
_, s = call("GET", f"/api/session/start?vae_uuid={vae['RAPT1']}")
log("viewer.session", s)
sid = s.get("uuid") if isinstance(s, dict) else s
_, enc = call("POST", "/api/session/encode", {"session_uuid": sid, "sequences": ["AUGACGGGGUCUGACGAAUUGACUCGGCACU"]})
log("viewer.encode", enc)
_, dec = call("POST", "/api/session/decode", {"session_uuid": sid, "coords_x": [0.0, 1.0], "coords_y": [0.0, -1.0]})
log("viewer.decode", dec)
call("GET", f"/api/session/end?session_uuid={sid}")

# 2. Preprocess like the VAE Trainer page
reads = []
with open(FASTQ) as f:
    for i, line in enumerate(f):
        if i % 4 == 1:
            reads.append(line.strip())
log("upload.reads", len(reads))
_, tl = call("POST", "/api/upload/estimate-target-length", {"sequences": reads})
target = tl["data"]["target_length"]
_, ad = call("POST", "/api/upload/estimate-adapters", {"sequences": reads, "target_length": target})
log("upload.estimate", {"target_length": target, "adapters": ad})
fwd, rev = ad["data"]["forward_adapter"], ad["data"]["reverse_adapter"]
rlen, tol, minc = target - len(fwd) - len(rev), 0, _args.min_count
cnt = collections.Counter()
for r in reads:
    if r.startswith(fwd) and r.endswith(rev) and abs(len(r) - target) <= tol:
        cnt[r[len(fwd):len(r) - len(rev)]] += 1
uniq = [(k, v) for k, v in cnt.items() if v >= minc]
log("upload.filter", {"random_region_length": rlen, "unique": len(uniq), "kept_reads": sum(v for _, v in uniq)})

# 3. VAE Trainer
payload = {
    "type": "RaptGen", "name": f"e2e-RAPT1-{EPOCHS}ep",
    "params_preprocessing": {"forward": fwd, "reverse": rev, "random_region_length": rlen,
                             "tolerance": tol, "minimum_count": minc},
    "random_regions": [k for k, _ in uniq], "duplicates": [v for _, v in uniq],
    "reiteration": 1,
    "params_training": {"model_length": rlen, "epochs": EPOCHS, "match_forcing_duration": min(20, EPOCHS // 2),
                        "beta_duration": min(50, EPOCHS // 2), "early_stopping": EPOCHS,
                        "seed_value": 42, "match_cost": 4, "device": "CPU"},
}
puid = os.environ.get("RESUME_PUID")
if not puid:
    _, sub = call("POST", "/api/train/jobs/submit", payload)
    puid = sub["uuid"]
log("vae.submit", puid)
t = time.time()
pj = poll(f"/api/train/jobs/items/{puid}", lambda j: j["status"] not in ("pending", "progress"), every=15)
log("vae.done", {"status": pj["status"], "wall_s": round(time.time() - t), "summary": pj.get("summary")})
if pj["status"] != "success":
    raise SystemExit("VAE training failed")
call("POST", "/api/train/jobs/publish", {"uuid": puid, "name": payload["name"]})
_, j = call("GET", "/api/data/VAE-model-names")
new_vae = {e["name"]: e["uuid"] for e in j["entries"]}[payload["name"]]
log("vae.publish", new_vae)

# 4. GMM Trainer
_, g = call("POST", "/api/gmm/jobs/submit", {"target": new_vae, "name": "e2e-gmm",
            "params": {"minimum_n_components": 2, "maximum_n_components": 6, "step_size": 2,
                       "n_trials_per_component": 2}})
guid = g["uuid"] if isinstance(g, dict) else g
log("gmm.submit", g)
t = time.time()
gj = poll(f"/api/gmm/jobs/items/{guid}", lambda j: j["status"] not in ("pending", "progress"), every=10)
log("gmm.done", {"status": gj["status"], "wall_s": round(time.time() - t),
                 "optimal_n": gj.get("gmm", {}).get("optimal_n_components")})
means = gj["gmm"]["means"]
call("POST", "/api/gmm/jobs/publish", {"uuid": guid, "n_components": gj["gmm"]["optimal_n_components"],
                                        "name": "e2e-gmm"})

# 5. Decode GMM centers, then Bayesian Optimization with made-up measured values
_, s = call("GET", f"/api/session/start?vae_uuid={new_vae}")
sid = s.get("uuid") if isinstance(s, dict) else s
xs, ys = [m[0] for m in means], [m[1] for m in means]
_, dec = call("POST", "/api/session/decode", {"session_uuid": sid, "coords_x": xs, "coords_y": ys})
log("gmm.centers.decoded", dec["sequences"])
vals = [[float(i + 1) for i in range(len(xs))]]  # placeholder "affinity" values, not real data
_, bo = call("POST", "/api/bayesopt/run", {
    "coords_x": xs, "coords_y": ys, "values": vals,
    "optimization_args": {"method_name": "qEI", "query_budget": 3},
    "distribution_args": {"xlim_min": -3.5, "xlim_max": 3.5, "ylim_min": -3.5, "ylim_max": 3.5}})
q = bo["query_data"]
_, qd = call("POST", "/api/session/decode", {"session_uuid": sid, "coords_x": q["coords_x"], "coords_y": q["coords_y"]})
log("bo.query", {"coords": list(zip(q["coords_x"], q["coords_y"])), "sequences": qd["sequences"],
                 "acq_points": len(bo["acquisition_data"]["values"])})
call("GET", f"/api/session/end?session_uuid={sid}")
log("ALL", "PASS")
