#!/usr/bin/env python3
"""Tests for Scripts/project-narrative.py.

    python3 Scripts/test-project-narrative.py

Runs against an in-process fake engine and a fake `claude` script; nothing touches a real engine, a
real vault or a real model. Case ids follow svod-engine docs/test-plan-evermind-borrow.md (N1–N12).
"""
import importlib.util
import json
import os
import stat
import tempfile
import threading
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("narrative", ROOT / "Scripts/project-narrative.py")
narrative = importlib.util.module_from_spec(spec)
spec.loader.exec_module(narrative)

DAY = 86_400_000


def session_note(project, sid, ended, body):
    return (f"---\ntype: session\nproject: {project}\nsessionId: {sid}\nstartedAt: {ended - 1000}\n"
            f"endedAt: {ended}\ndistilled: false\nbytes: {len(body)}\n---\n{body}")


class FakeEngine:
    """Just the four routes the job uses. `files` is the vault; `put_status` forces a PUT answer."""

    def __init__(self):
        self.files = {}          # path -> (content, revision)
        self.sessions = []       # list of SessionDto dicts
        self.puts = []           # (path, body dict)
        self.put_status = {}     # path -> forced status
        self.read_status = {}    # path -> forced status for GET /file
        self.ready = True
        engine = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, code, obj):
                raw = json.dumps(obj).encode()
                self.send_response(code)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def do_GET(self):
                u = urllib.parse.urlparse(self.path)
                q = dict(urllib.parse.parse_qsl(u.query))
                if u.path == "/ready":
                    return self._send(200 if engine.ready else 503, {"ready": engine.ready})
                if u.path == "/api/v1/memory/sessions":
                    return self._send(200, engine.sessions)
                if u.path == "/api/v1/file":
                    p = q["path"]
                    if p in engine.read_status:
                        return self._send(engine.read_status[p], {"error": "boom", "message": "boom"})
                    if p not in engine.files:
                        return self._send(404, {"error": "not_found", "message": p})
                    content, rev = engine.files[p]
                    return self._send(200, {"path": p, "revision": rev, "content": content})
                self._send(404, {"error": "not_found", "message": u.path})

            def do_PUT(self):
                u = urllib.parse.urlparse(self.path)
                q = dict(urllib.parse.parse_qsl(u.query))
                body = json.loads(self.rfile.read(int(self.headers["content-length"])))
                p = q["path"]
                engine.puts.append((p, body))
                forced = engine.put_status.get(p)
                if forced:
                    return self._send(forced, {"error": "x", "message": "forced"})
                rev = f"r{len(engine.puts)}"
                engine.files[p] = (body["content"], rev)
                self._send(200, {"path": p, "revision": rev, "commit": "c"})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.server.daemon_threads = True
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def add_session(self, project, sid, ended, body):
        path = f"messy/sessions/{ended}-{narrative.slug(project)}-{sid[:8]}.md"
        self.files[path] = (session_note(project, sid, ended, body), "s" + sid)
        self.sessions.append({"path": path, "project": project, "sessionId": sid, "startedAt": ended - 1000,
                              "endedAt": ended, "bytes": len(body.encode()), "distilled": False})

    def close(self):
        self.server.shutdown()
        self.server.server_close()


FAKE_CLAUDE = r'''#!/usr/bin/env python3
import json, os, sys
d = os.environ["FAKE_CLAUDE_DIR"]
prompt = sys.stdin.read()
n = len(os.listdir(d))
json.dump({"argv": sys.argv[1:], "capture": os.environ.get("SVOD_CAPTURE"), "prompt": prompt},
          open(os.path.join(d, f"call{n}.json"), "w"))
mode = os.environ.get("FAKE_CLAUDE_MODE", "ok")
project = prompt.split("# ", 1)[1].split(" — narrative", 1)[0] if "# " in prompt else "?"
if mode == "fail":
    sys.exit(3)
if mode == "empty":
    print("")
elif mode == "noh1":
    print("Here is the narrative you asked for.")
elif mode == "private":
    print(f"# {project} — narrative\n\nsecret <private>x</private>")
else:
    print(f"# {project} — narrative\n\nUpdated from {prompt.count('--- session ')} session(s).\n\n## Current state\n- ok")
'''


class NarrativeJobTest(unittest.TestCase):

    def setUp(self):
        self.engine = FakeEngine()
        self.tmp = tempfile.TemporaryDirectory()
        self.calls_dir = Path(self.tmp.name) / "calls"
        self.calls_dir.mkdir()
        self.claude = Path(self.tmp.name) / "claude"
        self.claude.write_text(FAKE_CLAUDE)
        self.claude.chmod(self.claude.stat().st_mode | stat.S_IEXEC)
        self.logs = []
        os.environ["FAKE_CLAUDE_DIR"] = str(self.calls_dir)
        os.environ.pop("FAKE_CLAUDE_MODE", None)

    def tearDown(self):
        self.engine.close()
        self.tmp.cleanup()

    def env(self, **extra):
        e = {"SVOD_ENGINE": self.engine.url, "SVOD_VAULT": "personal", "CLAUDE_BIN": str(self.claude),
             "NARRATIVE_MIN_BYTES": "1", "NARRATIVE_TODAY": "2026-09-22"}
        e.update({k: str(v) for k, v in extra.items()})
        return e

    def run_job(self, **extra):
        return narrative.run(self.env(**extra), self.logs.append)

    def calls(self):
        return [json.loads(p.read_text()) for p in sorted(self.calls_dir.glob("call*.json"))]

    # ------------------------------------------------------------------ pure helpers

    def test_n1_slug_matches_the_engine_rule(self):
        self.assertEqual(narrative.slug("github.com/karlovotech/resheno"), "github-com-karlovotech-resheno")
        self.assertEqual(narrative.slug("svod-ui-macos"), "svod-ui-macos")
        self.assertEqual(narrative.slug("Площад"), "площад")
        self.assertEqual(narrative.slug(""), "none")

    def test_n2_private_spans_and_frontmatter_are_removed(self):
        self.assertEqual(narrative.strip_private("a <private>x</private> b <PRIVATE>y</Private> c"), "a  b  c")
        self.assertEqual(narrative.strip_private("keep <private>unclosed and everything after"), "keep ")
        fm, body = narrative.split_frontmatter("---\ncovered_until: 5\nproject: \"a/b\"\n---\n# T\nbody")
        self.assertEqual(fm, {"covered_until": "5", "project": "a/b"})
        self.assertEqual(body, "# T\nbody")

    def test_n7_budget_keeps_the_newest_that_fit_oldest_first(self):
        new_first = [({"endedAt": 3}, "c" * 40), ({"endedAt": 2}, "b" * 40), ({"endedAt": 1}, "a" * 40)]
        chosen = narrative.select_sessions(iter(new_first), budget=100)
        self.assertEqual([m["endedAt"] for m, _ in chosen], [2, 3])

    def test_a_single_session_bigger_than_the_budget_is_clipped_not_dropped(self):
        chosen = narrative.select_sessions(iter([({"endedAt": 1}, "S" + "x" * 1000 + "E")]), budget=200)
        self.assertEqual(len(chosen), 1)
        text = chosen[0][1]
        self.assertTrue(text.startswith("S") and text.endswith("E"))
        self.assertLess(len(text), 300)

    def test_a_bare_directory_label_folds_into_its_single_remote_label(self):
        m = narrative.canonical_projects({"svod-ui-macos", "github.com/fleetq/svod-ui-macos", "ploshtad",
                                          "app", "github.com/a/app", "gitlab.com/b/app"})
        self.assertEqual(m["svod-ui-macos"], "github.com/fleetq/svod-ui-macos")
        self.assertEqual(m["ploshtad"], "ploshtad", "no remote label ⇒ stays as it is")
        self.assertEqual(m["app"], "app", "two remote labels end in 'app' ⇒ ambiguous, not folded")
        self.assertEqual(m["github.com/a/app"], "github.com/a/app")

    def test_old_and_new_labels_of_one_repo_make_one_narrative(self):
        self.seed("svod-ui-macos", n=2)
        self.seed("github.com/fleetq/svod-ui-macos", n=1, start=1_790_000_000_000 + 30 * DAY)
        out = self.run_job()
        self.assertEqual(out["projects"], {"github.com/fleetq/svod-ui-macos": "written: 3"})
        self.assertIn("narratives/github-com-fleetq-svod-ui-macos.md", self.engine.files)

    def test_n9_output_validation(self):
        self.assertIsNone(narrative.valid_output("", "p"))
        self.assertIsNone(narrative.valid_output("Sure! # p — narrative", "p"))
        self.assertIsNone(narrative.valid_output("# other — narrative\nx", "p"))
        self.assertIsNone(narrative.valid_output("# p — narrative\n<private>x</private>", "p"))
        self.assertEqual(narrative.valid_output("\n# p — narrative\nx\n\n", "p"), "# p — narrative\nx\n")

    # ------------------------------------------------------------------ the run

    def seed(self, project="svod-ui-macos", n=3, start=1_790_000_000_000):
        for i in range(n):
            self.engine.add_session(project, f"sid{i:05d}-{project[:3]}", start + i * DAY, f"user: task {i}\nassistant: done {i}")

    def test_n3_first_run_creates_the_note_with_its_frontmatter(self):
        self.seed(n=3)
        out = self.run_job()
        self.assertEqual(out["projects"]["svod-ui-macos"], "written: 3")
        content, _ = self.engine.files["narratives/svod-ui-macos.md"]
        fm, body = narrative.split_frontmatter(content)
        self.assertEqual(fm["type"], "narrative")
        self.assertEqual(fm["project"], "svod-ui-macos")
        self.assertEqual(fm["covered_until"], str(1_790_000_000_000 + 2 * DAY))
        self.assertEqual(fm["sessions_folded"], "3")
        self.assertTrue(body.startswith("# svod-ui-macos — narrative"))
        # first write has no expectedRevision; the prompt holds the three sessions oldest first
        self.assertNotIn("expectedRevision", self.engine.puts[0][1])
        prompt = self.calls()[0]["prompt"]
        self.assertLess(prompt.index("task 0"), prompt.index("task 2"))
        self.assertIn("(none yet)", prompt)

    def test_n4_second_run_without_new_sessions_does_nothing(self):
        self.seed(n=3)
        self.run_job()
        self.run_job()
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(len(self.engine.puts), 1)

    def test_incremental_run_sends_only_new_sessions_with_the_current_narrative(self):
        self.seed(n=3)
        self.run_job()
        self.seed(n=2, start=1_790_000_000_000 + 10 * DAY)   # two newer sessions
        out = self.run_job()
        self.assertEqual(out["projects"]["svod-ui-macos"], "written: 2")
        prompt = self.calls()[1]["prompt"]
        self.assertIn("Updated from 3 session(s)", prompt, "the current narrative is sent back")
        self.assertEqual(prompt.count("--- session "), 2)
        self.assertEqual(self.engine.puts[1][1]["expectedRevision"], "r1")
        fm, _ = narrative.split_frontmatter(self.engine.files["narratives/svod-ui-macos.md"][0])
        self.assertEqual(fm["sessions_folded"], "5")

    def test_n5_fewer_than_min_new_is_skipped(self):
        self.seed(n=1)
        out = self.run_job()
        self.assertEqual(out["projects"]["svod-ui-macos"], "skip: 1 new")
        self.assertEqual(self.calls(), [])

    def test_n6_job_runs_are_never_sent_to_the_model(self):
        self.seed(n=2)
        self.engine.add_session("svod-ui-macos", "distill1", 1_790_000_000_000 + 5 * DAY,
                                "user: ...\n--- RUNTIME CONTEXT (this run) ---\nWORK_DIR: /x")
        self.run_job()
        prompt = self.calls()[0]["prompt"]
        self.assertNotIn("RUNTIME CONTEXT (this run) ---\nWORK_DIR", prompt)
        self.assertEqual(prompt.count("--- session "), 2)

    def test_private_text_never_reaches_the_model(self):
        self.engine.add_session("p", "a1", 1_790_000_000_000, "public <private>TOKEN-123</private> text")
        self.engine.add_session("p", "a2", 1_790_000_000_000 + DAY, "more <private>left open TOKEN-456")
        self.run_job()
        prompt = self.calls()[0]["prompt"]
        self.assertNotIn("TOKEN-", prompt)

    def test_n8_conflict_and_blocked_writes_skip_only_that_project(self):
        self.seed("alpha", n=2)
        self.seed("beta", n=2)
        self.engine.put_status["narratives/alpha.md"] = 422
        out = self.run_job()
        self.assertEqual(out["projects"]["alpha"], "blocked")
        self.assertEqual(out["projects"]["beta"], "written: 2")
        self.engine.put_status = {"narratives/beta.md": 409}
        self.seed("beta", n=2, start=1_790_000_000_000 + 20 * DAY)
        out = self.run_job()
        self.assertEqual(out["projects"]["beta"], "conflict")

    def test_an_unreadable_existing_note_is_not_treated_as_new(self):
        self.seed(n=2)
        self.engine.read_status["narratives/svod-ui-macos.md"] = 500
        out = self.run_job()
        self.assertEqual(out["projects"]["svod-ui-macos"], "read-http-500")
        self.assertEqual(self.engine.puts, [])
        self.assertEqual(self.calls(), [])

    def test_n9_bad_model_output_writes_nothing(self):
        for mode in ("empty", "noh1", "private", "fail"):
            with self.subTest(mode=mode):
                os.environ["FAKE_CLAUDE_MODE"] = mode
                self.engine.puts.clear()
                self.seed(f"proj-{mode}", n=2)
                out = self.run_job(NARRATIVE_PROJECTS=f"proj-{mode}")
                self.assertIn(out["projects"][f"proj-{mode}"], ("rejected", "model-failed"))
                self.assertEqual(self.engine.puts, [])

    def test_n10_model_runs_without_tools_and_is_not_captured(self):
        self.seed(n=2)
        self.run_job()
        call = self.calls()[0]
        argv = call["argv"]
        self.assertEqual(argv[argv.index("--tools") + 1], "")
        self.assertIn("-p", argv)
        self.assertEqual(argv[argv.index("--model") + 1], "claude-haiku-4-5")
        self.assertEqual(call["capture"], "off")

    def test_n11_dry_run_neither_calls_the_model_nor_writes(self):
        self.seed(n=3)
        out = self.run_job(NARRATIVE_DRY_RUN=1)
        self.assertEqual(out["projects"]["svod-ui-macos"], "dry: 3")
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.engine.puts, [])

    def test_n12_engine_down_is_one_log_line_and_no_crash(self):
        self.engine.ready = False
        out = self.run_job()
        self.assertEqual(out["status"], "engine-down")
        self.assertEqual(len(self.logs), 1)

    def test_tiny_sessions_below_min_bytes_do_not_count(self):
        self.seed(n=3)
        out = self.run_job(NARRATIVE_MIN_BYTES=10_000)
        self.assertNotIn("svod-ui-macos", out["projects"])

    def test_project_filter_restricts_the_run(self):
        self.seed("alpha", n=2)
        self.seed("beta", n=2)
        out = self.run_job(NARRATIVE_PROJECTS="beta")
        self.assertEqual(list(out["projects"]), ["beta"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
