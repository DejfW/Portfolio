import datetime
import json
import os
import sqlite3
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.request
from unittest import mock
from pathlib import Path

# Ensure ORCH_DB_PATH is set before any other imports if not already imported
if "ORCH_DB_PATH" not in os.environ:
    os.environ["ORCH_DB_PATH"] = ":memory:"

from orch import capabilities, db, main, probe, suggestions
from orch.config import CFG


class DashboardApiTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = main.ThreadingHTTPServer(("127.0.0.1", 0), main.H)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.db_path = os.path.join(self.td.name, "test.db")
        self.orig_conn = db._conn
        conn = sqlite3.connect(self.db_path, check_same_thread=False)
        conn.row_factory = sqlite3.Row
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS runs(id INTEGER PRIMARY KEY AUTOINCREMENT, repo TEXT, goal TEXT,
              test_cmd TEXT, status TEXT, summary TEXT, created REAL, questions TEXT DEFAULT '');
            CREATE TABLE IF NOT EXISTS tasks(id INTEGER PRIMARY KEY AUTOINCREMENT, run_id INTEGER, key TEXT,
              title TEXT, prompt TEXT, agent TEXT, depends_on TEXT, acceptance TEXT, status TEXT,
              attempts INTEGER DEFAULT 0, tried TEXT DEFAULT '[]', summary TEXT,
              category TEXT DEFAULT 'implement', difficulty TEXT DEFAULT 'medium',
              profile TEXT DEFAULT '', prev_branch TEXT DEFAULT '', UNIQUE(run_id, key));
            CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY AUTOINCREMENT, run_id INTEGER,
              task_key TEXT, kind TEXT, text TEXT, ts REAL);
            CREATE TABLE IF NOT EXISTS attempts(id INTEGER PRIMARY KEY AUTOINCREMENT, run_id INTEGER, task_key TEXT,
              attempt INTEGER, role TEXT, profile TEXT, category TEXT, difficulty TEXT, started REAL, duration REAL,
              exit INTEGER, outcome TEXT, reason TEXT, out_tokens INTEGER, cost_usd REAL);
        """)
        db._conn = conn
        # Reset capabilities cache
        capabilities._cache = {"t": 0, "v": None}
        # Default patches so no real CLI runs
        self.sub_patcher = mock.patch("subprocess.run", side_effect=FileNotFoundError("cli not installed"))
        self.mock_sub = self.sub_patcher.start()
        self.probe_patcher = mock.patch.object(probe, "check", return_value={})
        self.mock_probe = self.probe_patcher.start()

    def tearDown(self):
        self.sub_patcher.stop()
        self.probe_patcher.stop()
        db._conn.close()
        db._conn = self.orig_conn
        self.td.cleanup()
        capabilities._cache = {"t": 0, "v": None}

    def _get(self, path):
        url = f"http://127.0.0.1:{self.port}{path}"
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))

    # --- 1. Overview tests ---

    def test_overview_empty_db(self):
        ov = db.overview(days=14)
        k = ov["kpis"]
        self.assertEqual(k["runs_total"], 0)
        self.assertEqual(k["runs_done"], 0)
        self.assertEqual(k["runs_failed"], 0)
        self.assertEqual(k["attempts_total"], 0)
        self.assertEqual(k["attempts_accepted"], 0)
        self.assertIsNone(k["success_rate"])
        self.assertEqual(k["tasks_failed"], 0)
        self.assertIsNone(k["avg_attempt_seconds"])
        self.assertEqual(k["tokens_out"], 0)
        self.assertEqual(k["cost_usd"], 0.0)

        self.assertEqual(len(ov["series"]), 14)
        today_str = datetime.date.today().strftime("%Y-%m-%d")
        self.assertEqual(ov["series"][-1]["day"], today_str)
        self.assertEqual(ov["series"][-1]["runs"], 0)
        self.assertEqual(ov["series"][-1]["attempts"], 0)
        self.assertEqual(ov["series"][-1]["accepted"], 0)
        self.assertIsNone(ov["series"][-1]["avg_seconds"])

        ts = ov["task_status"]
        self.assertEqual(ts, {"pending": 0, "running": 0, "done": 0, "failed": 0, "cancelled": 0})

    def test_overview_populated_db_and_endpoint(self):
        now = time.time()
        # Insert runs
        db.x("INSERT INTO runs(repo, goal, status, created) VALUES (?, ?, ?, ?)",
             ("/r1", "goal 1", "done", now))
        db.x("INSERT INTO runs(repo, goal, status, created) VALUES (?, ?, ?, ?)",
             ("/r2", "goal 2", "failed", now))
        db.x("INSERT INTO runs(repo, goal, status, created) VALUES (?, ?, ?, ?)",
             ("/r3", "goal 3", "running", now - 86400))  # yesterday

        # Insert tasks
        db.x("INSERT INTO tasks(run_id, key, title, prompt, agent, status) VALUES (?, ?, ?, ?, ?, ?)",
             (1, "t1", "T1", "p", "claude", "done"))
        db.x("INSERT INTO tasks(run_id, key, title, prompt, agent, status) VALUES (?, ?, ?, ?, ?, ?)",
             (1, "t2", "T2", "p", "claude", "failed"))
        db.x("INSERT INTO tasks(run_id, key, title, prompt, agent, status) VALUES (?, ?, ?, ?, ?, ?)",
             (2, "t3", "T3", "p", "claude", "pending"))

        # Insert attempts
        # Work attempts
        db.x("INSERT INTO attempts(run_id, task_key, attempt, role, outcome, duration, out_tokens, cost_usd, started) "
             "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
             (1, "t1", 1, "work", "done", 10.0, 100, 0.20, now))
        db.x("INSERT INTO attempts(run_id, task_key, attempt, role, outcome, duration, out_tokens, cost_usd, started) "
             "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
             (1, "t2", 1, "work", "failed", 20.0, 50, 0.10, now))
        # Excluded attempts from work metrics:
        db.x("INSERT INTO attempts(run_id, task_key, attempt, role, outcome, duration, out_tokens, cost_usd, started) "
             "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
             (1, "t2", 2, "work", "unavailable", 5.0, 10, 0.05, now))
        db.x("INSERT INTO attempts(run_id, task_key, attempt, role, outcome, duration, out_tokens, cost_usd, started) "
             "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
             (1, "t2", 3, "work", "cancelled", 5.0, 10, 0.05, now))
        # Review attempt: not counted in work attempts, but counted in total token/cost usage
        db.x("INSERT INTO attempts(run_id, task_key, attempt, role, outcome, duration, out_tokens, cost_usd, started) "
             "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
             (1, "t1", 1, "review", "done", 8.0, 40, 0.15, now))

        with mock.patch.object(probe, "check", return_value={"p1": {"ok": True}, "p2": {"ok": False}, "p3": {"ok": True}}):
            status_code, res = self._get("/api/overview")

        self.assertEqual(status_code, 200)
        k = res["kpis"]
        self.assertEqual(k["runs_total"], 3)
        self.assertEqual(k["runs_done"], 1)
        self.assertEqual(k["runs_failed"], 1)
        self.assertEqual(k["attempts_total"], 2)
        self.assertEqual(k["attempts_accepted"], 1)
        self.assertAlmostEqual(k["success_rate"], 0.5)
        self.assertEqual(k["tasks_failed"], 1)
        self.assertEqual(k["avg_attempt_seconds"], 15.0)
        self.assertEqual(k["tokens_out"], 210)
        self.assertAlmostEqual(k["cost_usd"], 0.55)
        self.assertEqual(k["active_profiles"], 2)

        ts = res["task_status"]
        self.assertEqual(ts["done"], 1)
        self.assertEqual(ts["failed"], 1)
        self.assertEqual(ts["pending"], 1)
        self.assertEqual(ts["running"], 0)
        self.assertEqual(ts["cancelled"], 0)

        # Series check
        series = res["series"]
        self.assertEqual(len(series), 14)
        today_entry = series[-1]
        self.assertEqual(today_entry["runs"], 2)
        self.assertEqual(today_entry["attempts"], 2)
        self.assertEqual(today_entry["accepted"], 1)
        self.assertEqual(today_entry["avg_seconds"], 15.0)

        yesterday_entry = series[-2]
        self.assertEqual(yesterday_entry["runs"], 1)

    def test_overview_custom_days(self):
        status_code, res = self._get("/api/overview?days=7")
        self.assertEqual(status_code, 200)
        self.assertEqual(len(res["series"]), 7)

    # --- 2. Capabilities tests ---

    def test_capabilities_claude(self):
        init_json = json.dumps({
            "type": "system",
            "subtype": "init",
            "skills": ["git", "search"],
            "plugins": [{"name": "web-browser"}, "extra-plugin"],
            "mcp_servers": [{"name": "github", "status": "connected"}, "postgres"],
            "permissionMode": "plan"
        }, separators=(',', ':'))
        db.x("INSERT INTO events(run_id, kind, text, ts) VALUES(?, ?, ?, ?)",
             (1, "out", init_json, time.time()))

        with mock.patch("subprocess.run") as mock_sub:
            mock_sub.side_effect = FileNotFoundError()
            caps = capabilities.capabilities(force=True)

        claude = caps["claude"]
        self.assertEqual(claude["skills"], ["git", "search"])
        self.assertEqual(claude["plugins"], ["web-browser", "extra-plugin"])
        self.assertEqual(claude["mcp_servers"], [
            {"name": "github", "status": "connected"},
            {"name": "postgres"}
        ])
        self.assertEqual(claude["permissionMode"], "plan")

    def test_capabilities_claude_empty_events(self):
        caps = capabilities.capabilities(force=True)
        self.assertEqual(caps["claude"], {"skills": [], "plugins": [], "mcp_servers": [], "permissionMode": None})

    def test_capabilities_codex(self):
        toml_content = b"""
[plugins]
browser = { enabled = true }
terminal = false
editor = {}

[mcp_servers]
github = { command = "gh" }
memory = { command = "mem" }
"""
        with tempfile.TemporaryDirectory() as home_dir:
            codex_dir = Path(home_dir) / ".codex"
            codex_dir.mkdir(parents=True)
            (codex_dir / "config.toml").write_bytes(toml_content)

            with mock.patch("pathlib.Path.home", return_value=Path(home_dir)), \
                 mock.patch("subprocess.run", side_effect=FileNotFoundError):
                caps = capabilities.capabilities(force=True)

            codex = caps["codex"]
            self.assertEqual(codex["mcp_servers"], ["github", "memory"])
            self.assertEqual(codex["plugins"], [
                {"name": "browser", "enabled": True},
                {"name": "terminal", "enabled": False},
                {"name": "editor"}
            ])

    def test_capabilities_codex_missing_file(self):
        with tempfile.TemporaryDirectory() as home_dir:
            with mock.patch("pathlib.Path.home", return_value=Path(home_dir)), \
                 mock.patch("subprocess.run", side_effect=FileNotFoundError):
                caps = capabilities.capabilities(force=True)
            self.assertEqual(caps["codex"], {"plugins": [], "mcp_servers": []})

    def test_capabilities_agy(self):
        def fake_run(cmd, **kwargs):
            if cmd == ["agy", "plugin", "list"]:
                return subprocess.CompletedProcess(cmd, 0, stdout="plugin-a\nplugin-b\n")
            if cmd == ["agy", "mcp", "list"]:
                return subprocess.CompletedProcess(cmd, 0, stdout="mcp-server-1\nmcp-server-2\n")
            raise ValueError(f"unexpected cmd: {cmd}")

        with mock.patch("subprocess.run", side_effect=fake_run):
            caps = capabilities.capabilities(force=True)

        self.assertEqual(caps["agy"], {
            "plugins": ["plugin-a", "plugin-b"],
            "mcp_servers": ["mcp-server-1", "mcp-server-2"]
        })

    def test_capabilities_agy_empty_markers(self):
        def fake_run(cmd, **kwargs):
            if cmd == ["agy", "plugin", "list"]:
                return subprocess.CompletedProcess(cmd, 0, stdout="No plugins installed.\n")
            if cmd == ["agy", "mcp", "list"]:
                return subprocess.CompletedProcess(cmd, 0, stdout="No MCP servers configured.\n")
            raise ValueError(f"unexpected cmd: {cmd}")

        with mock.patch("subprocess.run", side_effect=fake_run):
            caps = capabilities.capabilities(force=True)

        self.assertEqual(caps["agy"], {"plugins": [], "mcp_servers": []})

    def test_capabilities_agy_cli_missing(self):
        with mock.patch("subprocess.run", side_effect=FileNotFoundError):
            caps = capabilities.capabilities(force=True)

        self.assertIn("error", caps["agy"])
        self.assertEqual(caps["agy"]["error"], "cli not installed")

    def test_capabilities_caching_and_endpoint(self):
        call_count = [0]
        def fake_run(cmd, **kwargs):
            call_count[0] += 1
            return subprocess.CompletedProcess(cmd, 0, stdout="No plugins installed.\n")

        with mock.patch("subprocess.run", side_effect=fake_run):
            status1, res1 = self._get("/api/capabilities")
            status2, res2 = self._get("/api/capabilities")

        self.assertEqual(status1, 200)
        self.assertEqual(status2, 200)
        self.assertEqual(res1, res2)
        self.assertEqual(call_count[0], 2)  # called once for plugin and once for mcp, then cached

    # --- 3. Suggestions tests ---

    def test_suggestions_failed_runs_and_resumable(self):
        db.x("INSERT INTO runs(repo, goal, status, summary, created) VALUES (?, ?, ?, ?, ?)",
             ("/r", "fix issue 101", "failed", "out of memory", time.time()))
        db.x("INSERT INTO runs(repo, goal, status, summary, created) VALUES (?, ?, ?, ?, ?)",
             ("/r", "completed run", "done", "ok", time.time()))

        with mock.patch.object(probe, "check", return_value={}):
            status_code, items = self._get("/api/suggestions")

        self.assertEqual(status_code, 200)
        failed_sug = [it for it in items if it.get("kind") == "run"]
        self.assertEqual(len(failed_sug), 1)
        self.assertEqual(failed_sug[0]["action"], {"type": "resume", "run": 1})
        self.assertIn("Resume failed run #1", failed_sug[0]["title"])
        self.assertEqual(failed_sug[0]["detail"], "out of memory")

    def test_suggestions_profile_stats_low_acceptance(self):
        # 3 work attempts, 1 accepted (< 50%)
        db.x("INSERT INTO attempts(run_id, task_key, attempt, role, profile, category, difficulty, outcome, started, duration) "
             "VALUES (1, 't1', 1, 'work', 'test-prof', 'implement', 'medium', 'done', 0, 10)")
        db.x("INSERT INTO attempts(run_id, task_key, attempt, role, profile, category, difficulty, outcome, started, duration) "
             "VALUES (1, 't2', 1, 'work', 'test-prof', 'implement', 'medium', 'failed', 0, 10)")
        db.x("INSERT INTO attempts(run_id, task_key, attempt, role, profile, category, difficulty, outcome, started, duration) "
             "VALUES (1, 't3', 1, 'work', 'test-prof', 'implement', 'medium', 'failed', 0, 10)")

        # Another profile with 2 attempts, 0 accepted (not >= 3 attempts, so not suggested)
        db.x("INSERT INTO attempts(run_id, task_key, attempt, role, profile, category, difficulty, outcome, started, duration) "
             "VALUES (1, 't4', 1, 'work', 'short-prof', 'implement', 'medium', 'failed', 0, 10)")
        db.x("INSERT INTO attempts(run_id, task_key, attempt, role, profile, category, difficulty, outcome, started, duration) "
             "VALUES (1, 't5', 1, 'work', 'short-prof', 'implement', 'medium', 'failed', 0, 10)")

        with mock.patch.object(probe, "check", return_value={}):
            items = suggestions.suggestions()

        prof_sug = [it for it in items if it.get("title") == "Profile test-prof has low success rate"]
        self.assertEqual(len(prof_sug), 1)
        self.assertIn("1/3 attempts accepted (33%)", prof_sug[0]["detail"])

    def test_suggestions_quota_and_unavailable(self):
        checked = {
            "claude-opus-high": {"ok": False, "reason": "not logged in", "quota_left": None},
            "agy-flash-med": {"ok": True, "reason": "", "quota_left": 0.15},
            "agy-argon-high": {"ok": True, "reason": "", "quota_left": 0.80},
        }
        with mock.patch.object(probe, "check", return_value=checked):
            items = suggestions.suggestions()

        unavail = [it for it in items if it.get("title") == "Profile claude-opus-high is unavailable"]
        self.assertEqual(len(unavail), 1)
        self.assertEqual(unavail[0]["detail"], "not logged in")

        quota_sug = [it for it in items if it.get("kind") == "quota"]
        self.assertEqual(len(quota_sug), 1)
        self.assertIn("Low quota for pool agy-gemini", quota_sug[0]["title"])
        self.assertEqual(quota_sug[0]["detail"], "Remaining quota: 15%")

    def test_suggestions_group_unavailable_profiles_by_reason(self):
        checked = {n: {"ok": False, "reason": "cli not installed", "quota_left": None}
                   for n in ("codex-luna-low", "codex-sol-med", "codex-astra-high")}
        with mock.patch.object(probe, "check", return_value=checked):
            items = suggestions.suggestions()
        prof = [it for it in items if it.get("kind") == "profile"]
        self.assertEqual(len(prof), 1)
        self.assertEqual(prof[0]["title"], "3 profiles are unavailable: cli not installed")
        self.assertIn("codex-sol-med", prof[0]["detail"])

    def test_suggestions_claude_mcp_auth(self):
        init_json = json.dumps({
            "type": "system",
            "subtype": "init",
            "skills": [],
            "plugins": [],
            "mcp_servers": [
                {"name": "github-enterprise", "status": "needs_auth"},
                {"name": "local-db", "status": "connected"}
            ],
            "permissionMode": "plan"
        }, separators=(',', ':'))
        db.x("INSERT INTO events(run_id, kind, text, ts) VALUES(?, ?, ?, ?)",
             (1, "out", init_json, time.time()))

        with mock.patch.object(probe, "check", return_value={}), \
             mock.patch("subprocess.run", side_effect=FileNotFoundError):
            items = suggestions.suggestions()

        mcp_sug = [it for it in items if it.get("kind") == "mcp"]
        self.assertEqual(len(mcp_sug), 1)
        self.assertEqual(mcp_sug[0]["title"], "Claude MCP server 'github-enterprise' needs authentication")

    def test_suggestions_capped_at_eight(self):
        # Insert 12 failed runs
        for i in range(1, 13):
            db.x("INSERT INTO runs(repo, goal, status, created) VALUES (?, ?, ?, ?)",
                 ("/r", f"goal {i}", "failed", time.time()))

        with mock.patch.object(probe, "check", return_value={}):
            items = suggestions.suggestions()

        self.assertEqual(len(items), 8)


if __name__ == "__main__":
    unittest.main()
