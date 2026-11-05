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

CLANG_VERSIONS=(${*:-23})

ENABLE_MLGO="${ENABLE_MLGO:-1}"

TG_TOKEN="${TG_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
GH_TOKEN="${GH_TOKEN:-}"

TG_NOTIFY=1
if [[ -z "$TG_TOKEN" || -z "$TG_CHAT_ID" ]]; then
    TG_NOTIFY=0
    warn "$LLVM_NAME: TG_TOKEN or TG_CHAT_ID is not set. Telegram notifications are disabled for this run."
fi

BOT_MSG_URL="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"
BOT_DOC_URL="https://api.telegram.org/bot${TG_TOKEN}/sendDocument"

tg_post_msg() {
    [[ "$TG_NOTIFY" -eq 1 ]] || return 0
    curl -s -X POST "$BOT_MSG_URL" \
        -d chat_id="$TG_CHAT_ID" \
        -d "disable_web_page_preview=true" \
        -d "parse_mode=html" \
        --data-urlencode "text=$1" >/dev/null || true
}

tg_post_doc() {
    local doc="$1"
    local caption="${2:-}"
    [[ "$TG_NOTIFY" -eq 1 ]] || return 0
    [[ -f "$doc" ]] || return 0

    local upload_file="$doc"
    local need_rm=0

    # Telegram sendDocument limit is 50MB; compress with gzip if > 45MB
    local size
    size=$(stat -c%s "$doc" 2>/dev/null || echo 0)
    if (( size > 45000000 )); then
        gzip -c "$doc" > "${doc}.gz"
        upload_file="${doc}.gz"
        need_rm=1
    fi

    curl -s -X POST "$BOT_DOC_URL" \
        -F chat_id="$TG_CHAT_ID" \
        -F document=@"$upload_file" \
        -F caption="$caption" \
        -F "parse_mode=html" >/dev/null || true

    if [[ "$need_rm" -eq 1 ]]; then
        rm -f "$upload_file"
    fi
}

base=$(dirname "$(readlink -f "$0")")
install="$base/install"
src="$base/src"

rel_date="$(date "+%Y%m%d")"
rel_friendly_date="$(date "+%B %-d, %Y")"

# Configure continuous build logging
LOG_FILE="$base/build-tc-${rel_date}.log"
: > "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

BUILD_SUCCESS=0
CURRENT_BUILD_TARGET=""

on_exit() {
    local exit_code=$?
    sleep 0.5
    if [[ $exit_code -eq 130 ]]; then
        return 0
    fi
    if [[ $exit_code -ne 0 && $BUILD_SUCCESS -eq 0 ]]; then
        err "$LLVM_NAME: Build failed with exit code $exit_code!"

        local clean_log="$base/build-error-${rel_date}.log"
        sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g' "$LOG_FILE" > "$clean_log" 2>/dev/null || cp "$LOG_FILE" "$clean_log"

        local target_name="${CURRENT_BUILD_TARGET:-Clang ${VERSIONS_DISPLAY:-unknown}}"
        local fail_msg="<b>❌ Alchemist LLVM: Build Failed!</b>
<b>Target:</b> <code>$target_name</code>
<b>Date:</b> <code>$rel_friendly_date</code>
<b>Exit code:</b> <code>$exit_code</code>

Build failure log attached below:"

        tg_post_msg "$fail_msg"
        tg_post_doc "$clean_log" "📄 <b>Build Error Log:</b> <code>${target_name}</code> (${rel_friendly_date})"
        rm -f "$clean_log"
    fi
}
trap on_exit EXIT

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
        python3-pip
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

    if [[ "$ENABLE_MLGO" -eq 1 ]]; then
        if ! python3 -c "import tensorflow" &>/dev/null; then
            msg "$LLVM_NAME: Installing tensorflow-cpu for MLGO support..."
            pip3 install --break-system-packages --no-cache-dir tensorflow-cpu 2>/dev/null || \
            pip3 install --no-cache-dir tensorflow-cpu 2>/dev/null || \
            warn "$LLVM_NAME: Failed to install tensorflow-cpu. Ensure tensorflow-cpu is installed for MLGO."
        fi
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

get_aosp_info() {
    local ver="$1"
    local aosp_file="$src/llvm-project/AndroidVersion.txt"
    local rev=""

    if [[ -f "$aosp_file" ]]; then
        rev=$(grep -oP '^based on \K.*' "$aosp_file" | tr -d '\r\n' || echo "")
    fi

    if [[ -z "$rev" ]] && git -C "$src/llvm-project" rev-parse HEAD &>/dev/null; then
        local log_rev
        log_rev=$(git -C "$src/llvm-project" log -n 50 --format="%s" 2>/dev/null | grep -oP 'LLVM update to \K[0-9]+' | head -n1 || echo "")
        if [[ -n "$log_rev" ]]; then
            rev="r${log_rev}"
        fi
    fi

    if [[ -z "$rev" ]]; then
        case "$ver" in
            21) rev="r574158" ;;
            22) rev="r596125" ;;
            23) rev="r614150" ;;
            24) rev="upstream-main" ;;
            *)  rev="unknown" ;;
        esac
    fi

    echo "$rev"
}

get_aosp_base_desc() {
    local ver="$1"
    local rev="$2"
    if [[ "$ver" == "24" ]] || [[ "$rev" == *"upstream"* ]] || [[ "$rev" == *"Upstream"* ]]; then
        echo "Based on LLVM Upstream Main (Trunk)"
    else
        echo "Based on Google AOSP Clang version $rev"
    fi
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
ver = sys.argv[1].lower()
target = sys.argv[2].lower()
try:
    data = json.load(sys.stdin)
    for r in data:
        body = (r.get('body') or '').lower()
        tag = (r.get('tag_name') or '').lower()
        if f'clang-{ver}' in body and target in body:
            sys.exit(0)
        if target in tag and (f'clang-{ver}' in tag or f'llvm-{ver}' in tag or tag.startswith(f'v{ver}')):
            sys.exit(0)
        for a in r.get('assets', []):
            name = (a.get('name') or '').lower()
            if target in name and f'llvm-{ver}' in name:
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
    local profile_desc="Stage 1 ThinLTO Kernel Profile"
    local mlgo_args=()
    if [[ "$ENABLE_MLGO" -eq 1 ]]; then
        profile_desc="Stage 1 ThinLTO Kernel Profile with MLGO"
        mlgo_args+=(--mlgo)
    fi

    msg "$LLVM_NAME: Building LLVM for $llvm_ref ($profile_desc)..."

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
        --shallow-clone \
        "${mlgo_args[@]}"
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
    local aosp_rev
    aosp_rev="$(get_aosp_info "$ver")"
    local base_desc
    base_desc="$(get_aosp_base_desc "$ver" "$aosp_rev")"

    local notes_entry="Clang-${ver}: ${base_desc}
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

PIPELINE_PROFILE="Stage 1 ThinLTO Kernel Profile"
if [[ "$ENABLE_MLGO" -eq 1 ]]; then
    PIPELINE_PROFILE="Stage 1 ThinLTO Kernel Profile with MLGO"
fi

START_MSG="<b>🧪 Alchemist LLVM Toolchain Pipeline Started</b>
<b>Date:</b> <code>$rel_friendly_date</code>
<b>Versions:</b> <code>Clang ${VERSIONS_DISPLAY}</code>
<b>Profile:</b> $PIPELINE_PROFILE"
tg_post_msg "$START_MSG"

RESULTS=()

for VER in "${CLANG_VERSIONS[@]}"; do
    LLVM_REF="clang-${VER}"
    CURRENT_BUILD_TARGET="$LLVM_REF"
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
<b>Profile:</b> $PIPELINE_PROFILE"

    build_single_llvm "$LLVM_REF"
    if [[ "$ENABLE_MLGO" -eq 1 ]]; then
        local tf_dir
        tf_dir=$(python3 -c "import tensorflow as tf, os; print(os.path.dirname(tf.__file__))" 2>/dev/null || true)
        if [[ -n "$tf_dir" && -d "$tf_dir" ]]; then
            msg "$LLVM_NAME: Bundling TensorFlow runtime libraries into install directory for MLGO..."
            mkdir -p "$install/lib"
            cp -d "$tf_dir"/libtensorflow_framework.so* "$install/lib/" 2>/dev/null || true
        fi
    fi
    build_single_binutils
    test_kernel_arm64
    package_and_publish "$VER" "$CURRENT_VER"

    local aosp_rev
    aosp_rev="$(get_aosp_info "$VER")"
    local base_desc
    base_desc="$(get_aosp_base_desc "$VER" "$aosp_rev")"

    RESULTS+=("• <b>Clang ${VER} (<code>${CURRENT_VER}</code>):</b> ✅ Built & Published (<code>${aosp_rev}</code>)")
    tg_post_msg "<b>✅ Alchemist LLVM: Clang ${VER} Published!</b>
<b>Version:</b> <code>${CURRENT_VER}</code>
<b>Base:</b> <code>${base_desc}</code>
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

BUILD_SUCCESS=1
tg_post_msg "$SUMMARY_MSG"
