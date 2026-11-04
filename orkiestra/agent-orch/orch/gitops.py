import shutil, subprocess
from pathlib import Path


def git(cwd, *args, check=True):
    r = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True)
    if check and r.returncode:
        raise RuntimeError(f"git {' '.join(args)}: {r.stderr.strip() or r.stdout.strip()}")
    return r


def ensure_repo(repo):
    p = Path(repo).expanduser().resolve()
    if git(p, "rev-parse", "--git-dir", check=False).returncode:
        raise RuntimeError(f"{p} is not a git repository")
    if git(p, "rev-parse", "HEAD", check=False).returncode:
        raise RuntimeError("repository has no commits")
    # keep orchestrator state out of the user's `git status`
    ex = p / ".git" / "info" / "exclude"
    if ".orch/" not in ex.read_text():
        ex.write_text(ex.read_text() + "\n.orch/\n")
    return p


def branch_exists(repo, branch):
    return git(repo, "rev-parse", "--verify", "-q", f"refs/heads/{branch}", check=False).returncode == 0


def add_worktree(repo, path, branch, base, reuse=False):
    """Check `branch` out in a new worktree at `path`. Default: (re)create it from `base`.
    reuse=True keeps the branch's existing commits (used to resume a run's integration branch).
    A leftover worktree from a crashed process is cleaned up first."""
    path = Path(path)
    if path.exists():
        remove_worktree(repo, path)
        shutil.rmtree(path, ignore_errors=True)
    git(repo, "worktree", "prune", check=False)
    path.parent.mkdir(parents=True, exist_ok=True)
    if reuse and branch_exists(repo, branch):
        git(repo, "worktree", "add", str(path), branch)
    else:
        git(repo, "worktree", "add", "-B", branch, str(path), base)


def remove_worktree(repo, path):
    git(repo, "worktree", "remove", "--force", str(path), check=False)


def commit_all(wt, msg):
    git(wt, "add", "-A")
    if git(wt, "diff", "--cached", "--quiet", check=False).returncode:
        git(wt, "-c", "user.name=orch", "-c", "user.email=orch@localhost", "commit", "-m", msg)
        return True
    return False


def diff_vs(wt, base):
    return git(wt, "diff", f"{base}...HEAD").stdout


def merge(wt, branch, msg):
    """Merge `branch` into the branch checked out in `wt`. Returns True, or False on conflict
    (merge left in progress so a resolver can finish it)."""
    r = git(wt, "-c", "user.name=orch", "-c", "user.email=orch@localhost",
            "merge", "--no-ff", "-m", msg, branch, check=False)
    return r.returncode == 0


def merge_abort(wt):
    git(wt, "merge", "--abort", check=False)


def has_conflicts(wt):
    return bool(git(wt, "diff", "--name-only", "--diff-filter=U").stdout.strip())


def head(wt):
    return git(wt, "rev-parse", "HEAD").stdout.strip()


def diff_stat(wt, base):
    return git(wt, "diff", "--stat", f"{base}...HEAD").stdout
