#!/usr/bin/env python3
"""Sync LLVM branches from Android Googlesource to Alchemist-LLVM.

Clones source branches, rewrites committer information using git-filter-repo,
and pushes them in chunks to Alchemist-LLVM. Skips versions if there are no
new upstream commits since the last sync.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from typing import Final, Mapping, Sequence

# Ensure real-time flushed output in CI environments
if hasattr(sys.stdout, 'reconfigure'):
    try:
        sys.stdout.reconfigure(line_buffering=True)
        sys.stderr.reconfigure(line_buffering=True)
    except Exception:
        pass

SOURCE_LLVM_URL: Final[str] = 'https://android.googlesource.com/toolchain/llvm-project'
DEFAULT_TARGET_REPO: Final[str] = 'nekoshirro/Alchemist-LLVM'
DEFAULT_TARGET_USER: Final[str] = 'nekoshirro'
DEFAULT_AUTHOR_NAME: Final[str] = 'Hafidz Muzakky'
DEFAULT_AUTHOR_EMAIL: Final[str] = 'ais.muzakky@gmail.com'
DEFAULT_CHUNKS: Final[int] = 16

# Known stable fallbacks if remote head discovery fails
KNOWN_ANDROID_BRANCHES: Final[Mapping[str, str]] = {
    '19': 'llvm-r536225-release',
    '20': 'llvm-r547379-release',
    '21': 'mirror-goog-llvm-r574158-release',
    '22': 'mirror-goog-llvm-r596125-release',
    '23': 'mirror-google-llvm-r614150-release',
    '24': 'upstream-main',
}

# Known stable AndroidVersion.txt fallbacks if prebuilt discovery fails
KNOWN_ANDROID_VERSIONS: Final[Mapping[str, str]] = {
    '19': '19.0.0',
    '20': '20.0.0',
    '21': '21.0.0',
    '22': '22.0.2',
    '23': '23.0.1',
    '24': '24.0.0-rc1',
}


def sanitize(text: str, secret: str) -> str:
    """Mask secret token from string output."""
    if not secret:
        return text
    return text.replace(secret, '***')


def run_cmd(
    cmd: Sequence[str],
    cwd: Path | None = None,
    secret_to_mask: str = '',
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    """Execute a subprocess command cleanly and safely."""
    printable = [sanitize(arg, secret_to_mask) for arg in cmd]
    print(f"[CMD] {' '.join(printable)}")
    try:
        return subprocess.run(
            cmd,
            check=check,
            cwd=cwd,
            text=True,
            capture_output=False,
        )
    except subprocess.CalledProcessError as exc:
        msg = f"Command failed with exit code {exc.returncode}: {' '.join(printable)}"
        print(f"[ERROR] {msg}", file=sys.stderr)
        raise RuntimeError(msg) from exc


def get_cmd_output(cmd: Sequence[str], cwd: Path | None = None) -> str:
    """Execute a subprocess command and return stdout stripped."""
    result = subprocess.run(
        cmd,
        check=True,
        cwd=cwd,
        text=True,
        capture_output=True,
    )
    return result.stdout.strip()


def query_remote_heads(source_url: str) -> dict[str, str]:
    """Fetch remote branch heads and commit SHAs from source git repository."""
    try:
        raw = get_cmd_output(['git', 'ls-remote', '--heads', source_url])
        heads: dict[str, str] = {}
        for line in raw.splitlines():
            if '\t' in line:
                sha, ref = line.split('\t')
                branch_name = ref.replace('refs/heads/', '')
                heads[branch_name] = sha
        return heads
    except Exception as exc:  # noqa: BLE001
        print(f"[WARN] Failed to query remote heads from {source_url}: {exc}")
        return {}


def query_remote_tags(target_repo: str) -> dict[str, str]:
    """Fetch remote tags and commit SHAs from target repository."""
    target_url = f"https://github.com/{target_repo}.git"
    try:
        raw = get_cmd_output(['git', 'ls-remote', '--tags', target_url])
        tags: dict[str, str] = {}
        for line in raw.splitlines():
            if '\t' in line:
                sha, ref = line.split('\t')
                tag_name = ref.replace('refs/tags/', '').replace('^{}', '')
                tags[tag_name] = sha
        return tags
    except Exception as exc:  # noqa: BLE001
        print(f"[WARN] Failed to query remote tags from {target_url}: {exc}")
        return {}


def normalize_version(ver: str) -> str:
    """Normalize input like 'clang-22', 'v22', or single digit '2' -> '22'."""
    v = ver.strip().lower()
    if v.startswith('clang-'):
        v = v[6:]
    elif v.startswith('v'):
        v = v[1:]
    if v == '2':
        print("[INFO] Single digit '2' detected, auto-corrected to '22'.", flush=True)
        v = '22'
    return v


def resolve_branch_for_version(version: str, remote_heads: Mapping[str, str]) -> str | None:
    """Resolve the best matching android.googlesource.com branch for a Clang version."""
    fallback = KNOWN_ANDROID_BRANCHES.get(version)

    if version == '24':
        return 'upstream-main' if 'upstream-main' in remote_heads else (fallback or 'upstream-main')

    if fallback and fallback in remote_heads:
        return fallback

    if fallback:
        return fallback

    if version in remote_heads:
        return version

    return None


def clone_source_branch(source_url: str, branch: str, dest_dir: Path) -> None:
    """Clone a single branch from the source LLVM repo with live progress."""
    if dest_dir.exists():
        shutil.rmtree(dest_dir)
    print(f"\n[INFO] [STAGE 1/4] Cloning branch '{branch}' from {source_url}...", flush=True)
    run_cmd(
        [
            'git',
            'clone',
            '--progress',
            '--branch',
            branch,
            '--single-branch',
            source_url,
            str(dest_dir),
        ]
    )


def fetch_android_version(revision_or_branch: str) -> str | None:
    """Fetch version from AndroidVersion.txt on android.googlesource.com."""
    m = re.search(r'r\d+[a-z]?', revision_or_branch)
    if not m:
        return None
    rev = f'clang-{m.group(0)}'

    candidates = [
        f'https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+/refs/heads/main-kernel/{rev}/AndroidVersion.txt?format=TEXT',
        f'https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+/refs/heads/main/{rev}/AndroidVersion.txt?format=TEXT',
        f'https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+/refs/heads/mirror-goog-llvm-r596125-release/{rev}/AndroidVersion.txt?format=TEXT',
        f'https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+/{revision_or_branch}/{rev}/AndroidVersion.txt?format=TEXT',
    ]
    for url in candidates:
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
            with urllib.request.urlopen(req, timeout=5) as resp:
                raw = base64.b64decode(resp.read()).decode('utf-8', errors='replace')
                for line in raw.splitlines():
                    line = line.strip()
                    if re.match(r'^\d+\.\d+\.\d+', line):
                        return line.split()[0]
        except Exception:
            pass
    return None


def resolve_target_version(version: str, source_branch: str) -> str:
    """Resolve target version string following AndroidVersion.txt or fallback table."""
    if version == '24':
        return '24.0.0-rc1'

    fetched = fetch_android_version(source_branch)
    if fetched:
        print(f"[INFO] Discovered AOSP AndroidVersion.txt for Clang {version} ({source_branch}): {fetched}", flush=True)
        return fetched

    fallback = KNOWN_ANDROID_VERSIONS.get(version, f"{version}.0.0")
    print(f"[INFO] Using known AOSP version mapping for Clang {version}: {fallback}", flush=True)
    return fallback


def is_branch_configured_on_remote(
    target_repo: str,
    target_branch: str,
    version: str,
    target_version: str,
    token: str,
) -> tuple[bool, str]:
    """Check if remote branch on target_repo already has AndroidVersion.txt and LLVMVersion.cmake aligned."""
    if not token or not target_repo:
        return True, "No target repo or token to inspect remote branch"

    headers = {'Authorization': f'token {token}', 'Accept': 'application/vnd.github.v3.raw'}

    # 1. Check AndroidVersion.txt
    url_av = f"https://api.github.com/repos/{target_repo}/contents/AndroidVersion.txt?ref={target_branch}"
    req_av = urllib.request.Request(url_av, headers=headers)
    try:
        with urllib.request.urlopen(req_av, timeout=10) as resp:
            content_av = resp.read().decode('utf-8', errors='replace')
            first_line = content_av.splitlines()[0].strip() if content_av.splitlines() else ''
            if first_line != target_version:
                return False, f"AndroidVersion.txt version mismatch on remote ({first_line} != {target_version})"
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return False, "AndroidVersion.txt is missing on remote branch"
        return False, f"HTTP error checking AndroidVersion.txt: {e.code}"
    except Exception as e:
        return True, f"Could not verify remote branch: {e}"

    # 2. Check LLVMVersion.cmake suffix and version numbers
    url_cmake = f"https://api.github.com/repos/{target_repo}/contents/cmake/Modules/LLVMVersion.cmake?ref={target_branch}"
    req_cmake = urllib.request.Request(url_cmake, headers=headers)
    try:
        with urllib.request.urlopen(req_cmake, timeout=10) as resp:
            content_cmake = resp.read().decode('utf-8', errors='replace')
            parts = target_version.split('.')
            exp_major = parts[0]
            exp_minor = parts[1] if len(parts) > 1 else '0'
            exp_patch = parts[2].split('-')[0] if len(parts) > 2 else '0'
            exp_suffix = '-rc1' if version == '24' else '""'

            m_s = re.search(r'set\(LLVM_VERSION_SUFFIX\s+([^)]*)\)', content_cmake)
            if not m_s or m_s.group(1).strip() != exp_suffix:
                actual = m_s.group(1).strip() if m_s else 'None'
                return False, f"LLVM_VERSION_SUFFIX mismatch on remote ({actual} != {exp_suffix})"

            m_maj = re.search(r'set\(LLVM_VERSION_MAJOR\s+(\d+)\)', content_cmake)
            if not m_maj or m_maj.group(1).strip() != exp_major:
                actual = m_maj.group(1).strip() if m_maj else 'None'
                return False, f"LLVM_VERSION_MAJOR mismatch on remote ({actual} != {exp_major})"

            m_min = re.search(r'set\(LLVM_VERSION_MINOR\s+(\d+)\)', content_cmake)
            if not m_min or m_min.group(1).strip() != exp_minor:
                actual = m_min.group(1).strip() if m_min else 'None'
                return False, f"LLVM_VERSION_MINOR mismatch on remote ({actual} != {exp_minor})"

            m_pat = re.search(r'set\(LLVM_VERSION_PATCH\s+(\d+)\)', content_cmake)
            if not m_pat or m_pat.group(1).strip() != exp_patch:
                actual = m_pat.group(1).strip() if m_pat else 'None'
                return False, f"LLVM_VERSION_PATCH mismatch on remote ({actual} != {exp_patch})"

    except urllib.error.HTTPError as e:
        if e.code == 404:
            return False, "cmake/Modules/LLVMVersion.cmake missing on remote branch"
        return False, f"HTTP error checking LLVMVersion.cmake: {e.code}"
    except Exception as e:
        return True, f"Could not verify remote LLVMVersion.cmake: {e}"

    # 3. Check commit message prefix
    url_commit = f"https://api.github.com/repos/{target_repo}/commits/{target_branch}"
    req_commit = urllib.request.Request(
        url_commit,
        headers={'Authorization': f'token {token}', 'Accept': 'application/vnd.github.v3+json'},
    )
    try:
        with urllib.request.urlopen(req_commit, timeout=10) as resp:
            data_commit = json.loads(resp.read().decode('utf-8', errors='replace'))
            commit_title = data_commit.get('commit', {}).get('message', '').splitlines()[0]
            if not commit_title.startswith("Sync with upstream Google"):
                return False, f"Latest commit is '{commit_title}' (needs 'Sync with upstream Google...')"
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return False, f"Branch '{target_branch}' not found on remote"
    except Exception:
        pass

    return True, "Remote branch is properly configured"


def apply_android_version(
    repo_dir: Path, version: str, source_branch: str, upstream_sha: str = ''
) -> str:
    """Update cmake/Modules/LLVMVersion.cmake to match AndroidVersion.txt and remove git suffix."""
    print(
        f"[INFO] [STAGE 2/4] Aligning LLVM version with AndroidVersion.txt in cmake/Modules/LLVMVersion.cmake...",
        flush=True,
    )
    version_file = repo_dir / 'cmake' / 'Modules' / 'LLVMVersion.cmake'
    if not version_file.exists():
        print(f"[WARN] {version_file} not found, skipping version update.", flush=True)
        return '24.0.0-rc1' if version == '24' else f"{version}.0.0"

    target_version = resolve_target_version(version, source_branch)

    # For Clang 24 (upstream trunk), retain -rc1 suffix per convention
    if version == '24':
        major, minor, patch = '24', '0', '0'
        suffix_desc = '-rc1'
        suffix_cmake = 'set(LLVM_VERSION_SUFFIX -rc1)'
    else:
        parts = target_version.split('.')
        major = parts[0]
        minor = parts[1] if len(parts) > 1 else '0'
        patch = parts[2] if len(parts) > 2 else '0'
        suffix_desc = "''"
        suffix_cmake = 'set(LLVM_VERSION_SUFFIX "")'

    content = version_file.read_text(encoding='utf-8')
    new_content = content
    new_content = re.sub(
        r'set\(LLVM_VERSION_MAJOR\s+\d+\)',
        f'set(LLVM_VERSION_MAJOR {major})',
        new_content,
    )
    new_content = re.sub(
        r'set\(LLVM_VERSION_MINOR\s+\d+\)',
        f'set(LLVM_VERSION_MINOR {minor})',
        new_content,
    )
    new_content = re.sub(
        r'set\(LLVM_VERSION_PATCH\s+\d+\)',
        f'set(LLVM_VERSION_PATCH {patch})',
        new_content,
    )
    new_content = re.sub(
        r'set\(LLVM_VERSION_SUFFIX\s+[^)]*\)',
        suffix_cmake,
        new_content,
    )

    # Write or update AndroidVersion.txt at repo root
    android_version_file = repo_dir / 'AndroidVersion.txt'
    m = re.search(r'r\d+[a-z]?', source_branch)
    aosp_rev_tag = m.group(0) if m else ('upstream-main' if version == '24' else 'unknown')
    android_version_content = f"{target_version}\nbased on {aosp_rev_tag}\n"

    android_version_changed = False
    if not android_version_file.exists() or android_version_file.read_text(encoding='utf-8') != android_version_content:
        android_version_file.write_text(android_version_content, encoding='utf-8')
        android_version_changed = True

    if content == new_content and not android_version_changed:
        print(
            f"[INFO] {version_file} and AndroidVersion.txt already configured for {target_version} ({suffix_cmake}).",
            flush=True,
        )
        return target_version

    files_to_add = []
    if content != new_content:
        print(
            f"[INFO] Updating {version_file} to version {target_version} (Major={major}, Minor={minor}, Patch={patch}, Suffix={suffix_desc})...",
            flush=True,
        )
        version_file.write_text(new_content, encoding='utf-8')
        files_to_add.append(str(version_file.relative_to(repo_dir)))

    if android_version_changed:
        print(f"[INFO] Updating AndroidVersion.txt (based on {aosp_rev_tag})...", flush=True)
        files_to_add.append('AndroidVersion.txt')

    run_cmd(['git', 'add'] + files_to_add, cwd=repo_dir)

    sha_str = f" ({upstream_sha[:12]})" if upstream_sha else ""
    if version == '24':
        commit_title = f"Sync with upstream Google LLVM main (v{target_version})"
        commit_body = (
            f"Sync with upstream Google Android toolchain/llvm-project:\n"
            f"- Source branch: {source_branch}{sha_str}\n"
            f"- Configured version: {target_version}\n"
        )
    else:
        commit_title = f"Sync with upstream Google AOSP Clang {aosp_rev_tag} (v{target_version})"
        commit_body = (
            f"Sync with upstream Google Android toolchain/llvm-project:\n"
            f"- Source branch: {source_branch}{sha_str}\n"
            f"- Base revision: {aosp_rev_tag}\n"
            f"- Configured version: {target_version}\n"
        )

    commit_msg = (
        f"{commit_title}\n\n"
        f"{commit_body}\n"
        "Assisted-by: LLM (Gemini 4 Argon)\n"
        f"Signed-off-by: {DEFAULT_AUTHOR_NAME} <{DEFAULT_AUTHOR_EMAIL}>\n"
    )

    run_cmd(
        [
            'git',
            '-c',
            f'user.name={DEFAULT_AUTHOR_NAME}',
            '-c',
            f'user.email={DEFAULT_AUTHOR_EMAIL}',
            'commit',
            '-m',
            commit_msg,
        ],
        cwd=repo_dir,
    )
    return target_version


def rewrite_git_history(
    repo_dir: Path, author_name: str, author_email: str
) -> None:
    """Run git filter-repo to adjust committer and append Signed-off-by trailer."""
    print(
        f"[INFO] [STAGE 3/4] Rewriting history with git-filter-repo ({author_name} <{author_email}>)...",
        flush=True,
    )

    callback_code = f"""
commit.committer_name  = b"{author_name}"
commit.committer_email = b"{author_email}"
if not commit.message.endswith(b"\\n"):
    commit.message += b"\\n"
if b"Signed-off-by:" not in commit.message:
    commit.message += b"Signed-off-by: {author_name} <{author_email}>\\n"
"""

    run_cmd(
        ['git', 'filter-repo', '--force', '--commit-callback', callback_code],
        cwd=repo_dir,
    )


def get_chunk_commits(
    repo_dir: Path, total_commits: int, chunks: int
) -> list[tuple[int, str]]:
    """Retrieve commit hashes for chunk boundaries ordered topologically from root to HEAD.

    Uses `git rev-list --topo-order --reverse HEAD` in a single streaming pass to
    ensure commits are ordered chronologically from the initial commit forward,
    avoiding Git's --skip behavior which counts backwards from HEAD.
    """
    chunk_size = (total_commits + chunks - 1) // chunks
    target_indices = {
        i * chunk_size: i
        for i in range(1, chunks)
        if i * chunk_size < total_commits
    }

    if not target_indices:
        return []

    results: dict[int, str] = {}
    proc = subprocess.Popen(
        ['git', 'rev-list', '--topo-order', '--reverse', 'HEAD'],
        cwd=repo_dir,
        stdout=subprocess.PIPE,
        text=True,
    )
    assert proc.stdout is not None
    try:
        for idx, line in enumerate(proc.stdout, 1):
            if idx in target_indices:
                chunk_num = target_indices[idx]
                results[chunk_num] = line.strip()
                if len(results) == len(target_indices):
                    break
    finally:
        proc.stdout.close()
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()

    return [(i, results[i]) for i in sorted(results.keys())]


def push_with_retry(
    cmd: Sequence[str],
    cwd: Path,
    secret_token: str,
    max_retries: int = 4,
) -> None:
    """Run git push with automatic retry on transient HTTP 500 / timeout errors."""
    for attempt in range(1, max_retries + 1):
        try:
            run_cmd(cmd, cwd=cwd, secret_to_mask=secret_token)
            return
        except RuntimeError as exc:
            if attempt < max_retries:
                wait_time = attempt * 15
                print(
                    f"[WARN] Push attempt {attempt}/{max_retries} encountered an error. "
                    f"Retrying in {wait_time}s...",
                    flush=True,
                )
                time.sleep(wait_time)
            else:
                raise exc


def push_in_chunks(
    repo_dir: Path,
    branch_name: str,
    target_url: str,
    secret_token: str,
    chunks: int = DEFAULT_CHUNKS,
) -> None:
    """Push branch to target repository in chunks to prevent HTTP payload timeouts."""
    print(f"[INFO] [STAGE 4/4] Setting up remote target for branch '{branch_name}'...", flush=True)

    existing_remotes = get_cmd_output(['git', 'remote'], cwd=repo_dir).splitlines()
    if 'origin' in existing_remotes:
        run_cmd(['git', 'remote', 'remove', 'origin'], cwd=repo_dir)

    run_cmd(
        ['git', 'remote', 'add', 'origin', target_url],
        cwd=repo_dir,
        secret_to_mask=secret_token,
    )

    # Configure robust git HTTP settings for massive pushes
    run_cmd(['git', 'config', 'http.postBuffer', '1048576000'], cwd=repo_dir)
    run_cmd(['git', 'config', 'http.version', 'HTTP/1.1'], cwd=repo_dir)
    run_cmd(['git', 'config', 'core.compression', '9'], cwd=repo_dir)
    run_cmd(['git', 'config', 'http.lowSpeedLimit', '1000'], cwd=repo_dir)
    run_cmd(['git', 'config', 'http.lowSpeedTime', '600'], cwd=repo_dir)

    total_commits_str = get_cmd_output(['git', 'rev-list', '--count', 'HEAD'], cwd=repo_dir)
    total_commits = int(total_commits_str)
    chunk_size = (total_commits + chunks - 1) // chunks

    print(
        f"[INFO] Total commits: {total_commits}. Pushing in {chunks} chunks (~{chunk_size} commits/chunk)...",
        flush=True,
    )

    chunk_boundaries = get_chunk_commits(repo_dir, total_commits, chunks)

    for chunk_idx, target_commit in chunk_boundaries:
        print(f"[INFO] Pushing chunk {chunk_idx}/{chunks} (commit: {target_commit[:8]})...", flush=True)
        push_with_retry(
            [
                'git',
                'push',
                '--progress',
                '-u',
                'origin',
                f"{target_commit}:refs/heads/{branch_name}",
                '--force',
            ],
            cwd=repo_dir,
            secret_token=secret_token,
        )

    print(f"[INFO] Pushing final chunk ({chunks}/{chunks}) for branch '{branch_name}'...", flush=True)
    push_with_retry(
        [
            'git',
            'push',
            '--progress',
            '-u',
            'origin',
            f"refs/heads/{branch_name}:refs/heads/{branch_name}",
            '--force',
        ],
        cwd=repo_dir,
        secret_token=secret_token,
    )
    print(f"[SUCCESS] Successfully pushed branch '{branch_name}'!", flush=True)


def push_sync_tag(
    repo_dir: Path,
    version: str,
    upstream_sha: str,
    existing_tags: Mapping[str, str],
    secret_token: str,
) -> None:
    """Create and push sync tracking tag, and remove outdated sync tags for this version."""
    new_tag = f"synced-clang-{version}-{upstream_sha[:12]}"
    print(f"[INFO] Creating sync tracking tag '{new_tag}'...", flush=True)
    run_cmd(['git', 'tag', '-f', new_tag], cwd=repo_dir)
    push_with_retry(
        ['git', 'push', '--progress', '-u', 'origin', f"refs/tags/{new_tag}:refs/tags/{new_tag}", '--force'],
        cwd=repo_dir,
        secret_token=secret_token,
    )

    # Clean up older sync tags for this version
    old_tags = [
        tag
        for tag in existing_tags
        if tag.startswith(f"synced-clang-{version}-") and tag != new_tag
    ]
    for old_tag in old_tags:
        print(f"[INFO] Cleaning up outdated sync tag '{old_tag}' on remote...")
        run_cmd(
            ['git', 'push', 'origin', '--delete', old_tag],
            cwd=repo_dir,
            secret_to_mask=secret_token,
            check=False,
        )


def sync_single_version(
    version: str,
    source_url: str,
    source_branch: str,
    upstream_sha: str,
    target_repo: str,
    target_user: str,
    token: str,
    work_dir: Path,
    author_name: str,
    author_email: str,
    existing_tags: Mapping[str, str],
    chunks: int = DEFAULT_CHUNKS,
    dry_run: bool = False,
) -> None:
    """Perform complete sync cycle for a single Clang version."""
    target_branch = f"clang-{version}"
    version_dir = work_dir / f"llvm-{version}"

    print(f"\n{'=' * 60}")
    print(f" Starting sync for Clang {version}: {source_branch} ({upstream_sha[:12]}) -> {target_branch}")
    print(f"{'=' * 60}")

    target_version = resolve_target_version(version, source_branch)

    if dry_run:
        print(f"[DRY-RUN] Would clone {source_url} (branch: {source_branch}) to {version_dir}")
        print(f"[DRY-RUN] Would checkout branch '{target_branch}'")
        print(f"[DRY-RUN] Would update LLVM version to {target_version} in cmake/Modules/LLVMVersion.cmake")
        print(f"[DRY-RUN] Would rewrite history using git-filter-repo ({author_name} <{author_email}>)")
        print(f"[DRY-RUN] Would push in {chunks} chunks to https://{target_user}:***@github.com/{target_repo}.git")
        print(f"[DRY-RUN] Would push sync tag 'synced-clang-{version}-{upstream_sha[:12]}'")
        return

    try:
        clone_source_branch(source_url, source_branch, version_dir)

        # Checkout branch name
        run_cmd(['git', 'checkout', '-B', target_branch], cwd=version_dir)

        # Align LLVM version with AndroidVersion.txt without suffix for all versions
        apply_android_version(version_dir, version, source_branch, upstream_sha)

        # Run filter-repo
        rewrite_git_history(version_dir, author_name, author_email)

        target_url = f"https://{target_user}:{token}@github.com/{target_repo}.git"
        push_in_chunks(version_dir, target_branch, target_url, token, chunks=chunks)
        push_sync_tag(version_dir, version, upstream_sha, existing_tags, token)

    finally:
        if version_dir.exists():
            print(f"[INFO] Cleaning up {version_dir} to free disk space...")
            shutil.rmtree(version_dir, ignore_errors=True)


def parse_arguments() -> argparse.Namespace:
    """Parse CLI arguments."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        '--versions',
        nargs='+',
        default=['21', '22', '23', '24'],
        help='Clang versions to sync (default: 21 22 23 24)',
    )
    parser.add_argument(
        '--chunks',
        type=int,
        default=DEFAULT_CHUNKS,
        help=f'Number of chunks to split push operations into (default: {DEFAULT_CHUNKS})',
    )
    parser.add_argument(
        '--source-url',
        default=SOURCE_LLVM_URL,
        help=f"Source LLVM repo (default: {SOURCE_LLVM_URL})",
    )
    parser.add_argument(
        '--target-repo',
        default=DEFAULT_TARGET_REPO,
        help=f"Target GitHub repo (default: {DEFAULT_TARGET_REPO})",
    )
    parser.add_argument(
        '--target-user',
        default=DEFAULT_TARGET_USER,
        help=f"Target GitHub user (default: {DEFAULT_TARGET_USER})",
    )
    parser.add_argument(
        '--token',
        default=os.environ.get('LLVM_PUSH_TOKEN')
        or os.environ.get('PAT_TOKEN')
        or os.environ.get('GH_TOKEN')
        or '',
        help='GitHub PAT with repo write permission',
    )
    parser.add_argument(
        '--author-name',
        default=DEFAULT_AUTHOR_NAME,
        help=f"Committer name (default: {DEFAULT_AUTHOR_NAME})",
    )
    parser.add_argument(
        '--author-email',
        default=DEFAULT_AUTHOR_EMAIL,
        help=f"Committer email (default: {DEFAULT_AUTHOR_EMAIL})",
    )
    parser.add_argument(
        '--work-dir',
        type=Path,
        default=Path('./.sync_work'),
        help='Working directory for cloning repos',
    )
    parser.add_argument(
        '--dry-run',
        action='store_true',
        help='Plan and check commits without cloning or pushing',
    )
    parser.add_argument(
        '--force',
        action='store_true',
        help='Force sync even if upstream has no new commits',
    )
    return parser.parse_args()


def main() -> None:
    """Main execution function."""
    args = parse_arguments()

    if not args.dry_run and not args.token:
        print(
            "[ERROR] GitHub PAT is required! Pass --token or set LLVM_PUSH_TOKEN / PAT_TOKEN.",
            file=sys.stderr,
        )
        sys.exit(1)

    args.work_dir.mkdir(parents=True, exist_ok=True)

    print("[INFO] Querying remote heads from source repository...")
    remote_heads = query_remote_heads(args.source_url)
    print(f"[INFO] Found {len(remote_heads)} remote heads.")

    print(f"[INFO] Querying existing tags from target repository ({args.target_repo})...")
    existing_tags = query_remote_tags(args.target_repo)
    print(f"[INFO] Found {len(existing_tags)} tags on target repository.")

    for raw_version in args.versions:
        version = normalize_version(raw_version)
        source_branch = resolve_branch_for_version(version, remote_heads)
        if not source_branch:
            print(f"\n{'=' * 60}", flush=True)
            print(f" [WARN] Clang version '{raw_version}' is not recognized or available in Android LLVM.", flush=True)
            print(f" Supported versions: {', '.join(sorted(KNOWN_ANDROID_BRANCHES.keys()))}. Skipping!", flush=True)
            print(f"{'=' * 60}", flush=True)
            continue

        upstream_sha = remote_heads.get(source_branch, '')

        target_version = resolve_target_version(version, source_branch)

        # Check if version is already synced
        expected_tag = f"synced-clang-{version}-{upstream_sha[:12]}"
        is_synced = bool(upstream_sha and (expected_tag in existing_tags))

        # Verify remote branch has correct AndroidVersion.txt and LLVMVersion.cmake configuration
        target_branch = f"clang-{version}"
        is_configured = True
        config_reason = ""
        if not args.dry_run and args.token:
            is_configured, config_reason = is_branch_configured_on_remote(
                target_repo=args.target_repo,
                target_branch=target_branch,
                version=version,
                target_version=target_version,
                token=args.token,
            )

        if is_synced and is_configured and not args.force:
            print(f"\n{'=' * 60}")
            print(f" ⏭️  [SKIP] Clang {version}: Up-to-date with '{source_branch}' ({upstream_sha[:12]}).")
            print(f" Already synced in tag '{expected_tag}' and remote branch '{target_branch}' is properly configured. Skipping!")
            print(f"{'=' * 60}")
            continue

        if is_synced and not is_configured:
            print(
                f"\n[INFO] Clang {version}: Triggering sync because remote branch '{target_branch}' is not properly configured ({config_reason}).",
                flush=True,
            )

        sync_single_version(
            version=version,
            source_url=args.source_url,
            source_branch=source_branch,
            upstream_sha=upstream_sha,
            target_repo=args.target_repo,
            target_user=args.target_user,
            token=args.token,
            work_dir=args.work_dir,
            author_name=args.author_name,
            author_email=args.author_email,
            existing_tags=existing_tags,
            chunks=args.chunks,
            dry_run=args.dry_run,
        )

    # Clean up working directory
    shutil.rmtree(args.work_dir, ignore_errors=True)
    print("\n[DONE] All requested LLVM branches evaluated successfully.")


if __name__ == '__main__':
    main()
