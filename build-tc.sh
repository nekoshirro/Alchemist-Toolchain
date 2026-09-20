#!/usr/bin/env bash
#
# Alchemist LLVM toolchain build script.
# Builds clang/LLVM (+ binutils, + a sample kernel build) and publishes the
# resulting toolchain to GitHub Releases.
#
# This script never calls sudo / apt-get install. When a required tool or
# header is missing it first tries to resolve it *without root* (pinned
# upstream prebuilt binaries for cmake/ninja/gh, or `apt-get download` +
# `dpkg -x` into a local prefix for everything else) before giving up on it.
# Only what truly can't be resolved that way is reported as fatal.

set -euo pipefail

if [ -f "$HOME/.secrets" ]; then
    source "$HOME/.secrets"
else
    echo "File .secrets not found in $HOME"
fi

if [ -f "$(pwd)/.secrets" ]; then
    source "$(pwd)/.secrets"
else
    echo "File .secrets not found in $(pwd)"
fi

msg() {
    echo -e "\e[1;32m$*\e[0m"
}

err() {
    echo -e "\e[1;41m$*\e[0m" >&2
}

# ==== Per-version config ====
LLVM_NAME="🧪Alchemist LLVM"
LLVM_REF="clang-23"                       # branch of the LLVM source fork to build (clang-21/22/23/24)
GH_OWNER="nekoshirro"
LLVM_REPO="Alchemist-LLVM"                # source fork AND github release target
GH_REPO="$GH_OWNER/$LLVM_REPO"            # owner/repo, used by gh cli
REPO_URL="https://github.com/$GH_REPO"

# Pinned versions used for the no-sudo portable fallbacks. Bump these
# occasionally; pinning (instead of "latest") keeps the fallback
# reproducible and avoids needing a JSON parser to hit a "latest" API.
CMAKE_PORTABLE_VERSION="3.31.4"
NINJA_PORTABLE_VERSION="1.12.1"
GH_CLI_PORTABLE_VERSION="2.63.0"

TG_TOKEN="${TG_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
GH_TOKEN="${GH_TOKEN:-}"

TG_NOTIFY=1
if [[ -z "$TG_TOKEN" || -z "$TG_CHAT_ID" ]]; then
    TG_NOTIFY=0
    err "$LLVM_NAME: TG_TOKEN or TG_CHAT_ID is not set. Telegram notifications are disabled for this run."
fi

BOT_MSG_URL="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"

tg_post_msg() {
    [[ "$TG_NOTIFY" -eq 1 ]] || return 0
    curl -s -X POST "$BOT_MSG_URL" -d chat_id="$TG_CHAT_ID" \
        -d "disable_web_page_preview=true" \
        -d "parse_mode=html" \
        -d text="$1" >/dev/null || true
}

tg_post_build() {
    [[ "$TG_NOTIFY" -eq 1 ]] || return 0
    curl --progress-bar -F document=@"$1" "$BOT_MSG_URL" \
        -F chat_id="$TG_CHAT_ID" \
        -F "disable_web_page_preview=true" \
        -F "parse_mode=html" \
        -F caption="${2:-}" || true
}

base=$(dirname "$(readlink -f "$0")")
install="$base/install"
src="$base/src"

# ==== Local (no-sudo) dependency prefix ====
# Anything fetched by the portable fallbacks below lands here, never in a
# system path. This is set up unconditionally (not just inside do_deps) so
# tools resolved on a previous run, or via `./build-tc.sh deps`, are still
# picked up when a later invocation only runs `llvm`, `binutils`, etc.
LOCAL_PREFIX="$base/local-deps"
LOCAL_BIN="$LOCAL_PREFIX/bin"
LOCAL_LIB="$LOCAL_PREFIX/lib"
LOCAL_INCLUDE="$LOCAL_PREFIX/include"
LOCAL_TMP="$LOCAL_PREFIX/.tmp"
mkdir -p "$LOCAL_BIN" "$LOCAL_LIB" "$LOCAL_INCLUDE" "$LOCAL_TMP"

export PATH="$LOCAL_BIN:$PATH"
export LD_LIBRARY_PATH="$LOCAL_LIB:${LD_LIBRARY_PATH:-}"
export LIBRARY_PATH="$LOCAL_LIB:${LIBRARY_PATH:-}"
export CPATH="$LOCAL_INCLUDE:${CPATH:-}"
export PKG_CONFIG_PATH="$LOCAL_LIB/pkgconfig:${PKG_CONFIG_PATH:-}"
for d in "$LOCAL_LIB"/*/; do
    [[ -d "$d" ]] && export LD_LIBRARY_PATH="${d%/}:$LD_LIBRARY_PATH"
done

# Build Info
rel_date="$(date "+%Y%m%d")"               # ISO 8601 format
rel_friendly_date="$(date "+%B %-d, %Y")"  # "Month day, year" format

if git -C "$base" rev-parse HEAD &>/dev/null; then
    builder_commit="$(git -C "$base" rev-parse HEAD)"
else
    builder_commit="unknown"
    err "$LLVM_NAME: $base is not a git checkout. Builder commit link in release notes will be omitted."
fi

function parse_parameters() {
    while (($#)); do
        case $1 in
            all | binutils | deps | kernel | llvm) action=$1 ;;
            *)
                err "$LLVM_NAME: Unknown argument: $1"
                exit 33
                ;;
        esac
        shift
    done
}

function do_all() {
    do_deps
    do_llvm
    do_binutils
    do_kernel
}

function do_binutils() {
    msg "$LLVM_NAME: Building binutils..."
    tg_post_msg "<b>$LLVM_NAME: Building Binutils. . .</b>"
    "$base"/build-binutils.py \
        --install-folder "$install" \
        --show-build-commands \
        --targets arm aarch64 x86_64
}

# ---- Portable (no-root) dependency resolution helpers ----

host_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) echo x86_64 ;;
        aarch64 | arm64) echo aarch64 ;;
        *) uname -m ;;
    esac
}

# Official prebuilt cmake tarball. No compiler needed, unlike building cmake
# from its own source (which needs a bootstrap toolchain and takes much
# longer) -- more reliable for a one-shot run.
fetch_portable_cmake() {
    local arch url extracted
    arch="$(host_arch)"
    case "$arch" in
        x86_64 | aarch64) : ;;
        *) return 1 ;;
    esac
    url="https://github.com/Kitware/CMake/releases/download/v${CMAKE_PORTABLE_VERSION}/cmake-${CMAKE_PORTABLE_VERSION}-linux-${arch}.tar.gz"
    msg "$LLVM_NAME: Fetching portable cmake $CMAKE_PORTABLE_VERSION ($arch)..."
    curl -fsSL "$url" -o "$LOCAL_TMP/cmake.tar.gz" || return 1
    tar -xzf "$LOCAL_TMP/cmake.tar.gz" -C "$LOCAL_TMP" || return 1
    extracted="$(find "$LOCAL_TMP" -maxdepth 1 -type d -name 'cmake-*' | head -n1)"
    [[ -n "$extracted" ]] || return 1
    mkdir -p "$LOCAL_PREFIX/share"
    cp -r "$extracted"/bin/. "$LOCAL_BIN/"
    cp -r "$extracted"/share/. "$LOCAL_PREFIX/share/" 2>/dev/null || true
    rm -rf "${LOCAL_TMP:?}"/*
    command -v cmake &>/dev/null
}

# Official prebuilt ninja binary (single static executable).
fetch_portable_ninja() {
    local arch url
    arch="$(host_arch)"
    case "$arch" in
        x86_64) url="https://github.com/ninja-build/ninja/releases/download/v${NINJA_PORTABLE_VERSION}/ninja-linux.zip" ;;
        aarch64) url="https://github.com/ninja-build/ninja/releases/download/v${NINJA_PORTABLE_VERSION}/ninja-linux-aarch64.zip" ;;
        *) return 1 ;;
    esac
    msg "$LLVM_NAME: Fetching portable ninja $NINJA_PORTABLE_VERSION ($arch)..."
    curl -fsSL "$url" -o "$LOCAL_TMP/ninja.zip" || return 1
    if command -v unzip &>/dev/null; then
        ( cd "$LOCAL_TMP" && unzip -qo ninja.zip ) || return 1
    else
        python3 -c "import zipfile; zipfile.ZipFile('$LOCAL_TMP/ninja.zip').extractall('$LOCAL_TMP')" || return 1
    fi
    [[ -f "$LOCAL_TMP/ninja" ]] || return 1
    cp "$LOCAL_TMP/ninja" "$LOCAL_BIN/ninja"
    chmod +x "$LOCAL_BIN/ninja"
    rm -rf "${LOCAL_TMP:?}"/*
    command -v ninja &>/dev/null
}

# Official prebuilt gh CLI tarball.
fetch_portable_gh() {
    local arch dl_arch url extracted
    arch="$(host_arch)"
    case "$arch" in
        x86_64) dl_arch="amd64" ;;
        aarch64) dl_arch="arm64" ;;
        *) return 1 ;;
    esac
    url="https://github.com/cli/cli/releases/download/v${GH_CLI_PORTABLE_VERSION}/gh_${GH_CLI_PORTABLE_VERSION}_linux_${dl_arch}.tar.gz"
    msg "$LLVM_NAME: Fetching portable gh CLI $GH_CLI_PORTABLE_VERSION ($dl_arch)..."
    curl -fsSL "$url" -o "$LOCAL_TMP/gh.tar.gz" || return 1
    tar -xzf "$LOCAL_TMP/gh.tar.gz" -C "$LOCAL_TMP" || return 1
    extracted="$(find "$LOCAL_TMP" -maxdepth 1 -type d -name 'gh_*' | head -n1)"
    [[ -n "$extracted" ]] || return 1
    cp "$extracted"/bin/gh "$LOCAL_BIN/gh"
    chmod +x "$LOCAL_BIN/gh"
    rm -rf "${LOCAL_TMP:?}"/*
    command -v gh &>/dev/null
}

# Generic no-root fallback for anything without a dedicated fetcher above:
# `apt-get download <pkg>` fetches the .deb into the current directory
# without needing root, and `dpkg -x` unpacks it into an arbitrary folder --
# neither step touches the system or installs anything system-wide.
fetch_via_apt_download() {
    local pkg="$1"
    command -v apt-get &>/dev/null || return 1
    command -v dpkg &>/dev/null || return 1
    ( cd "$LOCAL_TMP" && apt-get download "$pkg" ) &>/dev/null || return 1
    local deb
    deb="$(find "$LOCAL_TMP" -maxdepth 1 -name '*.deb' | head -n1)"
    [[ -n "$deb" ]] || return 1
    dpkg -x "$deb" "$LOCAL_TMP/extract" &>/dev/null || return 1
    [[ -d "$LOCAL_TMP/extract/usr" ]] || return 1
    cp -rn "$LOCAL_TMP/extract/usr/." "$LOCAL_PREFIX/" 2>/dev/null || true
    for d in "$LOCAL_LIB"/*/; do
        [[ -d "$d" ]] && export LD_LIBRARY_PATH="${d%/}:$LD_LIBRARY_PATH"
    done
    rm -rf "${LOCAL_TMP:?}"/*
    return 0
}

resolve_missing_bin() {
    local bin="$1"
    case "$bin" in
        cmake) fetch_portable_cmake && return 0 ;;
        ninja) fetch_portable_ninja && return 0 ;;
        gh) fetch_portable_gh && return 0 ;;
    esac
    local apt_pkg="$bin"
    case "$bin" in
        xz) apt_pkg="xz-utils" ;;
        makeinfo) apt_pkg="texinfo" ;;
    esac
    fetch_via_apt_download "$apt_pkg" && command -v "$bin" &>/dev/null
}

resolve_missing_header() {
    fetch_via_apt_download "$1"
}

function bolt_supported() {
    if [[ -f "$base/.bolt_enabled" ]]; then
        [[ "$(cat "$base/.bolt_enabled")" == "1" ]]
    else
        command -v perf &>/dev/null
    fi
}

# Checks required tools/headers, tries the portable fallbacks above for
# anything missing, and only exits non-zero if something is still missing
# after that. --bolt (perf) is soft: it's disabled instead of failing the
# whole run, since perf is tied to the exact running kernel and has no
# generic no-root fallback.
function do_deps() {
    local required_bins=(
        bc bison cmake curl file flex gcc g++ git make ninja python3
        makeinfo xz gh
    )
    local still_missing_bins=()
    for bin in "${required_bins[@]}"; do
        if command -v "$bin" &>/dev/null; then
            continue
        fi
        msg "$LLVM_NAME: $bin not found, trying a portable fallback..."
        if resolve_missing_bin "$bin"; then
            msg "$LLVM_NAME: $bin resolved via portable fallback."
        else
            still_missing_bins+=("$bin")
        fi
    done

    local bolt_enabled=1
    if ! command -v perf &>/dev/null; then
        bolt_enabled=0
        msg "$LLVM_NAME: perf not found (tied to the running kernel, no generic fallback). Disabling --bolt for this run instead of failing."
    fi
    echo "$bolt_enabled" > "$base/.bolt_enabled"

    command -v clang &>/dev/null || msg "$LLVM_NAME: Note: clang not found (gcc/g++ will be used as host compiler instead)."
    command -v ld.lld &>/dev/null || msg "$LLVM_NAME: Note: lld not found (link step will use the system linker instead)."

    local header_checks=(
        "libssl-dev:/usr/include/openssl/ssl.h:$LOCAL_INCLUDE/openssl/ssl.h"
        "libelf-dev:/usr/include/libelf.h:$LOCAL_INCLUDE/libelf.h"
        "zlib1g-dev:/usr/include/zlib.h:$LOCAL_INCLUDE/zlib.h"
    )
    local still_missing_headers=()
    for entry in "${header_checks[@]}"; do
        local pkg sys_path local_path
        pkg="$(cut -d: -f1 <<< "$entry")"
        sys_path="$(cut -d: -f2 <<< "$entry")"
        local_path="$(cut -d: -f3 <<< "$entry")"
        if [[ -f "$sys_path" || -f "$local_path" ]]; then
            continue
        fi
        msg "$LLVM_NAME: $pkg headers not found, trying a portable fallback..."
        if resolve_missing_header "$pkg" && [[ -f "$local_path" ]]; then
            msg "$LLVM_NAME: $pkg resolved via portable fallback."
        else
            still_missing_headers+=("$pkg")
        fi
    done

    local problems=0

    if ((${#still_missing_bins[@]})); then
        problems=1
        err "$LLVM_NAME: Could not resolve required binaries (no working fallback): ${still_missing_bins[*]}"
    fi
    if ((${#still_missing_headers[@]})); then
        problems=1
        err "$LLVM_NAME: Could not resolve required dev headers/libraries (no working fallback): ${still_missing_headers[*]}"
    fi

    if [[ -z "$GH_TOKEN" ]]; then
        problems=1
        err "$LLVM_NAME: GH_TOKEN is not set. GitHub Release upload will fail."
    fi
    if command -v gh &>/dev/null; then
        if [[ -n "$GH_TOKEN" ]] && ! GH_TOKEN="$GH_TOKEN" gh auth status &>/dev/null; then
            problems=1
            err "$LLVM_NAME: gh CLI cannot authenticate with the provided GH_TOKEN. Check that the token has 'repo' scope and hasn't expired."
        fi
    else
        problems=1
        err "$LLVM_NAME: gh CLI is not installed and could not be fetched. Cannot create or upload GitHub Releases."
    fi

    if ((problems)); then
        err "$LLVM_NAME: Dependency check FAILED even after portable fallbacks. This host has no sudo, so what's left below needs the admin:"
        ((${#still_missing_bins[@]})) && err "  - binaries: ${still_missing_bins[*]}"
        ((${#still_missing_headers[@]})) && err "  - headers: ${still_missing_headers[*]}"
        [[ -z "$GH_TOKEN" ]] && err "  - GH_TOKEN environment variable (set it in \$HOME/.secrets or the environment)"
        exit 1
    fi

    msg "$LLVM_NAME: All required dependencies are present (some may be portable local copies under $LOCAL_PREFIX)."
}

function do_kernel() {
    local branch=linux-rolling-stable
    local linux="$src/$branch"

    if [[ -d "$linux" ]]; then
        git -C "$linux" fetch --depth=1 origin "$branch"
        git -C "$linux" reset --hard FETCH_HEAD
    else
        git clone \
            --branch "$branch" \
            --depth=1 \
            --single-branch \
            https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git \
            "$linux"
    fi

    cat <<EOF | env PYTHONPATH="$base"/tc_build python3 -
from pathlib import Path

from kernel import LLVMKernelBuilder

builder = LLVMKernelBuilder()
builder.folders.build = Path('$base/build/linux')
builder.folders.source = Path('$linux')
builder.matrix = {'defconfig': ['X86']}
builder.toolchain_prefix = Path('$install')

builder.build()
EOF
}

function do_llvm() {
    local bolt_flag=()
    bolt_supported && bolt_flag=(--bolt)

    tg_post_msg "<b>$LLVM_NAME: Toolchain Compilation Started</b>%0A<b>Date : </b><code>$rel_friendly_date</code>%0A"
    msg "$LLVM_NAME: Building LLVM..."
    tg_post_msg "<b>$LLVM_NAME: Building LLVM. . .</b>"
    "$base"/build-llvm.py \
        --vendor-string "$LLVM_NAME" \
        --defines \
            LLVM_PARALLEL_COMPILE_JOBS="$(nproc)" \
            LLVM_PARALLEL_LINK_JOBS="$(nproc)" \
            CMAKE_C_FLAGS=-O2 \
            CMAKE_CXX_FLAGS=-O2 \
        --ref "$LLVM_REF" \
        --lto full \
        "${bolt_flag[@]}" \
        --install-folder "$install" \
        --targets AArch64 ARM X86 \
        --full-toolchain \
        --projects clang lld polly compiler-rt \
        --shallow-clone
}

parse_parameters "$@"
do_"${action:=all}"

# ==== Release Info ====
if git -C "$src/llvm-project" rev-parse HEAD &>/dev/null; then
    llvm_commit="$(git -C "$src/llvm-project" rev-parse HEAD)"
    short_llvm_commit="${llvm_commit:0:8}"
else
    err "$LLVM_NAME: Could not read commit hash from $src/llvm-project. Release notes will omit the LLVM commit link."
    llvm_commit="unknown"
    short_llvm_commit="unknown"
fi

# Both the LLVM source commit and this build-script's own commit live in the
# same fork (Alchemist-LLVM), just on different branches, so both links point
# there.
llvm_commit_url="$REPO_URL/commit/$short_llvm_commit"
builder_commit_url="$REPO_URL/commit/$builder_commit"

# Pull clang & lld version strings out of the freshly built toolchain so they
# show up in the release notes instead of being blank.
clang_version="$("$install"/bin/clang --version | head -n1)"
lld_version="$("$install"/bin/ld.lld --version | head -n1)"

tg_post_msg "<b>$LLVM_NAME: Toolchain compilation Finished</b>"

# ==== Strip debug symbols to shrink the release archive ====
msg "$LLVM_NAME: Stripping binaries and libraries..."
find "$install" -type f \( -path '*/bin/*' -o -name '*.so*' -o -name '*.a' \) \
    -exec strip --strip-unneeded {} \; 2>/dev/null || true

# ==== Package the toolchain ====
# xz -9e gives the smallest archive of the common choices (beats zstd --ultra
# -22 by a bit, at the cost of longer compression time) -- worth it since this
# only runs once per release, not on every commit like the old LFS pushes did.
llvm_ver_num="$(sed 's/[^0-9]*//g' <<< "$LLVM_REF")"
asset_name="Alchemist-LLVM-${llvm_ver_num}-${rel_date}.tar.xz"
msg "$LLVM_NAME: Packaging $asset_name..."
tar -C "$install" -cf - . | XZ_OPT='-9e -T0' xz -c > "$base/$asset_name"

# ==== Upload to GitHub Releases ====
# One shared tag/release per day holds all 4 clang builds (21/22/23/24) as
# separate assets -- whichever version builds first creates the release,
# the rest just upload their asset into the same one.
tag="lto-${rel_date}"

notes_entry="### ${LLVM_REF}
Clang version: $clang_version
LLD version: $lld_version

LLVM commit: $llvm_commit_url
Builder commit: $builder_commit_url"

export GH_TOKEN

if gh release view "$tag" --repo "$GH_REPO" &>/dev/null; then
    gh release upload "$tag" "$base/$asset_name" --repo "$GH_REPO" --clobber
    existing_notes="$(gh release view "$tag" --repo "$GH_REPO" --json body -q .body)"
    if ! grep -qF "### ${LLVM_REF}" <<< "$existing_notes"; then
        gh release edit "$tag" --repo "$GH_REPO" --notes "$existing_notes

$notes_entry"
    fi
else
    gh release create "$tag" "$base/$asset_name" \
        --repo "$GH_REPO" \
        --title "$LLVM_NAME Toolchains ($rel_friendly_date)" \
        --notes "$notes_entry"
fi

release_url="$REPO_URL/releases/tag/$tag"

tg_post_msg "<b>$LLVM_NAME: Toolchain pushed to <code>$release_url</code></b>"
