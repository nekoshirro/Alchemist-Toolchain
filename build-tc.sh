#!/usr/bin/env bash
#
# Alchemist LLVM toolchain build script.
# Builds clang/LLVM (+ binutils, + a sample kernel build) and publishes the
# resulting toolchain to GitHub Releases.
#
# This script never calls sudo / apt-get. It only checks that required
# tools and headers exist and reports what is missing so it can be relayed
# to the server admin. Nothing is installed automatically.

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

# Reports missing tools/headers instead of installing anything (no sudo on
# this host). Exits non-zero and prints a list to relay to the admin if
# anything required for building LLVM/clang or publishing the release is
# missing. Nothing here modifies the system.
function do_deps() {
    local missing_bins=()
    local missing_headers=()
    local notes=()

    # Required to run build-llvm.py / build-binutils.py / kernel.py and to
    # package + release the toolchain.
    local required_bins=(
        bc bison cmake curl file flex gcc g++ git make ninja python3
        texinfo xz gh perf
    )
    for bin in "${required_bins[@]}"; do
        command -v "$bin" &>/dev/null || missing_bins+=("$bin")
    done

    # clang/lld speed up / are used during the LLVM bootstrap; gcc/g++ can
    # substitute for clang, so these are reported separately as notes.
    command -v clang &>/dev/null || notes+=("clang not found (gcc/g++ will be used as host compiler instead)")
    command -v ld.lld &>/dev/null || notes+=("lld not found (link step will use the system linker instead)")

    local header_checks=(
        "libssl-dev:/usr/include/openssl/ssl.h"
        "libelf-dev:/usr/include/libelf.h"
        "zlib1g-dev:/usr/include/zlib.h"
    )
    for entry in "${header_checks[@]}"; do
        local pkg="${entry%%:*}"
        local path="${entry##*:}"
        [[ -f "$path" ]] || missing_headers+=("$pkg (expected $path)")
    done

    local problems=0

    if ((${#missing_bins[@]})); then
        problems=1
        err "$LLVM_NAME: Missing required binaries: ${missing_bins[*]}"
    fi

    if ((${#missing_headers[@]})); then
        problems=1
        err "$LLVM_NAME: Missing required dev headers/libraries:"
        for h in "${missing_headers[@]}"; do
            err "  - $h"
        done
    fi

    for n in "${notes[@]}"; do
        msg "$LLVM_NAME: Note: $n"
    done

    if [[ -z "$GH_TOKEN" ]]; then
        problems=1
        err "$LLVM_NAME: GH_TOKEN is not set. GitHub Release upload will fail."
    fi

    if ! command -v gh &>/dev/null; then
        problems=1
        err "$LLVM_NAME: gh CLI is not installed. Cannot create or upload GitHub Releases."
    elif [[ -n "$GH_TOKEN" ]] && ! GH_TOKEN="$GH_TOKEN" gh auth status &>/dev/null; then
        problems=1
        err "$LLVM_NAME: gh CLI cannot authenticate with the provided GH_TOKEN. Check that the token has 'repo' scope and hasn't expired."
    fi

    if ((problems)); then
        err "$LLVM_NAME: Dependency check FAILED. This host has no sudo, so nothing can be installed automatically."
        err "$LLVM_NAME: Report the list above to the server admin before starting the build."
        exit 1
    fi

    msg "$LLVM_NAME: All required dependencies are present."
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
        --bolt \
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
