#!/usr/bin/env bash

set -e

msg() {
    echo -e "\e[1;32m$*\e[0m"
}

err() {
    echo -e "\e[1;41m$*\e[0m"
}

# ==== Per-version config ====
LLVM_NAME="🧪Alchemist LLVM"
LLVM_REF="clang-22"                       # branch of the LLVM source fork to build (clang-21/22/23/24)
GH_OWNER="nekoshirro"
LLVM_REPO="Alchemist-LLVM"               # source fork AND github release target
GH_REPO="$GH_OWNER/$LLVM_REPO"           # owner/repo, used by gh cli
REPO_URL="https://github.com/$GH_REPO"

TK="$TG_TOKEN"

# Set a directory
DIR="$(pwd ...)"

# Inlined function to post a message
export BOT_MSG_URL="https://api.telegram.org/bot${TK}/sendMessage"
tg_post_msg() {
	curl -s -X POST "$BOT_MSG_URL" -d chat_id="$TG_CHAT_ID" \
	-d "disable_web_page_preview=true" \
	-d "parse_mode=html" \
	-d text="$1"

}
tg_post_build() {
	curl --progress-bar -F document=@"$1" "$BOT_MSG_URL" \
	-F chat_id="$TG_CHAT_ID"  \
	-F "disable_web_page_preview=true" \
	-F "parse_mode=html" \
	-F caption="$3"
}

# Build Info
rel_date="$(date "+%Y%m%d")" # ISO 8601 format
rel_friendly_date="$(date "+%B %-d, %Y")" # "Month day, year" format
builder_commit="$(git rev-parse HEAD)"

base=$(dirname "$(readlink -f "$0")")
install=$base/install
src=$base/src

set -eu

function parse_parameters() {
    while (($#)); do
        case $1 in
            all | binutils | deps | kernel | llvm) action=$1 ;;
            *) exit 33 ;;
        esac
        shift
    done
}

function do_all() {
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

function do_deps() {

    # Refresh mirrorlist to avoid dead mirrors
    sudo apt-get update -y

    sudo apt-get install -y --no-install-recommends \
        bc \
        bison \
        ca-certificates \
        clang \
        cmake \
        curl \
        file \
        flex \
        gcc \
        g++ \
        git \
        libelf-dev \
        libssl-dev \
        lld \
        make \
        ninja-build \
        python3 \
        texinfo \
        xz-utils \
        zlib1g-dev

    # Needed for GitHub Releases upload
    if ! command -v gh &>/dev/null; then
        type -p curl >/dev/null || sudo apt-get install -y curl
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
        sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
        sudo apt-get update -y
        sudo apt-get install -y gh
    fi
}

function do_kernel() {
    local branch=linux-rolling-stable
    local linux=$src/$branch

    if [[ -d $linux ]]; then
        git -C "$linux" fetch --depth=1 origin $branch
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
		LLVM_PARALLEL_COMPILE_JOBS=$(nproc) \
		LLVM_PARALLEL_LINK_JOBS=$(nproc) \
		CMAKE_C_FLAGS=-O2 \
		CMAKE_CXX_FLAGS=-O2 \
	--ref "$LLVM_REF" \
	--lto full \
	--bolt \
	--install-folder "$base/install" \
	--targets AArch64 ARM X86 \
	--full-toolchain \
	--projects clang lld polly compiler-rt \
	--shallow-clone
}

parse_parameters "$@"
do_"${action:=all}"

# ==== Release Info ====
pushd src/llvm-project || exit
llvm_commit="$(git rev-parse HEAD)"
short_llvm_commit="$(cut -c-8 <<< "$llvm_commit")"
popd || exit

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
