"""Handoff context, idle watchdog, post-merge validation gate, conflict resolver limits, final goal check."""
import json, os, subprocess, tempfile, time, unittest
from pathlib import Path
from unittest import mock

if "ORCH_DB_PATH" not in os.environ:
    os.environ["ORCH_DB_PATH"] = ":memory:"

from orch import agents, db, gitops, judge, scheduler
from orch.config import CFG


class Handoff(unittest.TestCase):
    def test_prompt_carries_goal_and_dependency_summaries(self):
        t = {"prompt": "write tests", "acceptance": "tests pass", "tried": []}
        deps = [{"title": "Add parser", "summary": "parser.py parses dates"}]
        p = scheduler._prompt(t, False, "Date support for the CLI", deps)
        self.assertIn("Overall goal of the run", p)
        self.assertIn("Date support for the CLI", p)
        self.assertIn("- Add parser: parser.py parses dates", p)

    def test_prompt_without_context_is_unchanged(self):
        t = {"prompt": "write tests", "acceptance": "tests pass", "tried": []}
        self.assertEqual(scheduler._prompt(t, False), scheduler._prompt(t, False, "", ()))
        self.assertNotIn("Overall goal", scheduler._prompt(t, False))


class IdleWatchdog(unittest.TestCase):
    def test_silent_agent_is_killed_with_a_reason(self):
        lines = []
        with mock.patch.object(agents, "build_cmd", lambda *a, **k: ["sh", "-c", "echo start; sleep 30"]), \
                mock.patch.dict(CFG, {"agent_idle_timeout": 1}):
            t0 = time.time()
            code, summary = agents.run_agent({}, "x", ".", lines.append, lambda p: None)
        self.assertLess(time.time() - t0, 15)
        self.assertNotEqual(code, 0)
        self.assertIn("no output for 1 s", summary)
        self.assertIn("start", summary)

    def test_chatty_agent_is_not_killed(self):
        with mock.patch.object(agents, "build_cmd", lambda *a, **k: ["sh", "-c", "echo a; sleep 0.3; echo b"]), \
                mock.patch.dict(CFG, {"agent_idle_timeout": 1}):
            code, summary = agents.run_agent({}, "x", ".", lambda l: None, lambda p: None)
        self.assertEqual((code, summary), (0, "b"))

    def test_keep_limits_or_keeps_the_whole_final_message(self):
        long = "x" * 2500 + "END"
        with mock.patch.object(agents, "build_cmd", lambda *a, **k: ["printf", long]):
            self.assertEqual(len(agents.run_agent({}, "x", ".", lambda l: None, lambda p: None)[1]), 2000)
            self.assertEqual(agents.run_agent({}, "x", ".", lambda l: None, lambda p: None, keep=None)[1], long)


def _git(cwd, *a):
    subprocess.run(["git", "-C", str(cwd), "-c", "user.name=t", "-c", "user.email=t@t", *a],
                   check=True, capture_output=True)


class MergeGate(unittest.TestCase):
    """Two tasks that each pass alone but break together: the second merge must be undone and the task
    sent back with the reason, instead of poisoning the integration branch."""

    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.repo = Path(self.td.name)
        _git(self.repo, "init", "-q", "-b", "main")
        (self.repo / "README").write_text("x\n")
        _git(self.repo, "add", "-A")
        _git(self.repo, "commit", "-qm", "init")
        gitops.ensure_repo(self.repo)
        self.rid = db.x("INSERT INTO runs(repo,goal,test_cmd,status,created) VALUES(?,?,?,?,?)",
                        (str(self.repo), "goal", "! (test -f a && test -f b)", "running", time.time()))
        db.x("INSERT INTO tasks(run_id,key,title,prompt,agent,depends_on,acceptance,status,category,difficulty,"
             "profile) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
             (self.rid, "t1", "add b", "create b", "claude", "[]", "b exists", "running", "simple", "easy",
              "claude-haiku-low"))
        self.integ = self.repo / ".orch" / "wt" / f"integration-r{self.rid}"
        gitops.add_worktree(self.repo, self.integ, scheduler._branch(self.rid), "HEAD")
        scheduler._down[self.rid] = set()

    def tearDown(self):
        gitops.remove_worktree(self.repo, self.integ)
        scheduler._down.pop(self.rid, None)
        self.td.cleanup()

    def _work(self, agent):
        run = db.q("SELECT * FROM runs WHERE id=?", (self.rid,))[0]
        task = db.run_tasks(self.rid)[0]
        with mock.patch.object(scheduler, "run_agent", agent), \
                mock.patch.object(judge, "judge", lambda *a, **k: {"verdict": "accept", "reason": "ok"}):
            scheduler._work(run, task, self.repo, self.integ, "claude-haiku-low", time.time())
        return db.run_tasks(self.rid)[0]

    def test_merge_that_breaks_tests_is_undone(self):
        before = gitops.head(self.integ)

        def agent(profile, prompt, wd, on_line, reg, readonly=False):
            Path(wd, "b").write_text("b\n")
            Path(self.integ, "a").write_text("a\n")  # another task merges `a` meanwhile
            _git(self.integ, "add", "-A")
            _git(self.integ, "commit", "-qm", "other task")
            return 0, "done"

        t = self._work(agent)
        self.assertEqual(t["status"], "pending")
        self.assertIn("after merging into the integration branch", t["summary"])
        self.assertTrue(t["prev_branch"])
        self.assertNotEqual(gitops.head(self.integ), before)  # the other task's commit stays
        self.assertFalse((self.integ / "b").exists())         # this task's merge is gone

    def test_clean_merge_is_logged_with_sha(self):
        def agent(profile, prompt, wd, on_line, reg, readonly=False):
            Path(wd, "b").write_text("b\n")
            return 0, "done"

        t = self._work(agent)
        self.assertEqual(t["status"], "done")
        merges = db.q("SELECT text FROM events WHERE run_id=? AND kind='merge'", (self.rid,))
        self.assertIn(gitops.head(self.integ)[:12], merges[-1]["text"])


class ConflictResolver(unittest.TestCase):
    def test_no_usable_profile_means_no_agent_and_no_charge(self):
        scheduler._down[997] = set(CFG["profiles"])
        run, task = {"id": 997}, {"key": "t1", "category": "implement", "difficulty": "easy"}
        logs = []
        with mock.patch.object(scheduler, "run_agent", side_effect=AssertionError("must not run")):
            ok = scheduler._resolve_conflict(run, task, ".", 1, time.time(), lambda k, t: logs.append(t))
        self.assertFalse(ok)
        self.assertIn("no usable profile", logs[-1])
        self.assertEqual(scheduler._spent.get(997, 0), 0)
        scheduler._down.pop(997)

    def test_budget_applies_to_the_resolver(self):
        scheduler._down[996] = set()
        scheduler._spent[996] = CFG["run_budget"]
        logs = []
        with mock.patch.object(scheduler, "run_agent", side_effect=AssertionError("must not run")):
            ok = scheduler._resolve_conflict({"id": 996}, {"key": "t1"}, ".", 1, time.time(),
                                             lambda k, t: logs.append(t))
        self.assertFalse(ok)
        self.assertIn("budget", logs[-1])
        scheduler._down.pop(996)
        scheduler._spent.pop(996)


class FinalCheck(unittest.TestCase):
    def test_final_judge_sees_goal_tasks_and_test_result(self):
        seen = {}

        def chat(system, user, schema):
            seen.update(user=user, schema=schema)
            return {"verdict": "incomplete", "reason": "docs missing"}

        with mock.patch.object(judge.llm, "chat_json", chat):
            v = judge.final("Add login and docs", [{"key": "t1", "title": "Login", "summary": "ok"}],
                            " 1 file changed", "boom", False)
        self.assertEqual(v["verdict"], "incomplete")
        self.assertIn("Add login and docs", seen["user"])
        self.assertIn("t1 Login", seen["user"])
        self.assertIn("FAILED", seen["user"])
        self.assertEqual(seen["schema"]["properties"]["verdict"]["enum"], ["complete", "incomplete"])


if __name__ == "__main__":
    unittest.main()
