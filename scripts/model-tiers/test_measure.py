"""Tests of measure.py on recorded answers: python3 -m unittest discover scripts/model-tiers (needs docker)."""
import json
import os
import unittest

import measure

HERE = os.path.dirname(os.path.abspath(__file__))
CANDS = [
    {"model_name": "cand-a", "model": "zai/glm-5.3", "provider": "zai", "tier": "high"},
    {"model_name": "cand-b", "model": "dashscope/qwen3.8-max", "provider": "alibaba", "tier": "high"},
    {"model_name": "cand-c", "model": "groq/qwen/qwen3.8-27b", "provider": "groq", "tier": "high"},
    {"model_name": "cand-d", "model": "deepseek/deepseek-flash", "provider": "deepseek", "tier": "low"},
]


def records():
    return measure.load(os.path.join(HERE, "testdata", "recorded.jsonl"))


class Checks(unittest.TestCase):
    def test_coding_passes_only_when_the_tests_pass(self):
        buggy = measure.read("lru.go")
        fixed = buggy.replace("if e, ok := c.items[key]; ok {\n\t\treturn", "if e, ok := c.items[key]; ok {\n\t\tc.order.MoveToFront(e)\n\t\treturn")
        self.assertTrue(measure.check_coding("```go\n" + fixed + "```"))
        self.assertTrue(measure.check_coding(fixed), "an unfenced file")
        self.assertFalse(measure.check_coding("```go\n" + buggy + "```"))
        self.assertFalse(measure.check_coding("I cannot help with that."))

    def test_review_needs_concerns_naming_the_signature_bypass(self):
        ok = {"verdict": "concerns", "summary": "s", "findings": ["receive.go: an empty signature header skips verification"]}
        self.assertTrue(measure.check_review(json.dumps(ok)))
        self.assertTrue(measure.check_review("```json\n" + json.dumps(ok) + "\n```"))
        self.assertFalse(measure.check_review(json.dumps({**ok, "verdict": "approve"})))
        self.assertFalse(measure.check_review(json.dumps({**ok, "findings": ["deliver.go: backoff is linear"]})))
        self.assertFalse(measure.check_review("concerns: signature"))

    def test_supervisor_needs_redirect_to_parse_go(self):
        self.assertTrue(measure.check_supervisor('{"action": "redirect", "guidance": "fix internal/timeutil/parse.go, not the test"}'))
        self.assertFalse(measure.check_supervisor('{"action": "redirect", "guidance": "stop editing the test"}'))
        self.assertFalse(measure.check_supervisor('{"action": "retry_stronger", "guidance": "parse.go"}'))
        self.assertFalse(measure.check_supervisor("redirect parse.go"))


class Table(unittest.TestCase):
    def test_tables_from_recorded_answers(self):
        # cand-b passes 9 of 9, cand-a 8 (one supervisor retry_stronger),
        # cand-c none (buggy code, approve, retry_stronger) and one 500;
        # cand-a's p50 is the median of 10..12, 20..22, 30..32 = 21,
        # cand-d's the median of 1..9 = 5 and its cost the mean of
        # 0.001, 0.002, 0.003 = 0.002. Eligible (>= 7 passes): b and a,
        # weights 2 and 1; c gets 0; d alone in its tier gets 1.
        want = "\n".join([
            "### tier-high\n",
            "| rank | candidate | deployment | coding | review | supervisor | passes | p50 s | USD per call | errors | weight |",
            "|---|---|---|---|---|---|---|---|---|---|---|",
            "| 1 | cand-b | dashscope/qwen3.8-max | 3/3 | 3/3 | 3/3 | 9/9 | 40.0 | 0.020000 | 0 | 2 |",
            "| 2 | cand-a | zai/glm-5.3 | 3/3 | 3/3 | 2/3 | 8/9 | 21.0 | 0.010000 | 0 | 1 |",
            "| 3 | cand-c | groq/qwen/qwen3.8-27b | 0/3 | 0/3 | 0/3 | 0/9 | 5.0 | 0.001000 | 1 | 0 |",
            "",
            "### tier-low\n",
            "| rank | candidate | deployment | coding | review | supervisor | passes | p50 s | USD per call | errors | weight |",
            "|---|---|---|---|---|---|---|---|---|---|---|",
            "| 1 | cand-d | deepseek/deepseek-flash | 3/3 | 3/3 | 3/3 | 9/9 | 5.0 | 0.002000 | 0 | 1 |",
            "",
        ])
        self.assertEqual(measure.table(records(), CANDS), want)

    def test_equal_passes_rank_by_latency(self):
        recs = [r for r in records() if r["candidate"] in ("cand-a", "cand-b")]
        for r in recs:
            if r["candidate"] == "cand-a" and r["sample"] == "supervisor":
                r["content"] = '{"action": "redirect", "guidance": "parse.go"}'
        tiers = measure.rank(recs, CANDS[:2])
        self.assertEqual([(r["model_name"], r["total"], r["weight"]) for r in tiers["high"]], [("cand-a", 9, 2), ("cand-b", 9, 1)])


if __name__ == "__main__":
    unittest.main()
