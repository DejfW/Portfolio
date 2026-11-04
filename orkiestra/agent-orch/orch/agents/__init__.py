import json, os, signal, subprocess, threading, time
from ..config import CFG

def build_cmd(profile, prompt, wd, readonly=False):
    """Argv for one agent CLI. Flags verified against `--help` of claude 2.1.x, codex 0.165, agy.
    agy model ids already encode the effort level, so only claude/codex take a separate effort.
    readonly=True (reviewers) runs the agent without permission to edit files. Working agents run without
    permission prompts (nobody can answer them headless) so they can use skills, plugins and MCP tools on
    their own; they only ever work inside a throwaway worktree."""
    m, e = profile["model"], profile.get("effort") or ""
    if profile["agent"] == "claude":
        cmd = ["claude", "-p", prompt, "--output-format", "stream-json", "--verbose", "--model", m]
        cmd += ["--permission-mode", "plan"] if readonly else ["--dangerously-skip-permissions"]
        return cmd + (["--effort", e] if e else [])
    if profile["agent"] == "codex":
        cmd = ["codex", "exec", "--json", "-s", "read-only" if readonly else "workspace-write",
               "-C", str(wd), "-m", m]
        if not readonly:  # plugins (browser, documents, ...) and package installs need the network
            cmd += ["-c", "sandbox_workspace_write.network_access=true"]
        return cmd + (["-c", f'model_reasoning_effort="{e}"'] if e else []) + [prompt]
    # headless agy auto-denies every tool permission it cannot prompt for (it then exits 0 with an empty
    # response), so it needs the bypass flag; it only ever runs inside a throwaway worktree.
    if readonly:
        return ["agy", "-p", prompt, "--output-format", "stream-json", "--mode", "plan", "--model", m]
    return ["agy", "-p", prompt, "--output-format", "stream-json", "--mode", "accept-edits",
            "--dangerously-skip-permissions", "--model", m]


def _text_of(line):
    """Best-effort human text from one stream-json line (any of the three CLIs)."""
    try:
        j = json.loads(line)
    except ValueError:
        return line
    if not isinstance(j, dict):
        return line
    if isinstance(j.get("result"), str):
        return j["result"]
    item = j.get("item") or {}
    if item.get("text"):
        return item["text"]
    msg = j.get("message")
    if isinstance(msg, dict) and isinstance(msg.get("content"), list):
        return " ".join(c.get("text", "") for c in msg["content"] if isinstance(c, dict) and c.get("text"))
    return j.get("text") or j.get("content") if isinstance(j.get("text") or j.get("content"), str) else ""


def usage_of(line):
    """(output_tokens, cost_usd) reported by a final stream-json line (claude `result`, codex
    `turn.completed`, agy `{"event": "result", "result": {"usage": ...}}`); (0, 0.0) for other lines."""
    try:
        j = json.loads(line)
    except ValueError:
        return 0, 0.0
    if not isinstance(j, dict):
        return 0, 0.0
    if j.get("event") == "result" and isinstance(j.get("result"), dict):
        j = j["result"]
    elif j.get("type") not in ("result", "turn.completed"):
        return 0, 0.0
    u = j.get("usage") if isinstance(j.get("usage"), dict) else {}
    return int(u.get("output_tokens") or 0), float(j.get("total_cost_usd") or 0)


def kill_tree(p):
    """Kill an agent with everything it started (MCP servers, shells, test runners): killing only the CLI
    leaves children holding its stdout open, and reading it would hang until they exit on their own."""
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        p.kill()


def _watch_idle(p, seen, limit, stop):
    """Kill `p` when it printed nothing for `limit` seconds: a hung agent would otherwise hold its
    quota pool until the hard agent_timeout. seen[0] = time of the last line, seen[1] = killed-for-idle."""
    while not stop.wait(min(limit, 5)):
        if p.poll() is not None:
            return
        if time.time() - seen[0] > limit:
            seen[1] = True
            kill_tree(p)
            return


def run_agent(profile, prompt, workdir, on_line, register_proc, readonly=False, keep=2000):
    """Run one agent CLI in `workdir`. Returns (exit_code, summary): the last `keep` chars of the agent's
    final message (None = all of it). Kills on timeout, idle and cancel."""
    cmd = build_cmd(profile, prompt, workdir, readonly)
    p = subprocess.Popen(cmd, cwd=workdir, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, text=True, bufsize=1, start_new_session=True)
    register_proc(p)
    timer = threading.Timer(CFG["agent_timeout"], kill_tree, (p,))
    timer.start()
    seen, stop, idle = [time.time(), False], threading.Event(), CFG["agent_idle_timeout"]
    if idle:
        threading.Thread(target=_watch_idle, args=(p, seen, idle, stop), daemon=True).start()
    last = ""
    try:
        for line in p.stdout:
            seen[0] = time.time()
            line = line.rstrip("\n")
            on_line(line)
            t = _text_of(line)
            if t and t.strip():
                last = t.strip()
        p.wait()
    finally:
        timer.cancel()
        stop.set()
        p.stdout.close()
    if seen[1]:  # the reason reaches the retry prompt and the task summary
        last = f"agent produced no output for {idle} s and was killed. Last message: {last[-1500:]}"
        on_line(last)
    return p.returncode, last if keep is None else last[-keep:]
