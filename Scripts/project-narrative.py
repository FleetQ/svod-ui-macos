#!/usr/bin/env python3
"""Svod — weekly per-project narrative (the EverOS "Reflection" idea, shaped for Svod).

Captured Claude Code sessions pile up in `messy/sessions/`, which search never reads. Once a week this
job folds each project's NEW sessions into one note, `narratives/<project-slug>.md`, which search does
read. Design: svod-engine `docs/design-evermind-borrow.md`.

    python3 Scripts/project-narrative.py                 # one run
    NARRATIVE_DRY_RUN=1 python3 Scripts/project-narrative.py   # print the plan, no model, no write

How it stays safe to run unattended:
  * The engine stays LLM-free. This script does the HTTP; `claude -p` only turns text into text
    (`--tools ""`): no file access, no network, nothing for a PreToolUse hook to intercept.
  * `SVOD_CAPTURE=off` for the model run, so the capture hook does not record it as a session.
  * `<private>` spans are removed before the model sees a session. The sessions are out of search;
    the narrative is in it, so this is where private text could otherwise leak.
  * The note is written with `PUT /api/v1/file`: the engine's secret scanner applies (422 ⇒ skipped)
    and every update is a git commit, which is the audit trail and the undo.
  * Incremental: the note records `covered_until`; only sessions that ended later are sent, together
    with the current narrative. Weekly at most — every merge by a model loses some detail.

Best-effort like recall-distill.sh: logs to ~/Library/Logs/svod/project-narrative.log, exits 0.
"""
import datetime as dt
import json
import os
import re
import signal
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROMPT_FILE = ROOT / ".claude/hooks/project-narrative-prompt.md"

# Sessions that are runs of our own headless jobs. The capture hook skips them since SVOD_CAPTURE
# exists, but 19 distiller runs were captured before that.
JOB_MARKERS = ("RUNTIME CONTEXT (this run)", "SVOD-NARRATIVE-JOB")
NOTE_DIR = "narratives"

# Scripts a Bulgarian or English narrative never contains. Measured on the first real run (Haiku,
# 2026-09-22): Chinese and Korean characters mid-sentence ("база知識", "两", "띠"). Same lesson as the
# GraphRAG summaries — the language is checked in code, not trusted to the prompt.
_FOREIGN_SCRIPT = re.compile(r"[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7af\uf900-\ufaff]")
# Letters Russian has and Bulgarian does not — the same run drifted into Russian words ("эта", "языци").
_RUSSIAN_ONLY = re.compile(r"[ыэёЫЭЁ]")
# A literal tag in the narrative is the NAME of the feature (Svod's own sessions discuss it), never
# private content — that was stripped before the model saw anything. Left as a tag, an unclosed
# `<private>` would make the engine hide the rest of the note from search, so it is rewritten.
_PRIVATE_TAG = re.compile(r"<(/?)private\s*>", re.IGNORECASE)
_PRIVATE = re.compile(r"<private>(?:.*?</private>|.*)", re.IGNORECASE | re.DOTALL)
_FRONTMATTER = re.compile(r"\A---\n.*?\n---\n?", re.DOTALL)


# ---------------------------------------------------------------- pure helpers (tested directly)

def slug(project):
    """The engine's SessionNotes.slug: lowercase, every character that is not a letter or digit → '-',
    leading/trailing '-' trimmed, at most 40 characters."""
    s = "".join(c if c.isalnum() else "-" for c in (project or "").lower()).strip("-")[:40]
    return s or "none"


def strip_private(text):
    """Same rule as the engine's MarkdownChunker.stripPrivateSpans: an unclosed tag drops the rest."""
    return _PRIVATE.sub("", text)


def split_frontmatter(text):
    """(frontmatter dict of simple `key: value` lines, body). Enough for the notes this job reads/writes."""
    m = _FRONTMATTER.match(text)
    if not m:
        return {}, text
    fm = {}
    for line in m.group(0).splitlines()[1:-1]:
        if ":" in line and not line.startswith((" ", "\t", "-")):
            k, v = line.split(":", 1)
            fm[k.strip()] = v.strip().strip('"').strip("'")
    return fm, text[m.end():]


def canonical_projects(labels):
    """Map each capture label to the project it belongs to. Sessions captured before 2026-09-17 are
    labelled with the directory name ("svod-ui-macos"), later ones with the git remote
    ("github.com/fleetq/svod-ui-macos"). A bare label folds into the remote label whose last segment
    it equals — only when exactly one such remote label exists, so an ambiguous name stays apart."""
    remote = [l for l in labels if "/" in l]
    out = {}
    for label in labels:
        if "/" in label:
            out[label] = label
            continue
        matches = [r for r in remote if r.rsplit("/", 1)[-1].lower() == label.lower()]
        out[label] = matches[0] if len(matches) == 1 else label
    return out


def is_job_run(body):
    return any(marker in body for marker in JOB_MARKERS)


def clip(text, limit):
    """A session longer than the whole budget keeps its start and (mostly) its end. Without this one huge
    session would fail the model call every week and hold the project's `covered_until` still for good."""
    if len(text) <= limit:
        return text
    head = limit // 4
    return text[:head] + "\n\n[… session shortened …]\n\n" + text[-(limit - head):]


def select_sessions(bodies, budget):
    """`bodies`: iterable of (meta, text), newest first; consumed lazily so a first run over hundreds of
    sessions reads only what fits. Keeps the newest that fit in `budget` bytes (at least one, clipped),
    returns them oldest first — the order the model folds them in."""
    kept, used = [], 0
    for meta, text in bodies:
        size = len(text.encode("utf-8"))
        if kept and used + size > budget:
            break
        if not kept and size > budget:
            text = clip(text, budget)
            size = len(text.encode("utf-8"))
        kept.append((meta, text))
        used += size
    return list(reversed(kept))


def build_prompt(template, project, language, current_body, sessions):
    newest = max((m["endedAt"] for m, _ in sessions), default=0)
    newest_day = dt.datetime.fromtimestamp(newest / 1000, dt.timezone.utc).strftime("%Y-%m-%d")
    filled = template.replace("{{PROJECT}}", project).replace("{{LANGUAGE}}", language).replace("{{NEWEST}}", newest_day)
    parts = [filled,
             "\n=== CURRENT NARRATIVE ===\n", current_body.strip() or "(none yet)",
             "\n\n=== NEW SESSIONS (oldest first) ===\n"]
    for meta, text in sessions:
        ended = dt.datetime.fromtimestamp(meta["endedAt"] / 1000, dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
        parts.append(f"\n--- session {meta.get('sessionId', '')[:8]} · ended {ended} ---\n{text.strip()}\n")
    return "".join(parts)


def valid_output(body, project, language="Bulgarian"):
    """(narrative, None) when the answer is a narrative for this project in the expected script, else
    (None, reason). A literal `<private>` tag is rewritten to `‹private›` (see _PRIVATE_TAG)."""
    b = _PRIVATE_TAG.sub(lambda m: f"‹{m.group(1)}private›", body.strip())
    if not b.splitlines() or b.splitlines()[0].strip() != f"# {project} — narrative":
        return None, "first line is not the narrative heading"
    if _FOREIGN_SCRIPT.search(b):
        return None, "contains CJK/Hangul characters"
    if language.lower() == "bulgarian" and _RUSSIAN_ONLY.search(b):
        return None, "contains Russian-only letters"
    return b + "\n", None


def render_note(project, body, covered_until, sessions_folded, today):
    fm = [
        "---",
        "type: narrative",
        f"project: {json.dumps(project)}",
        f"covered_until: {covered_until}",
        f"sessions_folded: {sessions_folded}",
        f"updated: {today}",
        "source: project-narrative",
        "---",
    ]
    return "\n".join(fm) + "\n" + body


# ---------------------------------------------------------------- engine I/O

class Engine:
    def __init__(self, base, vault, timeout=20):
        self.base, self.vault, self.timeout = base.rstrip("/"), vault, timeout

    def _url(self, route, **params):
        q = {"vault": self.vault, **params}
        return f"{self.base}{route}?{urllib.parse.urlencode(q)}"

    def _call(self, method, url, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method, headers={"content-type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                return r.status, json.loads(r.read() or b"null")
        except urllib.error.HTTPError as e:
            with e:
                raw = e.read()
            try:
                return e.code, json.loads(raw or b"null")
            except ValueError:
                return e.code, None

    def ready(self):
        try:
            with urllib.request.urlopen(f"{self.base}/ready", timeout=5) as r:
                return r.status == 200
        except (urllib.error.URLError, OSError, ValueError):
            return False

    def sessions(self):
        status, data = self._call("GET", self._url("/api/v1/memory/sessions"))
        return data if status == 200 and isinstance(data, list) else None

    def read(self, path):
        """(status, content, revision). 404 means the note does not exist; anything else but 200 is an
        error the caller must not mistake for "does not exist"."""
        status, data = self._call("GET", self._url("/api/v1/file", path=path))
        if status == 200 and isinstance(data, dict):
            return 200, data.get("content", ""), data.get("revision")
        return status, None, None

    def write(self, path, content, expected_revision):
        body = {"content": content}
        if expected_revision:
            body["expectedRevision"] = expected_revision
        return self._call("PUT", self._url("/api/v1/file", path=path), body)


# ---------------------------------------------------------------- model

def find_claude(env):
    explicit = env.get("CLAUDE_BIN")
    if explicit:
        return explicit
    # launchd gives a bare PATH, so look where `claude` is installed (same list as recall-distill.sh).
    home = Path.home()
    for c in (home / ".local/bin/claude", Path("/opt/homebrew/bin/claude"), Path("/usr/local/bin/claude"),
              home / ".claude/local/claude"):
        if os.access(c, os.X_OK):
            return str(c)
    from shutil import which
    return which("claude")


def run_model(claude, model, prompt, timeout):
    """stdin → stdout, no tools, not captured. Returns the text, or None on failure/timeout."""
    env = {**os.environ, "SVOD_CAPTURE": "off"}
    try:
        p = subprocess.run(
            [claude, "-p", "--model", model, "--tools", "", "--no-session-persistence", "--output-format", "text"],
            input=prompt, capture_output=True, text=True, timeout=timeout, env=env, cwd=str(ROOT),
        )
    except subprocess.TimeoutExpired:
        return None, "timed out"
    except OSError as e:
        return None, str(e)
    if p.returncode != 0:
        return None, f"exit {p.returncode}: {p.stderr.strip()[:200]}"
    return p.stdout, None


# ---------------------------------------------------------------- the run

def run(env, log):
    engine = Engine(env.get("SVOD_ENGINE", "http://127.0.0.1:7619"), env.get("SVOD_VAULT", "personal"))
    # Sonnet, not Haiku: the first real run with Haiku mixed scripts and confused versions (2026-09-22).
    model = env.get("NARRATIVE_MODEL", "sonnet")
    language = env.get("NARRATIVE_LANGUAGE", "Bulgarian")
    min_new = int(env.get("NARRATIVE_MIN_NEW", "2"))
    min_bytes = int(env.get("NARRATIVE_MIN_BYTES", "1000"))
    budget = int(env.get("NARRATIVE_BYTE_BUDGET", "300000"))
    timeout = int(env.get("NARRATIVE_TIMEOUT", "600"))
    only = {p.strip() for p in env.get("NARRATIVE_PROJECTS", "").split(",") if p.strip()}
    dry = env.get("NARRATIVE_DRY_RUN") == "1"
    # Rewrite from scratch: ignore the current narrative and `covered_until` (after a prompt or model
    # change). The previous version stays in git history.
    rebuild = env.get("NARRATIVE_REBUILD") == "1"
    today = env.get("NARRATIVE_TODAY") or dt.date.today().isoformat()

    if not engine.ready():
        log(f"engine {engine.base} not ready; skip")
        return {"status": "engine-down"}
    metas = engine.sessions()
    if metas is None:
        log("could not list sessions; skip")
        return {"status": "no-sessions-list"}

    claude = None if dry else find_claude(env)
    if not dry and not claude:
        log("claude CLI not found; skip")
        return {"status": "no-claude"}
    template = PROMPT_FILE.read_text(encoding="utf-8")

    canonical = canonical_projects({m["project"] for m in metas if m.get("project")})
    by_project = {}
    for m in metas:
        if m.get("project") and (m.get("bytes") or 0) >= min_bytes:
            by_project.setdefault(canonical[m["project"]], []).append(m)

    outcome = {"status": "ok", "projects": {}}
    for project in sorted(by_project):
        if only and project not in only:
            continue
        note_path = f"{NOTE_DIR}/{slug(project)}.md"
        status, current, revision = engine.read(note_path)
        if status not in (200, 404):
            # Not "missing": treating an unreadable note as new would rewrite it from scratch.
            log(f"{project}: could not read {note_path} (HTTP {status}); skip")
            outcome["projects"][project] = f"read-http-{status}"
            continue
        fm, current_body = split_frontmatter(current or "")
        covered = int(fm.get("covered_until") or 0)
        folded_before = int(fm.get("sessions_folded") or 0)
        if rebuild:
            current_body, covered, folded_before = "", 0, 0

        new = sorted((m for m in by_project[project] if m["endedAt"] > covered), key=lambda m: -m["endedAt"])
        if len(new) < min_new:
            outcome["projects"][project] = f"skip: {len(new)} new"
            continue

        def usable(sessions=new):
            for m in sessions:
                st, text, _ = engine.read(m["path"])
                if st != 200:
                    continue
                _, body = split_frontmatter(text)
                if is_job_run(body):
                    continue
                yield m, strip_private(body)

        chosen = select_sessions(usable(), budget)
        if not chosen:
            outcome["projects"][project] = "skip: nothing usable"
            continue
        newest = max(m["endedAt"] for m, _ in chosen)

        if dry:
            log(f"[dry] {project}: {len(chosen)} of {len(new)} new session(s) → {note_path}")
            outcome["projects"][project] = f"dry: {len(chosen)}"
            continue

        prompt = build_prompt(template, project, language, current_body, chosen)
        answer, err = run_model(claude, model, prompt, timeout)
        if answer is None:
            log(f"{project}: model failed ({err}); skip")
            outcome["projects"][project] = "model-failed"
            continue
        body, reason = valid_output(answer, project, language)
        if body is None:
            log(f"{project}: model output rejected ({reason}); skip")
            outcome["projects"][project] = "rejected"
            continue

        note = render_note(project, body, newest, folded_before + len(chosen), today)
        status, data = engine.write(note_path, note, revision)
        if status == 200:
            log(f"{project}: {note_path} updated with {len(chosen)} session(s), covered_until={newest}")
            outcome["projects"][project] = f"written: {len(chosen)}"
        elif status == 422:
            log(f"{project}: engine blocked the write (secret scan: {(data or {}).get('message', '')[:120]}); skip")
            outcome["projects"][project] = "blocked"
        elif status == 409:
            log(f"{project}: {note_path} changed since it was read; skip until next run")
            outcome["projects"][project] = "conflict"
        else:
            log(f"{project}: write failed with HTTP {status}; skip")
            outcome["projects"][project] = f"http-{status}"
    return outcome


def main():
    log_dir = Path(os.environ.get("NARRATIVE_LOG_DIR", str(Path.home() / "Library/Logs/svod")))
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_dir / "project-narrative.log"

    def log(msg):
        line = f"{dt.datetime.now():%Y-%m-%d %H:%M:%S} {msg}"
        with open(log_file, "a", encoding="utf-8") as f:
            f.write(line + "\n")
        if os.environ.get("NARRATIVE_DRY_RUN") == "1" or sys.stdout.isatty():
            print(line)

    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    log("project-narrative start")
    try:
        outcome = run(dict(os.environ), log)
        log(f"project-narrative done: {json.dumps(outcome, ensure_ascii=False)}")
    except Exception as e:  # a weekly launchd job must not crash-loop; the log says what happened
        log(f"project-narrative failed: {type(e).__name__}: {e}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
