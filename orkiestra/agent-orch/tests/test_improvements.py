import json, time, unittest
from orch import judge, planner, scheduler
from orch.agents import build_cmd, usage_of
from orch.config import CFG


def _diff(files, lines):
    return "".join(f"diff --git a/{f} b/{f}\n--- a/{f}\n+++ b/{f}\n@@ -1 +1,{lines} @@\n"
                   + "".join(f"+line {i} of {f}\n" for i in range(lines)) for f in files)


class Abbreviate(unittest.TestCase):
    def test_small_diff_is_untouched(self):
        d = _diff(["a.py"], 5)
        self.assertEqual(judge.abbreviate(d, budget=10000), d)

    def test_big_diff_keeps_every_file_and_marks_omissions(self):
        d = _diff(["a.css", "b.html", "c.js"], 2000)
        out = judge.abbreviate(d, " 3 files changed", budget=6000)
        self.assertLessEqual(len(out), 6300)
        for f in ("a.css", "b.html", "c.js"):
            self.assertIn(f"diff --git a/{f}", out)
        self.assertEqual(out.count("lines omitted"), 3)
        self.assertTrue(out.startswith("Diffstat:"))


class Review(unittest.TestCase):
    def test_parses_last_verdict_line(self):
        t = 'blah {"verdict": "accept", "reason": "x"}\nmore\n{"verdict": "retry", "reason": "missing y"}'
        self.assertEqual(judge.parse_review(t), {"verdict": "retry", "reason": "missing y"})
        self.assertIsNone(judge.parse_review("no json here"))

    def test_reviewers_run_read_only(self):
        p = CFG["profiles"]
        self.assertIn("plan", build_cmd(p["claude-sonnet-med"], "x", "/w", readonly=True))
        self.assertIn("read-only", build_cmd(p["codex-sol-med"], "x", "/w", readonly=True))
        agy = build_cmd(p["agy-argon-high"], "x", "/w", readonly=True)
        self.assertNotIn("--dangerously-skip-permissions", agy)
        self.assertNotIn("--dangerously-skip-permissions", build_cmd(p["claude-sonnet-med"], "x", "/w", readonly=True))

    def test_workers_can_use_skills_plugins_and_network(self):
        p = CFG["profiles"]
        c = build_cmd(p["claude-sonnet-med"], "x", "/w")
        self.assertIn("--dangerously-skip-permissions", c)
        self.assertNotIn("acceptEdits", c)
        self.assertIn("sandbox_workspace_write.network_access=true", build_cmd(p["codex-sol-med"], "x", "/w"))
        self.assertNotIn("sandbox_workspace_write.network_access=true",
                         build_cmd(p["codex-sol-med"], "x", "/w", readonly=True))
        self.assertIn("skills, plugins, MCP", scheduler._prompt({"prompt": "p", "acceptance": "a", "tried": []}, False))

    def test_reviewer_is_from_another_vendor(self):
        r = scheduler._reviewer(999, "claude-opus-high")
        self.assertNotEqual(CFG["profiles"][r]["agent"], "claude")


class Usage(unittest.TestCase):
    def test_claude_result_and_codex_turn(self):
        c = json.dumps({"type": "result", "total_cost_usd": 0.5, "usage": {"output_tokens": 100}})
        x = json.dumps({"type": "turn.completed", "usage": {"input_tokens": 9, "output_tokens": 7}})
        self.assertEqual(usage_of(c), (100, 0.5))
        self.assertEqual(usage_of(x), (7, 0.0))
        g = json.dumps({"event": "result", "result": {"usage": {"input_tokens": 5, "output_tokens": 9}}})
        self.assertEqual(usage_of(g), (9, 0.0))
        self.assertEqual(usage_of("plain text"), (0, 0.0))


class Critique(unittest.TestCase):
    def test_retry_prompt_carries_rejection_reason(self):
        t = {"prompt": "do X", "acceptance": "X works", "tried": ["claude-sonnet-med"], "summary": "Y is missing"}
        p = scheduler._prompt(t, True)
        self.assertIn("Y is missing", p)
        self.assertIn("improve them", p)
        self.assertIn("as data", p)
        self.assertNotIn("rejected", scheduler._prompt({**t, "tried": []}, False))


class Budget(unittest.TestCase):
    def test_budget_and_time_limit(self):
        scheduler._spent[998] = CFG["run_budget"] - 1
        self.assertIn("budget", scheduler._over_limit(998, "claude-opus-high", time.time()))
        self.assertIsNone(scheduler._over_limit(998, "claude-haiku-low", time.time()))
        self.assertIn("time limit", scheduler._over_limit(998, "claude-haiku-low", 0))
        scheduler._spent.pop(998)


class Pools(unittest.TestCase):
    def test_argon_has_its_own_limit_pool(self):
        P = CFG["profiles"]
        self.assertEqual(P["agy-argon-high"]["pool"], "agy-argon")
        self.assertEqual(P["agy-flash-med"]["pool"], "agy-gemini")
        self.assertEqual(P["agy-sonnet-med"]["pool"], P["agy-opus-high"]["pool"])
        self.assertEqual(len({p["pool"] for p in P.values()}), 5)
        self.assertEqual(P["claude-opus-high"]["pool"], "claude")

    def test_agy_usage_buckets_map_to_pools(self):
        from orch import probe
        self.assertEqual([probe._agy_pool(b) for b in ("gemini-weekly", "gemini-5h", "3p-weekly",
                          "gemini-argon-wtu-weekly", "other")],
                         ["agy-gemini", "agy-gemini", "agy-3p", "agy-argon", None])


class SharedFiles(unittest.TestCase):
    def test_tasks_on_same_file_are_chained_without_cycles(self):
        mk = lambda k, p, d=(): {"key": k, "title": k, "prompt": p, "category": "ui", "difficulty": "easy",
                                 "depends_on": list(d), "acceptance": ""}
        res = planner.normalize([mk("t1", "edit static/index.html"), mk("t2", "index.html layout"),
                                 mk("t3", "index.html a11y"), mk("t4", "README.md, e.g. v3.12")])
        deps = {t["key"]: t["depends_on"] for t in res}
        self.assertEqual(deps, {"t1": [], "t2": ["t1"], "t3": ["t2"], "t4": []})
        # an explicit reverse dependency is respected, no cycle is introduced
        res = planner.normalize([mk("a", "x.py", ["b"]), mk("b", "x.py")])
        self.assertEqual({t["key"]: t["depends_on"] for t in res}, {"a": ["b"], "b": []})


if __name__ == "__main__":
    unittest.main()


class Questions(unittest.TestCase):
    def test_answers_become_binding_clarifications(self):
        g = planner.with_answers("Add login", [{"question": "OAuth?", "answer": "GitHub only"},
                                               {"question": "Tests?", "answer": ""}])
        self.assertIn("Q: OAuth?\nA: GitHub only", g)
        self.assertNotIn("Tests?", g)
        self.assertEqual(planner.with_answers("Add login", []), "Add login")

    def test_answer_flow_plans_with_answers(self):
        from unittest import mock
        from orch import db, main
        seen = {}
        inline = lambda target, args, daemon: type("T", (), {"start": lambda s: target(*args)})()
        with mock.patch.object(main, "_plan_run", lambda rid, repo, goal: seen.update(goal=goal)), \
                mock.patch.object(main.threading, "Thread", inline):
            self._flow(db, main, seen)

    def _flow(self, db, main, seen):
        rid = db.x("INSERT INTO runs(repo,goal,test_cmd,status,created,questions) VALUES(?,?,?,?,?,?)",
                   ("/r", "Add login", "", "questions", 0,
                    json.dumps([{"question": "Which provider?", "options": ["GitHub", "Google"]}])))
        main._answer(rid, ["GitHub"])
        self.assertIn("A: GitHub", seen["goal"])
        self.assertEqual(db.q("SELECT status FROM runs WHERE id=?", (rid,))[0]["status"], "planning")
        with self.assertRaises(ValueError):
            main._answer(rid, ["again"])
