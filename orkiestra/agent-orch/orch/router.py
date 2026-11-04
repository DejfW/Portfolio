"""Deterministic profile routing. The local LLM only classifies (category, difficulty);
this module chooses the profile, so an 8B model never has to pick among many options."""
from .config import CFG

REQUIRED_TIER = {"easy": 1, "medium": 3, "hard": 4}
CATEGORIES = ["implement", "refactor", "debug", "tests", "ui", "review", "simple"]
DIFFICULTIES = list(REQUIRED_TIER)


def pick(category, difficulty, available, exclude=(), load=None):
    """Cheapest available profile that is strong enough and good at `category`.
    Relaxes the category, then the tier, rather than returning nothing."""
    profs, load = CFG["profiles"], load or {}
    need = REQUIRED_TIER.get(difficulty, 3)
    pool = [n for n in available if n in profs and n not in exclude]
    key = lambda n: (profs[n]["cost"], load.get(profs[n]["pool"], 0), n)
    for ok in (lambda p: category in p["good"] and p["tier"] >= need, lambda p: p["tier"] >= need):
        cands = [n for n in pool if ok(profs[n])]
        if cands:
            return min(cands, key=key)
    return max(pool, key=lambda n: (profs[n]["tier"], -profs[n]["cost"], n)) if pool else None


def escalate(current, tried, available, category):
    """Next profile after a failed attempt: same agent one tier up first, then another agent
    at >= the current tier (preferring ones good at the category). None when exhausted."""
    profs = CFG["profiles"]
    pool = [n for n in available if n in profs and n not in tried]
    cur = profs.get(current)
    if not cur:
        return pick(category, "hard", pool)
    same = [n for n in pool if profs[n]["agent"] == cur["agent"] and profs[n]["tier"] > cur["tier"]]
    if same:
        return min(same, key=lambda n: (profs[n]["tier"], profs[n]["cost"], n))
    other = [n for n in pool if profs[n]["tier"] >= cur["tier"]]
    pref = [n for n in other if category in profs[n]["good"]] or other
    return min(pref, key=lambda n: (profs[n]["cost"], n)) if pref else None
