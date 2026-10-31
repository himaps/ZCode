#!/usr/bin/env bash
# 在 ubuntu:20.04 (focal) 容器内下载麒麟 V10 SP1 aarch64 的离线依赖闭包。
#
# 依据 docs/kylin-v10-sp1-offline-deb.md：
# - focal 与麒麟 V10 SP1 同源同版本（glibc 2.31、包名一致），闭包包名无需跨发行版映射；
# - 按 depends-seeds.txt 的 Depends 递归展开，剔除黑名单后逐包 `apt-get download`；
# - 黑名单 = Essential=yes + glibc(libc6 家族) + systemd*/dbus*/libpam*/udev/login/passwd，
#   这是"绝不升级目标机系统组件"红线的构建期防线。
#
# 用法（容器内 root）: collect-offline-closure.sh <输出目录> <seeds 文件>
# 产物: <输出目录>/*.deb、closure-manifest.txt、closure-packages.txt
set -euo pipefail

OUT_DIR="${1:?usage: collect-offline-closure.sh <out-dir> <seeds-file>}"
SEEDS_FILE="${2:?usage: collect-offline-closure.sh <out-dir> <seeds-file>}"

export DEBIAN_FRONTEND=noninteractive
mkdir -p "$OUT_DIR"

# ---- focal 已过标准支持期 + 云上网络：apt 必须限时，否则会挂死几十分钟 ----
cat > /etc/apt/apt.conf.d/95zcode-offline <<'EOF'
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
Acquire::Retries "5";
Acquire::Check-Valid-Until "false";
EOF

# 闭包只需要 arm64 包：只保留 ports.ubuntu.com 的 arm64 源（麒麟 V10 SP1 arm64 的上游血脉）
dpkg --add-architecture arm64
cat > /etc/apt/sources.list <<'EOF'
deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports focal main universe
deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports focal-updates main universe
deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports focal-security main universe
EOF

# 逐级降级更新：某个 suite 归档化（如 focal-security 迁走）时剔除该 suite，而不是整体失败
if ! timeout 600 apt-get update; then
  echo "[closure] 完整 update 失败，剔除 focal-security 后重试" >&2
  sed -i '/focal-security/d' /etc/apt/sources.list
  if ! timeout 600 apt-get update; then
    echo "[closure] 剔除 focal-security 仍失败，只保留 focal 主仓重试" >&2
    sed -i '/focal-updates/d' /etc/apt/sources.list
    timeout 600 apt-get update
  fi
fi

# ---- 种子解析 ----
mapfile -t seeds < <(tr -d '\r' < "$SEEDS_FILE" | sed 's/:arm64$//' | grep -v '^#' | grep -v '^$' | sort -u)
[ "${#seeds[@]}" -gt 0 ] || { echo "[closure] seeds 为空" >&2; exit 1; }

# ---- 黑名单（红线，构建期防线） ----
is_blacklisted() {
  local pkg="$1" essential=0
  case "$pkg" in
    # glibc 家族永不打包：符号版本在链接期固化，运行时必须由宿主 libc 提供
    libc6|libc6-*|libc-bin) return 0 ;;
    # 系统核心：升级/替换任何一个都可能把目标机搞崩（deepin-screenshot 事故）
    systemd*|dbus*|libpam*|udev|login|passwd) return 0 ;;
  esac
  # Essential=yes 的包同样绝不进闭包（grep 读到 EOF，不用 grep -q 于管道）
  essential=$(apt-cache show "$pkg" 2>/dev/null | grep -c '^Essential: yes' || true)
  [ "$essential" -gt 0 ]
}

# ---- Depends 递归展开：--recurse 输出的 <pkg> 行即传递闭包成员 ----
closure_pkgs=$(apt-cache depends --recurse \
  --no-recommends --no-suggests --no-conflicts --no-breaks --no-replaces --no-enhances \
  "${seeds[@]}" 2>/dev/null | grep -oE '<[a-z0-9][a-z0-9+.-]*>' | tr -d '<>' | sort -u || true)
# 与种子取并集；缺了种子本身会在下载阶段硬失败
all_pkgs=$(printf '%s\n%s\n' "$closure_pkgs" "$(printf '%s\n' "${seeds[@]}")" | sort -u)

manifest="$OUT_DIR/closure-manifest.txt"
packages_list="$OUT_DIR/closure-packages.txt"
: > "$manifest"
: > "$packages_list"

cd "$OUT_DIR"
downloaded=0
skipped_blacklisted=0
skipped_virtual=0
for pkg in $all_pkgs; do
  if is_blacklisted "$pkg"; then
    skipped_blacklisted=$((skipped_blacklisted + 1))
    continue
  fi
  # 纯虚包没有可下载版本：apt-cache show 对纯虚包 rc=0 但输出里没有 Version 字段
  # （debconf-2.0 这类 Provides 别名即属此类），其真实提供者要么在种子里、
  # 要么是目标机必备件，跳过并记录。
  version_lines=$(apt-cache show "$pkg" 2>/dev/null | grep -c '^Version:' || true)
  if [ "$version_lines" -eq 0 ]; then
    skipped_virtual=$((skipped_virtual + 1))
    echo "[closure] 跳过虚包: $pkg" >&2
    continue
  fi
  ok=0
  dl_log=$(mktemp)
  for attempt in 1 2 3; do
    if timeout 300 apt-get download "$pkg:arm64" >"$dl_log" 2>&1; then
      ok=1
      break
    fi
    # "no candidate"/"Unable to locate" 属虚包/缺名，重试无意义，降级为跳过
    if grep -qE 'no candidate|Unable to locate' "$dl_log"; then
      break
    fi
    echo "[closure] 下载重试 $attempt/3: $pkg" >&2
    sleep $((attempt * 5))
  done
  if [ "$ok" -ne 1 ]; then
    if grep -qE 'no candidate|Unable to locate' "$dl_log"; then
      skipped_virtual=$((skipped_virtual + 1))
      echo "[closure] 跳过无可下载版本的包: $pkg" >&2
      rm -f "$dl_log"
      continue
    fi
    echo "[closure] E: 下载失败: $pkg" >&2
    tail -3 "$dl_log" >&2 || true
    rm -f "$dl_log"
    exit 1
  fi
  rm -f "$dl_log"
  downloaded=$((downloaded + 1))
done

# ---- 清单：以 .deb 文件为准（包名/版本取自 deb 本身，杜绝名实不符） ----
for deb in ./*.deb; do
  [ -e "$deb" ] || continue
  pkg=$(dpkg-deb -f "$deb" Package)
  ver=$(dpkg-deb -f "$deb" Version)
  echo "$pkg $ver $deb" >> "$manifest"
  echo "$pkg" >> "$packages_list"
done
sort -o "$manifest" "$manifest"
sort -o "$packages_list" "$packages_list"

# 种子必须全部落盘，否则 deb 的 Depends 在裸机上必然缺依赖
for seed in "${seeds[@]}"; do
  if ! grep -q "^$seed " "$manifest"; then
    echo "[closure] E: 种子未进入闭包: $seed" >&2
    exit 1
  fi
done

deb_count=$(ls -1 ./*.deb | wc -l)
echo "[closure] 完成: debs=$deb_count seeds=${#seeds[@]} 跳过(黑名单=$skipped_blacklisted 虚包=$skipped_virtual)"
