import datetime, json, sqlite3, threading, time
from .config import CFG

_lock = threading.RLock()
_conn = sqlite3.connect(CFG["db_path"], check_same_thread=False)
_conn.row_factory = sqlite3.Row
_conn.executescript("""
CREATE TABLE IF NOT EXISTS runs(id INTEGER PRIMARY KEY AUTOINCREMENT, repo TEXT, goal TEXT,
  test_cmd TEXT, status TEXT, summary TEXT, created REAL);
CREATE TABLE IF NOT EXISTS tasks(id INTEGER PRIMARY KEY AUTOINCREMENT, run_id INTEGER, key TEXT,
  title TEXT, prompt TEXT, agent TEXT, depends_on TEXT, acceptance TEXT, status TEXT,
  attempts INTEGER DEFAULT 0, tried TEXT DEFAULT '[]', summary TEXT, UNIQUE(run_id, key));
CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY AUTOINCREMENT, run_id INTEGER,
  task_key TEXT, kind TEXT, text TEXT, ts REAL);
CREATE TABLE IF NOT EXISTS projects(id INTEGER PRIMARY KEY AUTOINCREMENT, description TEXT, status TEXT,
  profile TEXT, report TEXT, created REAL);
CREATE TABLE IF NOT EXISTS attempts(id INTEGER PRIMARY KEY AUTOINCREMENT, run_id INTEGER, task_key TEXT,
  attempt INTEGER, role TEXT, profile TEXT, category TEXT, difficulty TEXT, started REAL, duration REAL,
  exit INTEGER, outcome TEXT, reason TEXT, out_tokens INTEGER, cost_usd REAL);
""")

_MIGRATIONS = [("tasks", "category TEXT DEFAULT 'implement'"), ("tasks", "difficulty TEXT DEFAULT 'medium'"),
               ("tasks", "profile TEXT DEFAULT ''"), ("tasks", "prev_branch TEXT DEFAULT ''"),
               ("runs", "questions TEXT DEFAULT ''")]  # runs.questions: JSON [{question, options, answer}]
for _table, _col in _MIGRATIONS:
    try:
        _conn.execute(f"ALTER TABLE {_table} ADD COLUMN {_col}")
    except sqlite3.OperationalError:  # already migrated
        pass
_conn.commit()


def q(sql, args=()):
    with _lock:
        return [dict(r) for r in _conn.execute(sql, args).fetchall()]


def x(sql, args=()):
    with _lock:
        cur = _conn.execute(sql, args)
        _conn.commit()
        return cur.lastrowid


def event(run_id, task_key, kind, text):
    return x("INSERT INTO events(run_id,task_key,kind,text,ts) VALUES(?,?,?,?,?)",
             (run_id, task_key, kind, text, time.time()))


def run_tasks(run_id):
    rows = q("SELECT * FROM tasks WHERE run_id=? ORDER BY id", (run_id,))
    for r in rows:
        r["depends_on"] = json.loads(r["depends_on"] or "[]")
        r["tried"] = json.loads(r["tried"] or "[]")
    return rows


def stats():
    """Per profile x category x difficulty: how often its work attempts were accepted, and what they took."""
    return q("""SELECT profile, category, difficulty, COUNT(*) AS n,
                SUM(outcome='done') AS accepted, ROUND(AVG(duration)) AS avg_s,
                ROUND(AVG(out_tokens)) AS avg_out_tokens, ROUND(SUM(cost_usd), 2) AS usd
                FROM attempts WHERE role='work' AND outcome NOT IN ('unavailable', 'cancelled')
                GROUP BY profile, category, difficulty ORDER BY profile, category, difficulty""")


def overview(days=14):
    """Aggregate KPIs, daily activity series, and task statuses for the dashboard."""
    days = max(1, int(days))
    runs_row = q("""SELECT COUNT(*) AS total,
                           SUM(status = 'done') AS done,
                           SUM(status = 'failed') AS failed
                    FROM runs""")[0]
    tasks_row = q("SELECT COUNT(*) AS failed FROM tasks WHERE status = 'failed'")[0]
    work_row = q("""SELECT COUNT(*) AS total,
                           SUM(outcome = 'done') AS accepted,
                           AVG(duration) AS avg_s
                    FROM attempts
                    WHERE role = 'work' AND outcome NOT IN ('unavailable', 'cancelled')""")[0]
    usage_row = q("SELECT SUM(out_tokens) AS tokens_out, SUM(cost_usd) AS cost_usd FROM attempts")[0]

    att_total = work_row["total"] or 0
    att_accepted = work_row["accepted"] or 0
    avg_s = work_row["avg_s"]

    kpis = {
        "runs_total": runs_row["total"] or 0,
        "runs_done": runs_row["done"] or 0,
        "runs_failed": runs_row["failed"] or 0,
        "attempts_total": att_total,
        "attempts_accepted": att_accepted,
        "success_rate": round(att_accepted / att_total, 4) if att_total > 0 else None,
        "tasks_failed": tasks_row["failed"] or 0,
        "avg_attempt_seconds": round(avg_s, 1) if avg_s is not None else None,
        "tokens_out": int(usage_row["tokens_out"] or 0),
        "cost_usd": round(float(usage_row["cost_usd"] or 0.0), 4),
    }

    task_status = {"pending": 0, "running": 0, "done": 0, "failed": 0, "cancelled": 0}
    for r in q("SELECT status, COUNT(*) AS n FROM tasks GROUP BY status"):
        st = r["status"]
        if st:
            task_status[st] = r["n"]

    today = datetime.date.today()
    day_list = [today - datetime.timedelta(days=i) for i in reversed(range(days))]
    days_map = {
        d.strftime("%Y-%m-%d"): {
            "day": d.strftime("%Y-%m-%d"),
            "runs": 0,
            "attempts": 0,
            "accepted": 0,
            "_durations": [],
        }
        for d in day_list
    }

    for r in q("SELECT created FROM runs WHERE created IS NOT NULL"):
        try:
            d_str = datetime.datetime.fromtimestamp(r["created"]).strftime("%Y-%m-%d")
            if d_str in days_map:
                days_map[d_str]["runs"] += 1
        except (ValueError, OSError, OverflowError):
            pass

    for a in q("""SELECT started, duration, outcome FROM attempts
                  WHERE role = 'work' AND outcome NOT IN ('unavailable', 'cancelled')
                  AND started IS NOT NULL"""):
        try:
            d_str = datetime.datetime.fromtimestamp(a["started"]).strftime("%Y-%m-%d")
            if d_str in days_map:
                entry = days_map[d_str]
                entry["attempts"] += 1
                if a["outcome"] == "done":
                    entry["accepted"] += 1
                if a["duration"] is not None:
                    entry["_durations"].append(a["duration"])
        except (ValueError, OSError, OverflowError):
            pass

    series = []
    for d in day_list:
        entry = days_map[d.strftime("%Y-%m-%d")]
        durs = entry.pop("_durations")
        entry["avg_seconds"] = round(sum(durs) / len(durs), 1) if durs else None
        series.append(entry)

    return {
        "kpis": kpis,
        "series": series,
        "task_status": task_status,
    }
