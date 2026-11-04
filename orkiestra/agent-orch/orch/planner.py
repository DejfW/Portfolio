import re
from . import llm, router
from .config import CFG

_FILE = re.compile(r"[\w./-]*\w\.[A-Za-z]\w{1,5}\b")

SCHEMA = {
    "type": "object",
    "properties": {"tasks": {"type": "array", "items": {
        "type": "object",
        "properties": {
            "key": {"type": "string"}, "title": {"type": "string"}, "prompt": {"type": "string"},
            "category": {"type": "string", "enum": router.CATEGORIES},
            "difficulty": {"type": "string", "enum": router.DIFFICULTIES},
            "depends_on": {"type": "array", "items": {"type": "string"}},
            "acceptance": {"type": "string"}},
        "required": ["key", "title", "prompt", "category", "difficulty", "depends_on", "acceptance"]}}},
    "required": ["tasks"],
}


Q_SCHEMA = {"type": "object", "properties": {"questions": {"type": "array", "maxItems": 4, "items": {
    "type": "object", "properties": {"question": {"type": "string"},
                                     "options": {"type": "array", "items": {"type": "string"}}},
    "required": ["question", "options"]}}}, "required": ["questions"]}


def questions(goal, repo_listing):
    """Clarifying questions for the user before planning (opt-in). Only questions whose answer would
    change the plan; an empty list when the goal is clear enough."""
    system = (
        "You prepare work for coding agents. Before the goal is split into tasks, list at most 4 short "
        "questions for the user whose answers would change WHAT gets built or HOW it is split (scope, "
        "target files, behaviour, constraints, acceptance). Do not ask what you can see in the file list, "
        "do not ask about style trivia, and return an empty list when the goal is already clear. For each "
        "question give 2-4 likely answers as options (or an empty list for a free-text answer). "
        "Write the questions in the same language as the goal.")
    out = llm.chat_json(system, f"Repository files:\n{repo_listing}\n\nGoal:\n{goal}", Q_SCHEMA)
    res = []
    for q in out.get("questions", [])[:4]:
        text = str(q.get("question", "")).strip()
        if text:
            res.append({"question": text, "options": [str(o) for o in q.get("options", []) if str(o).strip()][:4]})
    return res


def with_answers(goal, qa):
    """The goal the planner sees once the user answered: answers are binding clarifications."""
    lines = [f"Q: {x['question']}\nA: {x['answer']}" for x in qa if str(x.get("answer", "")).strip()]
    return goal + ("\n\nClarifications from the user (binding):\n" + "\n".join(lines) if lines else "")


def plan(goal, repo_listing, available):
    system = (
        "You are a dispatcher for coding agents. Split the goal into the FEWEST independent subtasks "
        "(max 6) that can run in parallel in separate git worktrees; use depends_on only when a task "
        "truly needs another's output. Tasks that edit the same file must be ONE task (or chained with "
        "depends_on); a small goal is a single task. Each prompt must be self-contained, name concrete files, and "
        "never assume the agent saw the goal. Acceptance is one checkable sentence. Keys are short "
        "slugs (t1, t2, ...). Do NOT choose an agent or model; instead classify each task:\n"
        "category: implement (new feature code), refactor (restructure existing code), debug (find/fix a "
        "bug), tests (write tests), ui (frontend/HTML/CSS), review, simple (boilerplate, config, docs).\n"
        "difficulty: easy (one small file, obvious), medium (a few files, some design), "
        "hard (many files, subtle logic, architecture).")
    out = llm.chat_json(system, f"Repository files:\n{repo_listing}\n\nGoal:\n{goal}", SCHEMA)
    return normalize(out.get("tasks", []), available)


def normalize(tasks, available=None):
    """Make a model-produced (or user-edited) plan safe: unique keys, valid deps (acyclic), and a
    profile for every task (a valid user-forced `profile` is kept, otherwise the router picks)."""
    avail = list(available) if available is not None else list(CFG["profiles"])
    seen, res, load = set(), [], {}
    for i, t in enumerate(tasks):
        key = (t.get("key") or f"t{i+1}").strip().replace(" ", "-")
        if key in seen:
            key = f"{key}-{i+1}"
        seen.add(key)
        cat = t.get("category") if t.get("category") in router.CATEGORIES else "implement"
        diff = t.get("difficulty") if t.get("difficulty") in router.DIFFICULTIES else "medium"
        prof = t.get("profile")
        if prof not in CFG["profiles"]:
            prof = router.pick(cat, diff, avail, load=load) or next(iter(CFG["profiles"]))
        agent, pool = CFG["profiles"][prof]["agent"], CFG["profiles"][prof]["pool"]
        load[pool] = load.get(pool, 0) + 1
        res.append({"key": key, "title": t.get("title") or key, "prompt": t.get("prompt", ""),
                    "category": cat, "difficulty": diff, "profile": prof, "agent": agent,
                    "depends_on": list(t.get("depends_on") or []), "acceptance": t.get("acceptance", "")})
    keys = {t["key"] for t in res}
    done = set()
    for _ in range(len(res) + 1):  # drop unknown deps and anything that stays cyclic
        for t in res:
            t["depends_on"] = [d for d in t["depends_on"] if d in keys and d != t["key"]]
            if all(d in done for d in t["depends_on"]):
                done.add(t["key"])
    for t in res:
        if t["key"] not in done:
            t["depends_on"] = []
    _chain_shared_files(res)
    return res


def _chain_shared_files(res):
    """Parallel tasks editing the same file end in merge conflicts: when two unrelated tasks name the same
    file, the later one waits for the earlier one (deterministic, keeps the plan acyclic)."""
    files = [{m.rsplit("/", 1)[-1].lower() for m in _FILE.findall(t["prompt"] + " " + t["title"])} for t in res]
    by_key = {t["key"]: t for t in res}

    def reaches(a, b):  # does task a (transitively) depend on task b?
        stack, seen = [a], set()
        while stack:
            k = stack.pop()
            if k == b:
                return True
            if k not in seen:
                seen.add(k)
                stack.extend(by_key[k]["depends_on"])
        return False

    for j, later in enumerate(res):
        for i in range(j - 1, -1, -1):  # nearest earlier task first keeps the chain short
            if files[i] & files[j] and not reaches(later["key"], res[i]["key"]) \
                    and not reaches(res[i]["key"], later["key"]):
                later["depends_on"].append(res[i]["key"])
