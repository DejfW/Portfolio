"""Which profiles can actually run right now (CLI installed, logged in, model offered)."""
import json, subprocess, threading, time
from .config import CFG

_cache = {"t": 0, "v": {}}
_lock = threading.Lock()
TTL = 60


def _run(cmd):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=45, stdin=subprocess.DEVNULL)
        return r.returncode, (r.stdout + r.stderr)
    except FileNotFoundError:
        return None, "cli not installed"
    except Exception as e:
        return None, str(e)


def _agent_status():
    """agent -> (set of model ids offered or None for 'unknown but ok', failure reason or '')."""
    st = {}
    rc, out = _run(["claude", "auth", "status"])
    try:
        st["claude"] = (None, "" if json.loads(out).get("loggedIn") else "not logged in")
    except ValueError:
        st["claude"] = (None, out.strip()[:80] if rc is None else "auth status unreadable")
    rc, out = _run(["codex", "login", "status"])
    if rc is None or "not logged in" in out.lower():
        st["codex"] = (None, "cli not installed" if rc is None else "not logged in (run `codex login`)")
    else:
        rc, out = _run(["codex", "debug", "models"])
        try:
            st["codex"] = ({m["slug"] for m in json.loads(out).get("models", [])}, "")
        except ValueError:
            st["codex"] = (None, "")
    rc, out = _run(["agy", "models"])
    if rc is None:
        st["agy"] = (None, out)
    else:
        ids = {l.split("\t")[0].strip() for l in out.splitlines() if "\t" in l}
        st["agy"] = (ids, "" if ids else "no models listed (not logged in?)")
    return st


def _agy_pool(bucket_id):
    if bucket_id.startswith("gemini-argon"):
        return "agy-argon"
    if bucket_id.startswith("3p"):
        return "agy-3p"
    return "agy-gemini" if bucket_id.startswith("gemini") else None


def _agy_quota():
    """pool -> (lowest remaining fraction over its 5h/weekly buckets, reset time of that bucket), from
    `agy -p /usage`, which reports agy's real quota groups without spending any quota."""
    rc, out = _run(["agy", "-p", "/usage", "--output-format", "json"])
    try:
        j = json.loads(out[out.find("{"):out.rfind("}") + 1])
    except ValueError:
        return {}
    stack, groups = [j], []
    while stack and not groups:  # the groups list sits a few levels deep; find it without hardcoding
        o = stack.pop()
        if isinstance(o, dict):
            groups = o.get("groups") if isinstance(o.get("groups"), list) else []
            stack.extend(o.values())
        elif isinstance(o, list):
            stack.extend(o)
    q = {}
    for g in groups:
        for b in g.get("buckets", []):
            pool, left = _agy_pool(str(b.get("id", ""))), b.get("remaining_fraction")
            if pool and isinstance(left, (int, float)) and (pool not in q or left < q[pool][0]):
                q[pool] = (float(left), b.get("reset_time", ""))
    return q


def check(force=False):
    """profile name -> {"ok": bool, "reason": str}, cached for TTL seconds."""
    with _lock:
        if not force and time.time() - _cache["t"] < TTL and _cache["v"]:
            return _cache["v"]
        st, res = _agent_status(), {}
        quota = _agy_quota() if not st["agy"][1] else {}
        for name, p in CFG["profiles"].items():
            models, err = st[p["agent"]]
            left, reset = quota.get(p["pool"], (None, ""))
            if err:
                res[name] = {"ok": False, "reason": err}
            elif models is not None and p["model"] not in models:
                res[name] = {"ok": False, "reason": f"model {p['model']} not offered"}
            elif left is not None and left <= 0:
                res[name] = {"ok": False, "reason": f"{p['pool']} quota used up (resets {reset})"}
            else:
                res[name] = {"ok": True, "reason": ""}
            res[name]["quota_left"] = left
        _cache.update(t=time.time(), v=res)
        return res


def available(force=False):
    return [n for n, v in check(force).items() if v["ok"]]
