import unittest
from orch import router, planner, scheduler
from orch.agents import build_cmd
from orch.config import CFG

ALL = list(CFG["profiles"])
NO_CODEX = [n for n in ALL if CFG["profiles"][n]["agent"] != "codex"]


class Pick(unittest.TestCase):
    def test_easy_simple_is_cheapest_tier1(self):
        self.assertEqual(router.pick("simple", "easy", NO_CODEX), "claude-haiku-low")

    def test_hard_refactor_goes_to_top_tier(self):
        p = router.pick("refactor", "hard", NO_CODEX)
        self.assertEqual(CFG["profiles"][p]["tier"], 4)
        self.assertIn("refactor", CFG["profiles"][p]["good"])

    def test_excluded_and_unavailable_are_never_returned(self):
        p = router.pick("ui", "medium", NO_CODEX, exclude={"agy-flash-med"})
        self.assertEqual(p, "agy-argon-high")

    def test_relaxes_category_then_tier_instead_of_failing(self):
        self.assertIsNotNone(router.pick("review", "easy", ["agy-flash-med"]))
        self.assertEqual(router.pick("simple", "hard", ["claude-haiku-low"]), "claude-haiku-low")
        self.assertIsNone(router.pick("ui", "easy", []))

    def test_load_breaks_cost_ties(self):
        a = router.pick("simple", "easy", ["claude-haiku-low", "codex-luna-low"], load={"claude": 2})
        self.assertEqual(a, "codex-luna-low")


class Escalate(unittest.TestCase):
    def test_same_agent_one_tier_up_first(self):
        self.assertEqual(router.escalate("claude-haiku-low", ["claude-haiku-low"], NO_CODEX, "simple"), "claude-sonnet-med")

    def test_then_other_agent_never_weaker(self):
        n = router.escalate("claude-opus-high", ["claude-opus-high"], NO_CODEX, "debug")
        self.assertEqual(n, "agy-argon-high")

    def test_exhausted_returns_none_and_never_repeats(self):
        tried = ["claude-opus-high", "agy-argon-high", "agy-opus-high"]
        self.assertIsNone(router.escalate("agy-opus-high", tried, NO_CODEX, "debug"))


class Plan(unittest.TestCase):
    def test_cycles_and_unknown_deps_are_dropped(self):
        t = planner.normalize([{"key": "a", "depends_on": ["b"]}, {"key": "b", "depends_on": ["a", "zzz"]}])
        self.assertTrue(all(x["depends_on"] == [] for x in t))

    def test_forced_valid_profile_kept_invalid_replaced(self):
        t = planner.normalize([{"key": "a", "profile": "claude-opus-high", "category": "simple", "difficulty": "easy"},
                               {"key": "b", "profile": "nope", "category": "simple", "difficulty": "easy"}], NO_CODEX)
        self.assertEqual(t[0]["profile"], "claude-opus-high")
        self.assertEqual(t[1]["profile"], "claude-haiku-low")

    def test_bad_enums_fall_back_to_safe_defaults(self):
        t = planner.normalize([{"key": "a", "category": "???", "difficulty": "???"}], NO_CODEX)[0]
        self.assertEqual((t["category"], t["difficulty"]), ("implement", "medium"))


class Commands(unittest.TestCase):
    def test_flags_per_agent(self):
        c = build_cmd(CFG["profiles"]["claude-opus-high"], "P", "/w")
        self.assertEqual(c[c.index("--model") + 1], "opus"); self.assertEqual(c[c.index("--effort") + 1], "high")
        c = build_cmd(CFG["profiles"]["codex-sol-med"], "P", "/w")
        self.assertEqual(c[c.index("-m") + 1], "gpt-6.1-sol"); self.assertIn('model_reasoning_effort="medium"', c)
        self.assertEqual(c[-1], "P")
        c = build_cmd(CFG["profiles"]["agy-argon-high"], "P", "/w")
        self.assertEqual(c[c.index("--model") + 1], "gemini-4-argon-high")
        self.assertIn("--dangerously-skip-permissions", c)

    def test_empty_effort_omits_flag(self):
        self.assertNotIn("--effort", build_cmd(CFG["profiles"]["claude-haiku-low"], "P", "/w"))


class Unavailable(unittest.TestCase):
    def test_quota_and_auth_text_detected_but_normal_failures_not(self):
        for s in ("Error 429: rate limit exceeded", "You have hit your usage limit", "Not logged in", "401 Unauthorized"):
            self.assertTrue(scheduler._UNAVAILABLE.search(s), s)
        for s in ("AssertionError: expected 3", "SyntaxError in line 4", "nothing to do"):
            self.assertFalse(scheduler._UNAVAILABLE.search(s), s)


if __name__ == "__main__":
    unittest.main()
