import errno, json, re, threading, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from . import capabilities, db, gitops, planner, probe, projgen, scheduler, suggestions
from .config import CFG

STATIC = Path(__file__).parent / "static"


def _listing(repo):
    return "\n".join(gitops.git(repo, "ls-files").stdout.splitlines()[:200])


def _ask_run(run_id, repo, goal):
    """Opt-in step before planning: the local model asks the user clarifying questions."""
    try:
        qs = planner.questions(goal, _listing(repo))
    except Exception as e:
        db.x("UPDATE runs SET status='failed', summary=? WHERE id=?", (str(e), run_id))
        return db.event(run_id, None, "error", str(e))
    if not qs:
        db.event(run_id, None, "status", "the planner has no questions, planning right away")
        db.x("UPDATE runs SET status='planning' WHERE id=?", (run_id,))
        return _plan_run(run_id, repo, goal)
    db.x("UPDATE runs SET status='questions', questions=? WHERE id=?", (json.dumps(qs), run_id))
    db.event(run_id, None, "status", f"the planner asks {len(qs)} question(s)")


def _answer(run_id, answers, skip=False):
    run = db.q("SELECT * FROM runs WHERE id=?", (run_id,))
    if not run or run[0]["status"] != "questions":
        raise ValueError("this run is not waiting for answers")
    qa = json.loads(run[0]["questions"] or "[]")
    for q, a in zip(qa, [] if skip else answers):
        q["answer"] = str(a or "").strip()
    db.x("UPDATE runs SET status='planning', questions=? WHERE id=?", (json.dumps(qa), run_id))
    db.event(run_id, None, "status", "questions skipped, planning" if skip else "answers received, planning")
    threading.Thread(target=_plan_run, args=(run_id, run[0]["repo"], planner.with_answers(run[0]["goal"], qa)),
                     daemon=True).start()


def _plan_run(run_id, repo, goal):
    try:
        tasks = planner.plan(goal, _listing(repo), probe.available())
        _save_tasks(run_id, tasks)
        db.x("UPDATE runs SET status='planned' WHERE id=?", (run_id,))
        db.event(run_id, None, "status", f"plan ready: {len(tasks)} tasks")
    except Exception as e:
        db.x("UPDATE runs SET status='failed', summary=? WHERE id=?", (str(e), run_id))
        db.event(run_id, None, "error", str(e))


def _save_tasks(run_id, tasks):
    db.x("DELETE FROM tasks WHERE run_id=?", (run_id,))
    for t in planner.normalize(tasks, probe.available()):
        db.x("INSERT INTO tasks(run_id,key,title,prompt,agent,depends_on,acceptance,status,category,difficulty,profile)"
             " VALUES(?,?,?,?,?,?,?, 'pending',?,?,?)",
             (run_id, t["key"], t["title"], t["prompt"], t["agent"], json.dumps(t["depends_on"]),
              t["acceptance"], t["category"], t["difficulty"], t["profile"]))


def _state(run_id):
    runs = db.q("SELECT * FROM runs WHERE id=?", (run_id,))
    return {"run": runs[0], "tasks": db.run_tasks(run_id)} if runs else None


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/index.html"):
            b = (STATIC / "index.html").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            return self.wfile.write(b)
        if path == "/api/runs":
            return self._json(db.q("SELECT * FROM runs ORDER BY id DESC"))
        if path == "/api/stats":
            return self._json(db.stats())
        if path == "/api/profiles":
            st = probe.check()
            return self._json([{"name": n, **p, **st[n]} for n, p in CFG["profiles"].items()])
        if path == "/api/overview":
            days = 14
            if "?" in self.path:
                from urllib.parse import parse_qs, urlparse
                qs = parse_qs(urlparse(self.path).query)
                try:
                    days = int(qs.get("days", [14])[0])
                except (ValueError, IndexError):
                    days = 14
            data = db.overview(days=days)
            data["kpis"]["active_profiles"] = sum(1 for p in probe.check().values() if p.get("ok"))
            return self._json(data)
        if path == "/api/capabilities":
            return self._json(capabilities.capabilities())
        if path == "/api/suggestions":
            return self._json(suggestions.suggestions())
        if path == "/api/projects":
            return self._json(projgen.listing())
        m = re.fullmatch(r"/api/projects/(\d+)", path)
        if m:
            p = projgen.get(int(m[1]))
            return self._json(p or {"error": "not found"}, 200 if p else 404)
        m = re.fullmatch(r"/api/runs/(\d+)", path)
        if m:
            s = _state(int(m[1]))
            return self._json(s, 200 if s else 404)
        m = re.fullmatch(r"/api/runs/(\d+)/stream", path)
        if m:
            return self._stream(int(m[1]))
        self._json({"error": "not found"}, 404)

    def _stream(self, run_id):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        last = 0
        try:
            while True:
                ev = db.q("SELECT * FROM events WHERE run_id=? AND id>? ORDER BY id LIMIT 500", (run_id, last))
                if ev:
                    last = ev[-1]["id"]
                self.wfile.write(f"data: {json.dumps({'state': _state(run_id), 'events': ev})}\n\n".encode())
                self.wfile.flush()
                time.sleep(1)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self):
        path, body = self.path, self._body()
        try:
            if path == "/api/runs":
                repo = gitops.ensure_repo(body["repo"])
                ask = bool(body.get("ask_questions"))
                rid = db.x("INSERT INTO runs(repo,goal,test_cmd,status,created) VALUES(?,?,?,?,?)",
                           (str(repo), body["goal"], body.get("test_cmd") or "",
                            "clarifying" if ask else "planning", time.time()))
                threading.Thread(target=_ask_run if ask else _plan_run, args=(rid, repo, body["goal"]),
                                 daemon=True).start()
                return self._json({"id": rid})
            if path == "/api/projects":
                return self._json({"id": projgen.start(body.get("description"))})
            m = re.fullmatch(r"/api/projects/(\d+)/install/(\d+)", path)
            if m:
                projgen.install(int(m[1]), int(m[2]))
                return self._json({"ok": True})
            m = re.fullmatch(r"/api/runs/(\d+)/answers", path)
            if m:
                _answer(int(m[1]), body.get("answers") or [], bool(body.get("skip")))
                return self._json({"ok": True})
            m = re.fullmatch(r"/api/runs/(\d+)/approve", path)
            if m:
                rid = int(m[1])
                if body.get("tasks"):
                    _save_tasks(rid, body["tasks"])
                scheduler.start(rid)
                return self._json({"ok": True})
            m = re.fullmatch(r"/api/runs/(\d+)/resume", path)
            if m:
                return self._json({"ok": True, "tasks": scheduler.resume(int(m[1]), bool(body.get("fresh")))})
            m = re.fullmatch(r"/api/runs/(\d+)/cancel", path)
            if m:
                scheduler.cancel_run(int(m[1]))
                return self._json({"ok": True})
            m = re.fullmatch(r"/api/runs/(\d+)/cancel/([\w.-]+)", path)
            if m:
                scheduler.cancel(int(m[1]), m[2])
                return self._json({"ok": True})
        except Exception as e:
            return self._json({"error": str(e)}, 400)
        self._json({"error": "not found"}, 404)


def main():
    url = f"http://{CFG['host']}:{CFG['port']}"
    try:
        srv = ThreadingHTTPServer((CFG["host"], CFG["port"]), H)
    except OSError as e:
        if e.errno != errno.EADDRINUSE:
            raise
        try:  # is the thing on the port our dashboard?
            urllib.request.urlopen(url + "/api/runs", timeout=3).read()
            print(f"orchestrator already running: {url}")
            return
        except Exception:
            raise SystemExit(f"port {CFG['port']} is taken by another program (set ORCH_PORT to use a different one)")
    srv.daemon_threads = True
    # runs left mid-flight by a previous process can never finish (only now that we own the port)
    db.x("UPDATE runs SET status='failed', summary='orchestrator restarted' WHERE status IN ('clarifying','planning','running')")
    db.x("UPDATE projects SET status='failed', report=? WHERE status='running'",
         (json.dumps({"error": "orchestrator restarted, generate again"}),))
    print(f"dashboard: {url}  model: {CFG['model']}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
