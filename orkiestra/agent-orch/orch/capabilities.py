import json, subprocess, threading, time, tomllib
from pathlib import Path
from . import db

_cache = {"t": 0, "v": None}
_lock = threading.Lock()
TTL = 300  # 5 minutes


def _claude_capabilities():
    rows = db.q("""SELECT text FROM events
                   WHERE kind='out' AND (text LIKE '{"type":"system","subtype":"init"%'
                                         OR text LIKE '{"type": "system", "subtype": "init"%')
                   ORDER BY id DESC LIMIT 1""")
    if not rows:
        return {"skills": [], "plugins": [], "mcp_servers": [], "permissionMode": None}
    try:
        data = json.loads(rows[0]["text"])
    except (ValueError, TypeError):
        return {"skills": [], "plugins": [], "mcp_servers": [], "permissionMode": None}

    raw_skills = data.get("skills") or []
    skills = [s if isinstance(s, str) else s.get("name", "") for s in raw_skills]

    raw_plugins = data.get("plugins") or []
    plugins = [p if isinstance(p, str) else p.get("name", "") for p in raw_plugins]

    raw_mcp = data.get("mcp_servers") or []
    mcp_servers = []
    if isinstance(raw_mcp, list):
        for s in raw_mcp:
            if isinstance(s, dict):
                item = {"name": s.get("name", "")}
                if "status" in s:
                    item["status"] = s["status"]
                mcp_servers.append(item)
            elif isinstance(s, str):
                mcp_servers.append({"name": s})
    elif isinstance(raw_mcp, dict):
        for k, v in raw_mcp.items():
            item = {"name": k}
            if isinstance(v, dict) and "status" in v:
                item["status"] = v["status"]
            elif isinstance(v, str):
                item["status"] = v
            mcp_servers.append(item)

    return {
        "skills": skills,
        "plugins": plugins,
        "mcp_servers": mcp_servers,
        "permissionMode": data.get("permissionMode"),
    }


def _codex_capabilities():
    cfg_path = Path.home() / ".codex" / "config.toml"
    if not cfg_path.is_file():
        return {"plugins": [], "mcp_servers": []}
    try:
        with open(cfg_path, "rb") as f:
            data = tomllib.load(f)
    except Exception:
        return {"plugins": [], "mcp_servers": []}

    plugins = []
    raw_plugins = data.get("plugins")
    if isinstance(raw_plugins, dict):
        for k, v in raw_plugins.items():
            item = {"name": k}
            if isinstance(v, dict) and "enabled" in v:
                item["enabled"] = bool(v["enabled"])
            elif isinstance(v, bool):
                item["enabled"] = v
            plugins.append(item)

    mcp_servers = []
    raw_mcp = data.get("mcp_servers")
    if isinstance(raw_mcp, dict):
        mcp_servers = list(raw_mcp.keys())
    elif isinstance(raw_mcp, list):
        mcp_servers = [s if isinstance(s, str) else s.get("name", "") for s in raw_mcp]

    return {"plugins": plugins, "mcp_servers": mcp_servers}


def _parse_agy_list(out, empty_marker):
    text = (out or "").strip()
    if not text or empty_marker.lower() in text.lower():
        return []
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    return [l for l in lines if empty_marker.lower() not in l.lower()]


def _agy_capabilities():
    try:
        r_p = subprocess.run(["agy", "plugin", "list"], capture_output=True, text=True,
                             timeout=20, stdin=subprocess.DEVNULL)
        r_m = subprocess.run(["agy", "mcp", "list"], capture_output=True, text=True,
                             timeout=20, stdin=subprocess.DEVNULL)
    except FileNotFoundError:
        return {"error": "cli not installed"}
    except Exception as e:
        return {"error": str(e)}

    if r_p.returncode == 127 or "command not found" in (r_p.stderr or "").lower():
        return {"error": "cli not installed"}

    plugins = _parse_agy_list(r_p.stdout, "No plugins installed.")
    mcp = _parse_agy_list(r_m.stdout, "No MCP servers configured.")
    return {"plugins": plugins, "mcp_servers": mcp}


def capabilities(force=False):
    with _lock:
        if not force and _cache["v"] is not None and (time.time() - _cache["t"] < TTL):
            return _cache["v"]
        val = {
            "claude": _claude_capabilities(),
            "codex": _codex_capabilities(),
            "agy": _agy_capabilities(),
        }
        _cache["t"] = time.time()
        _cache["v"] = val
        return val


def suggestions():
    from .suggestions import suggestions as _sug
    return _sug()

