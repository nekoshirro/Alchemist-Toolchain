#!/usr/bin/env bash

set -euo pipefail

if [ -f "$HOME/.secrets" ]; then
    source "$HOME/.secrets"
fi

if [ -f "$(pwd)/.secrets" ]; then
    source "$(pwd)/.secrets"
fi

msg() {
    echo -e "\e[1;32m$*\e[0m"
}

warn() {
    echo -e "\e[1;33m$*\e[0m"
}

err() {
    echo -e "\e[1;41m$*\e[0m" >&2
}

LLVM_NAME="🧪Alchemist LLVM"
GH_OWNER="nekoshirro"
LLVM_REPO="Alchemist-LLVM"
GH_REPO="$GH_OWNER/$LLVM_REPO"
REPO_URL="https://github.com/$GH_REPO"

CLANG_VERSIONS=(${*:-22})

TG_TOKEN="${TG_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
GH_TOKEN="${GH_TOKEN:-}"

TG_NOTIFY=1
if [[ -z "$TG_TOKEN" || -z "$TG_CHAT_ID" ]]; then
    TG_NOTIFY=0
    warn "$LLVM_NAME: TG_TOKEN or TG_CHAT_ID is not set. Telegram notifications are disabled for this run."
fi

BOT_MSG_URL="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"

tg_post_msg() {
    [[ "$TG_NOTIFY" -eq 1 ]] || return 0
    curl -s -X POST "$BOT_MSG_URL" \
        -d chat_id="$TG_CHAT_ID" \
        -d "disable_web_page_preview=true" \
        -d "parse_mode=html" \
        --data-urlencode "text=$1" >/dev/null || true
}

base=$(dirname "$(readlink -f "$0")")
install="$base/install"
src="$base/src"

rel_date="$(date "+%Y%m%d")"
rel_friendly_date="$(date "+%B %-d, %Y")"

if git -C "$base" rev-parse HEAD &>/dev/null; then
    builder_commit="$(git -C "$base" rev-parse HEAD)"
else
    builder_commit="unknown"
fi

builder_commit_url="$REPO_URL/commit/$builder_commit"
release_tag="lto-${rel_date}"
release_url="$REPO_URL/releases/tag/$release_tag"

do_deps() {
    msg "$LLVM_NAME: Checking and installing required dependencies via apt..."

    local pkgs=(
        bc
        bison
        build-essential
        cmake
        curl
        file
        flex
        git
        libelf-dev
        libssl-dev
        lld
        make
        ninja-build
        python3
        texinfo
        xz-utils
        zlib1g-dev
    )

    local to_install=()
    for pkg in "${pkgs[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            to_install+=("$pkg")
        fi
    done

    if ! command -v gh &>/dev/null; then
        to_install+=("gh")
    fi

    if [ -n "${to_install[*]:-}" ]; then
        msg "$LLVM_NAME: Installing missing packages: ${to_install[*]}..."
        local sudo_cmd=""
        if [[ $EUID -ne 0 ]] && command -v sudo &>/dev/null; then
            sudo_cmd="sudo"
        fi
        $sudo_cmd apt-get update -y || true
        $sudo_cmd apt-get install -y --no-install-recommends "${to_install[@]}" || {
            err "$LLVM_NAME: Failed to install dependencies via apt."
            exit 1
        }
    else
        msg "$LLVM_NAME: All required apt dependencies are already installed."
    fi

    if [[ -z "$GH_TOKEN" ]]; then
        err "$LLVM_NAME: GH_TOKEN is not set. GitHub Release upload will fail."
        exit 1
    fi

    if command -v gh &>/dev/null; then
        if [[ -n "$GH_TOKEN" ]] && ! GH_TOKEN="$GH_TOKEN" gh auth status &>/dev/null; then
            err "$LLVM_NAME: gh CLI cannot authenticate with GH_TOKEN. Check 'repo' scope."
            exit 1
        fi
    else
        err "$LLVM_NAME: gh CLI is not installed."
        exit 1
    fi

    msg "$LLVM_NAME: Dependencies are satisfied."
}

get_remote_llvm_version() {
    local branch="clang-$1"
    local raw_url="https://raw.githubusercontent.com/$GH_REPO/${branch}/cmake/Modules/LLVMVersion.cmake"
    local content
    content=$(curl -fsSL "$raw_url" 2>/dev/null || true)
    if [[ -z "$content" ]]; then
        echo ""
        return
    fi
    local major minor patch suffix
    major=$(echo "$content" | grep -oP 'set\(LLVM_VERSION_MAJOR \K[0-9]+' || echo "")
    minor=$(echo "$content" | grep -oP 'set\(LLVM_VERSION_MINOR \K[0-9]+' || echo "")
    patch=$(echo "$content" | grep -oP 'set\(LLVM_VERSION_PATCH \K[0-9]+' || echo "")
    suffix=$(echo "$content" | grep -oP 'set\(LLVM_VERSION_SUFFIX \K[^)]+' | tr -d ' "' || echo "")
    echo "${major}.${minor}.${patch}${suffix}"
}

is_already_released() {
    local ver="$1"
    local target_ver="$2"
    [[ -z "$target_ver" ]] && return 1

    local auth_header=()
    [[ -n "${GH_TOKEN:-}" ]] && auth_header=(-H "Authorization: token ${GH_TOKEN}")

    local releases_json
    releases_json=$(curl -fsSL "${auth_header[@]}" "https://api.github.com/repos/$GH_REPO/releases?per_page=100" 2>/dev/null || true)
    [[ -z "$releases_json" || "$releases_json" == "[]" ]] && return 1

    python3 -c "
import sys, json
ver = sys.argv[1]
target = sys.argv[2]
try:
    data = json.load(sys.stdin)
    for r in data:
        body = r.get('body', '')
        tag = r.get('tag_name', '')
        if f'clang-{ver}' in body and target in body:
            sys.exit(0)
        if target in tag and (f'clang-{ver}' in tag or f'llvm-{ver}' in tag or tag.startswith(f'v{ver}')):
            sys.exit(0)
        for a in r.get('assets', []):
            name = a.get('name', '')
            if target in name and f'LLVM-{ver}' in name:
                sys.exit(0)
    sys.exit(1)
except Exception:
    sys.exit(1)
" "$ver" "$target_ver" <<< "$releases_json"
}

build_single_binutils() {
    msg "$LLVM_NAME: Building binutils (arm, aarch64, x86_64)..."
    "$base"/build-binutils.py \
        --install-folder "$install" \
        --show-build-commands \
        --targets arm aarch64 x86_64
}

test_kernel_arm64() {
    local branch=linux-rolling-stable
    local linux="$src/$branch"

    msg "$LLVM_NAME: Verifying toolchain with Linux ARM64 defconfig test build..."
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

    cat <<EOF | env PYTHONPATH="$base" python3 -
from pathlib import Path

from tc_build.kernel import LLVMKernelBuilder

builder = LLVMKernelBuilder()
builder.folders.build = Path('$base/build/linux')
builder.folders.source = Path('$linux')
builder.matrix = {'defconfig': ['ARM64']}
builder.toolchain_prefix = Path('$install')

builder.build()
EOF
}

build_single_llvm() {
    local llvm_ref="$1"
    msg "$LLVM_NAME: Building LLVM for $llvm_ref (Stage 1 ThinLTO Kernel Profile)..."

    local total_ram_gb
    total_ram_gb=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo 4)
    local link_jobs=$(( total_ram_gb / 4 ))
    (( link_jobs < 1 )) && link_jobs=1
    (( link_jobs > 4 )) && link_jobs=4

    "$base"/build-llvm.py \
        --vendor-string "$LLVM_NAME" \
        --defines \
            LLVM_PARALLEL_COMPILE_JOBS="$(nproc)" \
            LLVM_PARALLEL_LINK_JOBS="${LLVM_PARALLEL_LINK_JOBS:-$link_jobs}" \
            CMAKE_C_FLAGS="-O2 -pipe" \
            CMAKE_CXX_FLAGS="-O2 -pipe" \
        --ref "$llvm_ref" \
        --lto thin \
        --build-stage1-only \
        --install-folder "$install" \
        --targets AArch64 ARM X86 \
        --projects clang lld \
        --shallow-clone
}

package_and_publish() {
    local ver="$1"
    local llvm_ref="clang-${ver}"
    local current_ver="$2"

    local llvm_commit="unknown"
    local short_llvm_commit="unknown"
    if git -C "$src/llvm-project" rev-parse HEAD &>/dev/null; then
        llvm_commit="$(git -C "$src/llvm-project" rev-parse HEAD)"
        short_llvm_commit="${llvm_commit:0:8}"
    fi

    local llvm_commit_url="$REPO_URL/commit/$short_llvm_commit"

    local clang_version
    local lld_version
    clang_version="$("$install"/bin/clang --version | head -n1)"
    lld_version="$("$install"/bin/ld.lld --version | head -n1)"

    msg "$LLVM_NAME: Stripping binaries and libraries..."
    find "$install" -type f \( -path '*/bin/*' -o -name '*.so*' -o -name '*.a' \) \
        -exec strip --strip-unneeded {} \; 2>/dev/null || true

    local asset_name="Alchemist-LLVM-${ver}-${rel_date}.tar.xz"
    msg "$LLVM_NAME: Packaging $asset_name..."
    tar -C "$install" -cf - . | XZ_OPT='-9e -T0' xz -c > "$base/$asset_name"

    msg "$LLVM_NAME: Publishing $asset_name to GitHub Release $release_tag..."
    local notes_entry="Clang-${ver}
Clang version: $clang_version
LLD version: $lld_version

LLVM commit: $llvm_commit_url
Builder commit: $builder_commit_url"

    export GH_TOKEN

    if gh release view "$release_tag" --repo "$GH_REPO" &>/dev/null; then
        gh release upload "$release_tag" "$base/$asset_name" --repo "$GH_REPO" --clobber
        local existing_notes
        existing_notes="$(gh release view "$release_tag" --repo "$GH_REPO" --json body -q .body)"
        if ! grep -qF "Clang-${ver}" <<< "$existing_notes"; then
            gh release edit "$release_tag" --repo "$GH_REPO" --notes "$existing_notes

$notes_entry"
        fi
    else
        gh release create "$release_tag" "$base/$asset_name" \
            --repo "$GH_REPO" \
            --title "$LLVM_NAME Toolchains ($rel_friendly_date)" \
            --notes "$notes_entry"
    fi

    msg "$LLVM_NAME: Successfully published $llvm_ref ($current_ver)!"

    msg "$LLVM_NAME: Cleaning workspace for $llvm_ref to save disk space..."
    rm -rf "$install" "$base/build" "$src/llvm-project" "$base/$asset_name"
}

do_deps

VERSIONS_DISPLAY="${CLANG_VERSIONS[*]}"
msg "========================================================"
msg " Starting Alchemist LLVM Pipeline: Clang ${VERSIONS_DISPLAY}"
msg "========================================================"

START_MSG="<b>🧪 Alchemist LLVM Toolchain Pipeline Started</b>
<b>Date:</b> <code>$rel_friendly_date</code>
<b>Versions:</b> <code>Clang ${VERSIONS_DISPLAY}</code>
<b>Profile:</b> Stage 1 ThinLTO Kernel Profile"
tg_post_msg "$START_MSG"

RESULTS=()

for VER in "${CLANG_VERSIONS[@]}"; do
    LLVM_REF="clang-${VER}"
    msg "--------------------------------------------------------"
    msg " Evaluating $LLVM_REF..."
    msg "--------------------------------------------------------"

    CURRENT_VER=$(get_remote_llvm_version "$VER")
    if [[ -z "$CURRENT_VER" ]]; then
        CURRENT_VER="latest"
    fi

    if is_already_released "$VER" "$CURRENT_VER"; then
        msg "⏭️  $LLVM_REF ($CURRENT_VER) is already published in GitHub Releases. Skipping!"
        RESULTS+=("• <b>Clang ${VER} (<code>${CURRENT_VER}</code>):</b> ⏭️ Skipped (Already released)")
        tg_post_msg "<b>⏭️ Alchemist LLVM: Clang ${VER} Skipped</b>
<b>Version:</b> <code>${CURRENT_VER}</code> (Already published in GitHub Releases)"
        continue
    fi

    msg "🚀 Building $LLVM_REF ($CURRENT_VER)..."
    tg_post_msg "<b>🔨 Alchemist LLVM: Building Clang ${VER}...</b>
<b>Version:</b> <code>${CURRENT_VER}</code>
<b>Profile:</b> Stage 1 ThinLTO Kernel Profile"

    build_single_llvm "$LLVM_REF"
    build_single_binutils
    test_kernel_arm64
    package_and_publish "$VER" "$CURRENT_VER"

    RESULTS+=("• <b>Clang ${VER} (<code>${CURRENT_VER}</code>):</b> ✅ Built & Published")
    tg_post_msg "<b>✅ Alchemist LLVM: Clang ${VER} Published!</b>
<b>Version:</b> <code>${CURRENT_VER}</code>
<b>Asset:</b> <code>Alchemist-LLVM-${VER}-${rel_date}.tar.xz</code>
<b>Release:</b> <code>$release_url</code>"
done

RESULTS_TEXT=$(printf "%s\n" "${RESULTS[@]}")

SUMMARY_MSG="<b>🧪 Alchemist LLVM Build Pipeline Summary</b>
<b>Date:</b> <code>$rel_friendly_date</code>

<b>Results:</b>
$RESULTS_TEXT

<b>Release URL:</b>
🔗 <code>$release_url</code>"

msg "========================================================"
msg " Pipeline finished!"
echo -e "$RESULTS_TEXT"
msg "========================================================"

tg_post_msg "$SUMMARY_MSG"
