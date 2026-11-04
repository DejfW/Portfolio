import json, urllib.request
from .config import CFG


def chat_json(system, user, schema, retries=2):
    """Ask the local model for JSON constrained by `schema`."""
    body = {
        "model": CFG["model"], "stream": False, "think": False, "format": schema,
        "options": {"temperature": 0.2, "num_ctx": CFG["ollama_ctx"]},
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
    }
    last = None
    for _ in range(retries + 1):
        req = urllib.request.Request(CFG["ollama_url"] + "/api/chat", json.dumps(body).encode(),
                                     {"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=600) as r:
                return json.loads(json.loads(r.read())["message"]["content"])
        except Exception as e:  # network or malformed JSON: retry
            last = e
    raise RuntimeError(f"local model failed: {last}")
