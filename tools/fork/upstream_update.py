#!/usr/bin/env python3
"""Open a reviewed stable-release update; never force-push or merge a PR."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

UPSTREAM = "altic-dev/FluidVoice"
FORK = "renato-dransay/FluidVoice"
BASE = "personal"


def run(*args, check=True):
    result = subprocess.run(args, text=True, capture_output=True, check=False)
    if check and result.returncode:
        raise RuntimeError(f"{args[0]} failed: {result.stderr.strip()}")
    return result


def git(*args):
    return run("git", *args).stdout.strip()


def ancestor(older, newer):
    result = run("git", "merge-base", "--is-ancestor", older, newer, check=False)
    if result.returncode not in (0, 1):
        raise RuntimeError(result.stderr.strip())
    return result.returncode == 0


def candidate_status(baseline, release, upstream_main, personal):
    if ancestor(release, personal):
        return "included"
    if not ancestor(baseline, release) or not ancestor(release, upstream_main):
        return "divergent"
    return "eligible"


def update_branch(tag):
    return "upstream-update/" + hashlib.sha256(tag.encode()).hexdigest()[:16]


def duplicate_pull_request(pulls, branch):
    return next((pr for pr in pulls if pr["headRefName"] == branch), None)


def merge_candidate(personal, release, branch):
    git("switch", "-c", branch, personal)
    result = run("git", "merge", "--no-ff", "--no-edit", release, check=False)
    if result.returncode:
        conflicts = git("diff", "--name-only", "--diff-filter=U")
        git("merge", "--abort")
        raise RuntimeError("Upstream merge requires manual resolution:\n" + (conflicts or result.stderr))
    return git("rev-parse", "HEAD")


def gh_json(*args):
    return json.loads(run("gh", *args).stdout)


def create_issue(title, body):
    issues = gh_json("issue", "list", "--repo", FORK, "--state", "open", "--limit", "500", "--json", "title")
    if any(issue["title"] == title for issue in issues):
        print("Existing issue: " + title)
        return
    with tempfile.NamedTemporaryFile(mode="w", suffix=".md") as draft:
        draft.write(body)
        draft.flush()
        print(run("gh", "issue", "create", "--repo", FORK, "--title", title, "--body-file", draft.name).stdout.strip())


def main():
    if os.environ.get("GITHUB_REPOSITORY", FORK) != FORK:
        raise RuntimeError("This workflow is restricted to the personal fork.")
    if git("status", "--porcelain"):
        raise RuntimeError("Use a clean checkout for upstream synchronization.")
    baseline = (Path(__file__).parent / "upstream-baseline.txt").read_text().strip()
    release = gh_json("api", f"repos/{UPSTREAM}/releases/latest")
    if release.get("draft") or release.get("prerelease"):
        raise RuntimeError("GitHub returned a non-stable release.")
    tag = release["tag_name"]
    branch = update_branch(tag)
    git("check-ref-format", "refs/tags/" + tag)
    git("remote", "set-url", "origin", f"https://github.com/{FORK}.git")
    if "upstream" not in git("remote").splitlines():
        git("remote", "add", "upstream", f"https://github.com/{UPSTREAM}.git")
    git("fetch", "--no-tags", "origin", "main", BASE)
    git("fetch", "--no-tags", "upstream", "main")
    release_ref = "refs/remotes/upstream/releases/" + branch.split("/")[-1]
    git("fetch", "--no-tags", "upstream", f"refs/tags/{tag}:{release_ref}")
    release_sha = git("rev-parse", release_ref + "^{commit}")
    if not ancestor("origin/main", "upstream/main"):
        create_issue("Upstream main mirror diverged", "The fork main branch cannot fast-forward to upstream/main. Resolve history manually; no force-push was attempted.")
        raise RuntimeError("Upstream main mirror diverged.")
    if git("rev-parse", "origin/main") != git("rev-parse", "upstream/main"):
        git("push", "origin", "upstream/main:refs/heads/main")
    state = candidate_status(baseline, release_sha, "upstream/main", f"origin/{BASE}")
    if state == "included":
        print(f"{tag} is already included in {BASE}; no update needed.")
        return
    if state == "divergent":
        create_issue(f"Review divergent upstream release {tag}", f"Release `{tag}` (`{release_sha}`) does not descend from the initial baseline or is outside upstream/main. Review its ancestry before integrating it.")
        raise RuntimeError("Release history diverged; manual review required.")
    pulls = gh_json("pr", "list", "--repo", FORK, "--state", "all", "--head", branch, "--limit", "100", "--json", "headRefName,url,state")
    existing = duplicate_pull_request(pulls, branch)
    if existing:
        print("Existing update pull request: " + existing["url"])
        if existing["state"] == "OPEN":
            run("gh", "workflow", "run", "fork-ci.yml", "--repo", FORK, "--ref", branch)
        return
    git("config", "user.name", "github-actions[bot]")
    git("config", "user.email", "41898282+github-actions[bot]@users.noreply.github.com")
    try:
        if run("git", "ls-remote", "--exit-code", "--heads", "origin", branch, check=False).returncode == 0:
            git("fetch", "origin", branch)
            candidate_sha = git("rev-parse", f"origin/{branch}")
            if not ancestor(release_sha, candidate_sha) or not ancestor(f"origin/{BASE}", candidate_sha):
                raise RuntimeError("Existing update branch is stale or unrelated; review it manually.")
        else:
            candidate_sha = merge_candidate(f"origin/{BASE}", release_sha, branch)
            git("push", "origin", f"HEAD:refs/heads/{branch}")
    except RuntimeError as error:
        create_issue(f"Resolve upstream update {tag}", f"Release `{tag}` needs manual integration into `{BASE}`.\n\n```text\n{error}\n```\n")
        raise
    body = f"Integrates upstream stable release [{tag}]({release['html_url']}) into the personal fork.\n\nUpstream commit: `{release_sha}`. Candidate: `{candidate_sha}`.\n\nFork checks are dispatched explicitly because GITHUB_TOKEN-created pull requests do not trigger ordinary pull_request workflows. Review the merge, require green checks, then validate a signed local build before installation. No automatic merge or binary installation occurs."
    with tempfile.NamedTemporaryFile(mode="w", suffix=".md") as draft:
        draft.write(body)
        draft.flush()
        print(run("gh", "pr", "create", "--repo", FORK, "--base", BASE, "--head", branch, "--title", f"Update upstream to {tag}", "--body-file", draft.name).stdout.strip())
    run("gh", "workflow", "run", "fork-ci.yml", "--repo", FORK, "--ref", branch)
    print("Dispatched fork checks for " + candidate_sha)


if __name__ == "__main__":
    main()
