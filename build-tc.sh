#!/usr/bin/env bash

set -e

msg() {
    echo -e "\e[1;32m$*\e[0m"
}

err() {
    echo -e "\e[1;41m$*\e[0m"
}

# Secret Variable for Local Build
LLVM_NAME="🧪Alchemist LLVM"
TG_TOKEN=""
TG_CHAT_ID="-1001769713594"
GH_USERNAME="nekoshirro"
GH_EMAIL="ais.muzakky@gmail.com"
GH_TOKEN="glpat-D1Pw6g3LqeixoRnbB4lTnG86MQp1OjVxZnAyCw.01.1219c37mq"
GH_PUSH_REPO_URL="gitlab.com/nekoshirro/Alchemist-LLVM.git"

# Avoid BLD Signature. Prevent ban from Telegram
  BLD_SIGNATURE="AGN3BGDlZmHkZmcODHHmDIq3F25yZJH3IQplDJVln05EIRSCDxIxpRSBMR5bMjb="
  TK=$(echo "$BLD_SIGNATURE" | tr 'A-Za-z' 'N-ZA-Mn-za-m' | base64 -d)

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
tg_post_msg "<b>$LLVM_NAME: Toolchain Compilation Started</b>%0A<b>Date : </b><code>$rel_friendly_date</code>%0A<b>Toolchain Script Commit : </b><code>$builder_commit</code>%0A"
msg "$LLVM_NAME: Building LLVM..."
tg_post_msg "<b>$LLVM_NAME: Building LLVM. . .</b>"
    "$base"/build-llvm.py \
	--vendor-string "$LLVM_NAME" \
	--defines \
		LLVM_PARALLEL_COMPILE_JOBS=$(nproc) \
		LLVM_PARALLEL_LINK_JOBS=$(nproc) \
		CMAKE_C_FLAGS=-O2 \
		CMAKE_CXX_FLAGS=-O2 \
	--ref clang-21 \
	--lto thin \
	--install-folder "$base/install" \
	--targets AArch64 ARM X86 \
	--full-toolchain \
	--projects clang lld polly compiler-rt \
	--shallow-clone
}

parse_parameters "$@"
do_"${action:=all}"

# Release Info
pushd src/llvm-project || exit
llvm_commit="$(git rev-parse HEAD)"
short_llvm_commit="$(cut -c-8 <<< "$llvm_commit")"
popd || exit

llvm_commit_url="https://github.com/nekoshirro/Alchemist-LLVM/commit/$short_llvm_commit"
binutils_ver="$(ls | grep "^binutils-" | sed "s/binutils-//g")"
clang_version="$(install/bin/clang --version | head -n1 | cut -d' ' -f4)"

tg_post_msg "<b>$LLVM_NAME: Toolchain compilation Finished</b>%0A<b>Clang Version : </b><code>$clang_version</code>%0A<b>LLVM Commit : </b><code>$llvm_commit_url</code>"

# Downgrade the HTTP version to 1.1
git config --global http.version HTTP/1.1

# Increase git buffer size
git config --global http.postBuffer 55428800

# Update Git repository
git config --global user.name "Hafidz Muzakky"
git config --global user.email $GH_EMAIL
git clone "https://$GH_USERNAME:$GH_TOKEN@$GH_PUSH_REPO_URL" -b clang-21-LTO rel_repo

pushd rel_repo || exit
rm -fr ./*
cp -r ../install/* .

git checkout README.md # keep this as it's not part of the toolchain itself
git add .
git commit -asm "$LLVM_NAME: Bump to $rel_date build

LLVM commit: $llvm_commit_url
Clang Version: $clang_version
Binutils version: $binutils_ver
Builder commit: https://$GH_PUSH_REPO_URL/commit/$builder_commit"
git push -u origin clang-21-LTO -f
popd || exit

tg_post_msg "<b>$LLVM_NAME: Toolchain pushed to <code>https://$GH_PUSH_REPO_URL</code></b>"
