#!/usr/bin/env bash
# 组装麒麟 V10 SP1 aarch64 离线 deb 并做构建期硬门禁。
#
# 依据 docs/kylin-v10-sp1-offline-deb.md：
# - 载荷来自 electron-builder `--linux dir --arm64` 的 linux-unpacked（复用仓库全部 afterPack 校验）；
# - Depends 只声明真正的 ELF 依赖（libc6 (>= 2.31) + libgcc-s1 + libstdc++6 + seeds）；
# - 构建后必须做两类自检：dpkg-deb -c 载荷断言 + 全量 ELF 的 GLIBC_ 符号扫描（<= 2.31）。
#
# 用法: build-offline-deb.sh <linux-unpacked> <closure-dir> <version> <out-dir>
set -euo pipefail

UNPACKED="${1:?usage: build-offline-deb.sh <linux-unpacked> <closure-dir> <version> <out-dir>}"
CLOSURE_DIR="${2:?usage: build-offline-deb.sh <linux-unpacked> <closure-dir> <version> <out-dir>}"
VERSION="${3:?usage: build-offline-deb.sh <linux-unpacked> <closure-dir> <version> <out-dir>}"
OUT_DIR="${4:?usage: build-offline-deb.sh <linux-unpacked> <closure-dir> <version> <out-dir>}"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
ICONS_DIR="$REPO_ROOT/packages/desktop/build/icons"
GLIBC_MAX="2.31"
PACKAGE_NAME="zcode"
DELIVERABLE="zcode-kylin-v10-sp1-aarch64-glibc2.31-offline.deb"

for f in "$UNPACKED/zcode" "$UNPACKED/resources/app.asar" "$UNPACKED/chrome-sandbox"; do
  [ -e "$f" ] || { echo "E: 载荷缺少 $f（electron-builder dir 产物不完整）" >&2; exit 1; }
done
[ -x "$SCRIPT_DIR/install-deps.sh" ] || { echo "E: 缺少 install-deps.sh" >&2; exit 1; }
command -v dpkg-deb >/dev/null || { echo "E: 需要 dpkg-deb" >&2; exit 1; }
command -v objdump >/dev/null || { echo "E: 需要 objdump（binutils）" >&2; exit 1; }

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/opt/ZCode" "$STAGING/usr/bin" \
  "$STAGING/usr/share/applications" "$STAGING/usr/share/icons/hicolor/512x512/apps" \
  "$STAGING/usr/share/pixmaps" "$STAGING/DEBIAN" \
  "$STAGING/opt/ZCode/offline-deps"

# ---- 载荷 ----
cp -a "$UNPACKED/." "$STAGING/opt/ZCode/"
ln -s /opt/ZCode/zcode "$STAGING/usr/bin/zcode"
# 沙箱 SUID：Electron 沙箱在麒麟上依赖 setuid chrome-sandbox
chmod 4755 "$STAGING/opt/ZCode/chrome-sandbox"
install -m 0755 "$SCRIPT_DIR/install-deps.sh" "$STAGING/opt/ZCode/offline-deps/install-deps.sh"

# ---- 离线依赖闭包 ----
deb_count=0
for deb in "$CLOSURE_DIR"/*.deb; do
  [ -e "$deb" ] || continue
  cp "$deb" "$STAGING/opt/ZCode/offline-deps/"
  deb_count=$((deb_count + 1))
done
[ "$deb_count" -ge 1 ] || { echo "E: 闭包为空: $CLOSURE_DIR" >&2; exit 1; }
cp "$CLOSURE_DIR/closure-manifest.txt" "$STAGING/opt/ZCode/offline-deps/closure-manifest.txt"
# 种子清单随包内置：install-deps 的 apt 路径以种子为安装目标，
# 传递依赖由 apt 从闭包 file 仓库自动补齐。
cp "$SCRIPT_DIR/depends-seeds.txt" "$STAGING/opt/ZCode/offline-deps/depends-seeds.txt"

# ---- 本地 apt 仓库索引：install-deps 用 file 仓库 + --no-upgrade 只装缺失 ----
# apt 原生处理解包/配置顺序与触发器，避免 dpkg -i 在依赖顺序上翻车；
# 没有索引时 install-deps 自行回退 dpkg -i 逐包路径。
if command -v dpkg-scanpackages >/dev/null 2>&1; then
  (cd "$STAGING/opt/ZCode/offline-deps" && dpkg-scanpackages --multiversion . > Packages) \
    || echo "W: dpkg-scanpackages 失败，install-deps 将走 dpkg -i 回退路径" >&2
else
  echo "W: 构建机无 dpkg-scanpackages，install-deps 将走 dpkg -i 回退路径" >&2
fi

# ---- 桌面集成 ----
cat > "$STAGING/usr/share/applications/zcode.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=ZCode
Comment=ZCode AI Coding Agent
Exec=/opt/ZCode/zcode %U
Icon=zcode
Terminal=false
Categories=Development;IDE;
StartupWMClass=zcode
MimeType=x-scheme-handler/zcode;
EOF
icon_copied=0
for png in "$ICONS_DIR"/512x512.png; do
  if [ -e "$png" ]; then
    install -m 0644 "$png" "$STAGING/usr/share/icons/hicolor/512x512/apps/zcode.png"
    install -m 0644 "$png" "$STAGING/usr/share/pixmaps/zcode.png"
    icon_copied=1
  fi
done
[ "$icon_copied" = "1" ] || { echo "E: 缺少应用图标 $ICONS_DIR/512x512.png" >&2; exit 1; }

# ---- control ----
mapfile -t seeds < <(tr -d '\r' < "$SCRIPT_DIR/depends-seeds.txt" | grep -v '^#' | grep -v '^$' | sed 's/:arm64$//' | sort -u)
depends="libc6 (>= ${GLIBC_MAX}), libgcc-s1, libstdc++6, $(IFS=', '; echo "${seeds[*]}")"
installed_size=$(du -sk --apparent-size "$STAGING/opt/ZCode" "$STAGING/usr" | awk '{s+=$1} END {print s}')
cat > "$STAGING/DEBIAN/control" <<EOF
Package: ${PACKAGE_NAME}
Version: ${VERSION}
Section: devel
Priority: optional
Architecture: arm64
Installed-Size: ${installed_size}
Depends: ${depends}
Maintainer: ZCode <dev@zcode.z.ai>
Homepage: https://zcode.z.ai
Description: ZCode - AI coding agent desktop app (Kylin V10 SP1 aarch64 offline build)
 ZCode 桌面端（Electron），内含离线依赖闭包与补齐脚本。
 目标系统：银河麒麟 V10 SP1 aarch64（glibc 2.31，focal 同源）。
EOF

# ---- 维护脚本 ----
install -m 0755 "$SCRIPT_DIR/postinst" "$STAGING/DEBIAN/postinst"
install -m 0755 "$SCRIPT_DIR/postrm" "$STAGING/DEBIAN/postrm"

# ---- GLIBC 符号门禁（全量 ELF，构建期红线） ----
# 逐 ELF 用 objdump -T 取最高 GLIBC_ 引用；报告按版本倒序，超基线立即失败。
report_dir="$OUT_DIR"
mkdir -p "$report_dir"
scan_report="$report_dir/glibc-scan-report.txt"
: > "$scan_report"
max_seen="0"
while IFS= read -r -d '' f; do
  magic=$(head -c 4 "$f" | od -An -tx1 | tr -d ' \n')
  [ "$magic" = "7f454c46" ] || continue
  top=$(objdump -T "$f" 2>/dev/null | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail -1 || true)
  [ -n "$top" ] || continue
  top="${top#GLIBC_}"
  echo "$top $f" >> "$scan_report"
  higher=$(printf '%s\n%s\n' "$max_seen" "$top" | sort -V | tail -1)
  [ "$higher" = "$max_seen" ] || max_seen="$top"
done < <(find "$STAGING/opt/ZCode" -type f -print0)
sort -rV -o "$scan_report" "$scan_report"

higher=$(printf '%s\n%s\n' "$GLIBC_MAX" "$max_seen" | sort -V | tail -1)
if [ "$higher" != "$GLIBC_MAX" ]; then
  echo "E: GLIBC 基线超标：载荷最高引用 ${max_seen} > 允许 ${GLIBC_MAX}" >&2
  echo "E: 超标文件（前 10）:" >&2
  head -10 "$scan_report" >&2
  echo "::error::GLIBC baseline violated: max GLIBC_${max_seen} > ${GLIBC_MAX} (Kylin V10 SP1 aarch64)" >&2
  exit 1
fi
echo "[deb] GLIBC 门禁通过：载荷最高引用 GLIBC_${max_seen} <= ${GLIBC_MAX}"

# ---- 构建 deb ----
mkdir -p "$OUT_DIR"
internal_deb="$OUT_DIR/${PACKAGE_NAME}_${VERSION}_arm64.deb"
dpkg-deb --build --root-owner-group -Zgzip "$STAGING" "$internal_deb"

# ---- 构建后载荷自检（dpkg-deb -c 断言，曾发生漏拷应用本体的事故） ----
listing=$(dpkg-deb -c "$internal_deb")
assert_entry() {
  local label="$1" pattern="$2" hits=0
  hits=$(printf '%s\n' "$listing" | grep -c -- "$pattern" || true)
  if [ "$hits" -lt 1 ]; then
    echo "E: 载荷自检失败：deb 中缺少 $label" >&2
    exit 1
  fi
}
assert_entry "应用本体 /opt/ZCode/zcode" '\./opt/ZCode/zcode$'
assert_entry "应用入口 app.asar" '\./opt/ZCode/resources/app\.asar$'
assert_entry "chrome-sandbox" '\./opt/ZCode/chrome-sandbox$'
assert_entry "依赖补齐脚本" '\./opt/ZCode/offline-deps/install-deps\.sh$'
assert_entry "agent bundle (resources/glm)" '\./opt/ZCode/resources/glm/'
assert_entry "内置搜索工具 (resources/tools)" '\./opt/ZCode/resources/tools/'
# 符号链接行格式为 "./usr/bin/zcode -> /opt/ZCode/zcode"，不能锚定行尾
assert_entry "命令行入口 /usr/bin/zcode" '\./usr/bin/zcode'
assert_entry "desktop 文件" '\./usr/share/applications/zcode\.desktop$'
assert_entry "hicolor 图标" '\./usr/share/icons/hicolor/512x512/apps/zcode\.png$'
packed_debs=$(printf '%s\n' "$listing" | grep -c '\./opt/ZCode/offline-deps/.*\.deb$' || true)
if [ "$packed_debs" -lt "$deb_count" ]; then
  echo "E: 载荷自检失败：闭包不完整（打包 $packed_debs / 预期 $deb_count）" >&2
  exit 1
fi

# ---- 元数据校验 ----
[ "$(dpkg-deb -f "$internal_deb" Architecture)" = "arm64" ] || { echo "E: Architecture 不是 arm64" >&2; exit 1; }
[ "$(dpkg-deb -f "$internal_deb" Package)" = "$PACKAGE_NAME" ] || { echo "E: Package 名不符" >&2; exit 1; }
[ "$(dpkg-deb -f "$internal_deb" Version)" = "$VERSION" ] || { echo "E: Version 不符" >&2; exit 1; }

# ---- 交付物命名与校验和 ----
cp "$internal_deb" "$OUT_DIR/$DELIVERABLE"
(
  cd "$OUT_DIR"
  sha256sum "$DELIVERABLE" > "$DELIVERABLE.sha256"
)
cp "$CLOSURE_DIR/closure-manifest.txt" "$OUT_DIR/closure-manifest.txt" 2>/dev/null || true

size_mb=$(du -m "$internal_deb" | cut -f1)
echo "[deb] 完成: $internal_deb (${size_mb}MB, 闭包 ${deb_count} 个)"
echo "[deb] 交付物: $OUT_DIR/$DELIVERABLE"
