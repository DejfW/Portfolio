import json, os, tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULTS = {
    "ollama_url": "http://localhost:11434",
    "model": "qwen3:8b",
    "max_parallel": 3,
    "max_attempts": 3,
    "agent_timeout": 1800,
    "agent_idle_timeout": 600,   # kill an agent that printed nothing for this many seconds (0 = off)
    "ollama_ctx": 32768,         # context for the local model; Ollama's small default silently drops input
    "judge_diff_chars": 24000,   # diff budget for the judge; larger diffs are abbreviated per file/hunk
    "retry_from_previous": True, # a rejected attempt's branch is the next attempt's starting point
    "review_for": ["hard"],      # difficulties that also get a review by an agent of another vendor
    "review_profiles": ["claude-sonnet-med", "codex-sol-med", "claude-opus-high"],
    "run_budget": 40,            # max sum of profile `cost` spent per run execution (0 = unlimited)
    "run_max_minutes": 240,      # wall-clock limit per run execution (0 = unlimited)
    # install commands the New project page may run (from a model's recommendation, after the user confirms)
    "install_allow": ["claude mcp add", "claude mcp add-json", "claude plugin install", "codex mcp add",
                      "agy mcp add", "agy plugin install", "npx skills add", "npm install -g", "npm i -g",
                      "pip install", "pip3 install", "pipx install", "uv tool install", "brew install"],
    "db_path": str(ROOT / "orch.db"),
    "host": "127.0.0.1",
    "port": 8765,
    "profiles": {},
}


def load():
    cfg = dict(DEFAULTS)
    p = ROOT / "orch.toml"
    if p.exists():
        cfg.update(tomllib.loads(p.read_text()))
    for k in DEFAULTS:
        v = os.environ.get("ORCH_" + k.upper())
        if v is None or isinstance(DEFAULTS[k], (list, dict)):
            continue
        cfg[k] = v.lower() in ("1", "true", "yes") if isinstance(DEFAULTS[k], bool) else type(DEFAULTS[k])(v)
    for name, p in cfg["profiles"].items():
        missing = {"agent", "model", "tier", "cost", "good"} - set(p)
        if missing or p["agent"] not in ("claude", "codex", "agy"):
            raise ValueError(f"bad profile {name}: {missing or p['agent']}")
        # usage-limit pool: profiles sharing one quota (default: the whole agent CLI). Parallelism and
        # "limit hit -> unavailable" both work per pool.
        p.setdefault("pool", p["agent"])
    if not cfg["profiles"]:
        raise ValueError("orch.toml defines no [profiles.*]")
    return cfg


CFG = load()
