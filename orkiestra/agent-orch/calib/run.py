"""Calibration runner: every task x every selected profile, scored by each task's own check.

  python3 -m calib.run --selfcheck                 # free: proves the checks (no agents run)
  python3 -m calib.run                             # dry run: shows the matrix and call count
  python3 -m calib.run --go --set hard --profiles a,b             # REAL agent calls (uses your quotas)
"""
import argparse, json, subprocess, tempfile, time
from pathlib import Path
from orch import probe
from orch.agents import run_agent
from orch.config import CFG
from .tasks import ALL, HARD, TASKS


def materialize(task, files=None):
    d = Path(tempfile.mkdtemp(prefix=f"calib-{task['id']}-"))
    for name, text in (task["files"] if files is None else files).items():
        (d / name).write_text(text)
    subprocess.run("git init -q && git add -A && git -c user.name=c -c user.email=c@c commit -qm init --allow-empty",
                   shell=True, cwd=d, capture_output=True)
    return d


def selfcheck():
    bad = 0
    for t in ALL:
        d = materialize(t)
        before, _ = t["check"](d)
        for n, text in t["solution"].items():
            if text is None:
                (d / n).unlink()
            else:
                (d / n).parent.mkdir(parents=True, exist_ok=True)
                (d / n).write_text(text)
        after, msg = t["check"](d)
        good = (not before) and after
        bad += not good
        print(f"{'OK ' if good else 'BAD'} {t['id']:10} fails-before={not before} passes-with-solution={after} {'' if good else msg}")
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--selfcheck", action="store_true")
    ap.add_argument("--go", action="store_true", help="actually call the agents")
    ap.add_argument("--profiles", help="comma list; default: all available")
    ap.add_argument("--tasks", help="comma list of task ids; default: the --set selection")
    ap.add_argument("--set", choices=["basic", "hard", "all"], default="basic")
    ap.add_argument("--timeout", type=int, default=300)
    a = ap.parse_args()
    if a.selfcheck:
        raise SystemExit(1 if selfcheck() else 0)
    avail = probe.available(force=True)
    profs = [p for p in (a.profiles.split(",") if a.profiles else avail) if p in avail]
    pool = {"basic": TASKS, "hard": HARD, "all": ALL}[a.set]
    tasks = [t for t in ALL if t["id"] in a.tasks.split(",")] if a.tasks else pool
    print(f"{len(tasks)} tasks x {len(profs)} profiles = {len(tasks) * len(profs)} agent calls")
    print("profiles:", ", ".join(profs))
    if not a.go:
        print("dry run; add --go to call the agents (uses quota)")
        return
    CFG["agent_timeout"] = a.timeout
    rows = []
    for t in tasks:
        for p in profs:
            d = materialize(t)
            t0 = time.time()
            code, _ = run_agent(CFG["profiles"][p], t["prompt"] + "\nWork only inside this directory.", d,
                                lambda l: None, lambda pr: None)
            ok, msg = t["check"](d)
            rows.append(dict(task=t["id"], profile=p, passed=ok, exit=code, secs=round(time.time() - t0), detail=msg))
            print(f"{'PASS' if ok else 'FAIL'} {t['id']:10} {p:20} {rows[-1]['secs']:4}s exit={code}")
    out = Path(__file__).parent / f"results-{int(time.time())}.json"
    out.write_text(json.dumps(rows, indent=1))
    print("saved", out.name)
    for p in profs:
        mine = [r for r in rows if r["profile"] == p]
        print(f"{p:20} {sum(r['passed'] for r in mine)}/{len(mine)} passed, {sum(r['secs'] for r in mine)}s total")


if __name__ == "__main__":
    main()
