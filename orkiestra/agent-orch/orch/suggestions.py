from . import db, probe
from .capabilities import capabilities
from .config import CFG


def suggestions():
    items = []

    # Unavailable profiles with their reason (high severity)
    # one item per reason, so a missing CLI does not push everything else out of the list
    checked = probe.check()
    by_reason = {}
    for name, info in checked.items():
        if not info.get("ok"):
            by_reason.setdefault(info.get("reason") or "unavailable", []).append(name)
    for reason, names in by_reason.items():
        items.append({
            "kind": "profile",
            "title": f"Profile {names[0]} is unavailable" if len(names) == 1
            else f"{len(names)} profiles are unavailable: {reason}",
            "detail": reason if len(names) == 1 else ", ".join(names),
            "action": None,
            "_priority": 1,
        })

    # Quota pools with quota_left < 0.2 from probe.check()
    pool_quotas = {}
    for name, info in checked.items():
        pool = CFG["profiles"].get(name, {}).get("pool") or info.get("pool") or name
        q_left = info.get("quota_left")
        if q_left is not None:
            if pool not in pool_quotas or q_left < pool_quotas[pool]:
                pool_quotas[pool] = q_left
    for pool, left in pool_quotas.items():
        if left < 0.2:
            items.append({
                "kind": "quota",
                "title": f"Low quota for pool {pool}",
                "detail": f"Remaining quota: {round(left * 100)}%",
                "action": None,
                "_priority": 2,
            })

    # Claude MCP servers whose status means they need authentication
    caps = capabilities()
    claude_mcp = caps.get("claude", {}).get("mcp_servers", [])
    for s in claude_mcp:
        status = str(s.get("status") or "").lower()
        if "auth" in status or status in ("unauthenticated", "login_required", "unauthorized"):
            items.append({
                "kind": "mcp",
                "title": f"Claude MCP server '{s.get('name')}' needs authentication",
                "detail": f"Status: {s.get('status')}. Authentication required.",
                "action": None,
                "_priority": 3,
            })

    # Failed runs that can be resumed (action {"type":"resume","run":id})
    failed_runs = db.q("SELECT id, goal, summary FROM runs WHERE status='failed' ORDER BY id DESC")
    for r in failed_runs:
        items.append({
            "kind": "run",
            "title": f"Resume failed run #{r['id']}",
            "detail": r["summary"] or r["goal"] or f"Run #{r['id']} failed",
            "action": {"type": "resume", "run": r["id"]},
            "_priority": 4,
            "_id": r["id"],
        })

    # Profiles with >=3 work attempts and accepted rate < 50% (from db.stats())
    prof_stats = {}
    for row in db.stats():
        p = row["profile"]
        if p not in prof_stats:
            prof_stats[p] = {"n": 0, "accepted": 0}
        prof_stats[p]["n"] += int(row.get("n") or 0)
        prof_stats[p]["accepted"] += int(row.get("accepted") or 0)
    for p, st in prof_stats.items():
        if st["n"] >= 3 and (st["accepted"] / st["n"]) < 0.5:
            pct = round(st["accepted"] / st["n"] * 100)
            items.append({
                "kind": "profile",
                "title": f"Profile {p} has low success rate",
                "detail": f"{st['accepted']}/{st['n']} attempts accepted ({pct}%)",
                "action": None,
                "_priority": 5,
            })

    # Return at most 8, most important first
    items.sort(key=lambda x: (x.get("_priority", 99), -x.get("_id", 0)))
    result = []
    for it in items[:8]:
        result.append({
            "kind": it["kind"],
            "title": it["title"],
            "detail": it["detail"],
            "action": it["action"],
        })
    return result
