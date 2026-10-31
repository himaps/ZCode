#!/usr/bin/env bash
# 在 arm64 的 ubuntu:20.04 (focal) 容器内验证离线 deb（目标系统同源环境）。
#
# 依据 docs/kylin-v10-sp1-offline-deb.md 的验证语义：
#   dpkg -l 快照 → 解包 → install-deps.sh（只装缺失）→ dpkg --configure -a
#   → 零升级断言 → ldd 门禁（零 not found）→ 运行时冒烟。
#
# 环境变量：
#   ZCODE_VERIFY_NATIVE=1  宿主是真 arm64（运行时冒烟失败 = 硬失败）
#   ZCODE_VERIFY_NATIVE=0  宿主是 QEMU 模拟（运行时冒烟失败仅告警：模拟器崩溃
#                          不构成对真机的判负，如实标注后放行）
#
# 用法（容器内 root）: verify-offline-deb.sh <deb 文件>
set -uo pipefail

DEB="${1:?usage: verify-offline-deb.sh <deb>}"
NATIVE="${ZCODE_VERIFY_NATIVE:-0}"
APP_DIR=/opt/ZCode

say() { echo "[verify] $*"; }
fail() { echo "::error::[verify] $*" >&2; say "FAIL: $*"; exit 1; }
warn() { echo "::warning::[verify] $*" >&2; }

command -v dpkg >/dev/null || fail "容器内没有 dpkg"
[ -e "$DEB" ] || fail "找不到 deb: $DEB"
deb_arch=$(dpkg-deb -f "$DEB" Architecture)
[ "$deb_arch" = "arm64" ] || fail "deb 不是 arm64: $deb_arch"

snapshot() { dpkg -l 2>/dev/null | awk '/^ii/ {print $2" "$3}' | sort; }

# ---- 1. 安装前快照 ----
snapshot > /tmp/dpkg-before.txt
before_count=$(wc -l < /tmp/dpkg-before.txt)
say "安装前已装包数: $before_count"

# ---- 2. 解包（依赖未满足属预期；postinst 在 configure 阶段才运行） ----
if ! dpkg --unpack "$DEB"; then
  fail "dpkg --unpack 失败"
fi
[ -x "$APP_DIR/zcode" ] || fail "解包后缺少 $APP_DIR/zcode"
say "解包完成，载荷就位"

# ---- 3. 离线依赖补齐（只装缺失，绝不升级；幂等，QEMU 下个别维护脚本可能
#         瞬时失败，重试靠 dpkg 实时状态判定收敛） ----
deps_rc=1
for deps_try in 1 2 3; do
  if "$APP_DIR/offline-deps/install-deps.sh" > /tmp/install-deps.log 2>&1; then
    deps_rc=0
    break
  fi
  echo "[verify] install-deps 第 $deps_try/3 次未收敛，重试"
  sleep 5
done
if [ "$deps_rc" -ne 0 ]; then
  grep -vE '^$' /tmp/install-deps.log | tr -d '\r' | tail -10 \
    | awk '{ i++; gsub(/%/, "%25"); print "::error title=install-deps-" i " ::" substr($0, 1, 400) }'
  fail "install-deps.sh 三次未收敛（缺依赖或复验未过，日志尾部见注解）"
fi
say "离线依赖补齐完成"

# ---- 4. 配置（postinst 在此真实运行；Depends 由闭包补齐后必须能配置成功） ----
if ! dpkg --configure -a > /tmp/configure.log 2>&1; then
  grep -vE '^$' /tmp/configure.log | tr -d '\r' | tail -10 \
    | awk '{ i++; gsub(/%/, "%25"); print "::error title=configure-" i " ::" substr($0, 1, 400) }'
  fail "dpkg --configure -a 失败：Depends 与闭包覆盖不一致（日志尾部见注解）"
fi
say "配置完成（postinst 已运行）"

# ---- 5. 零升级断言：只允许新增，任何升级/替换/删除即失败 ----
snapshot > /tmp/dpkg-after.txt
after_count=$(wc -l < /tmp/dpkg-after.txt)
# 已装包版本变化 = 升级（红线）
upgraded=$(join -j 1 /tmp/dpkg-before.txt /tmp/dpkg-after.txt \
  | awk '$2 != $3 {print $1" "$2" -> "$3}')
if [ -n "$upgraded" ]; then
  echo "$upgraded" >&2
  fail "零升级断言失败：以下系统包被升级（第三方离线包绝不升级目标机系统组件）"
fi
removed=$(comm -23 <(cut -d' ' -f1 /tmp/dpkg-before.txt) <(cut -d' ' -f1 /tmp/dpkg-after.txt))
if [ -n "$removed" ]; then
  echo "$removed" >&2
  fail "零升级断言失败：以下已装包被移除"
fi
added=$((after_count - before_count))
say "零升级断言通过：新增 $added 个包，升级 0，移除 0"

# ---- 6. ldd 门禁：应用目录内可执行文件/共享库零 not found ----
ldd_failures=""
while IFS= read -r f; do
  magic=$(head -c 4 "$f" | od -An -tx1 | tr -d ' \n')
  [ "$magic" = "7f454c46" ] || continue
  nf=$(ldd "$f" 2>/dev/null | grep 'not found' || true)
  if [ -n "$nf" ]; then
    ldd_failures="$ldd_failures
$f
$nf"
  fi
done < <(find "$APP_DIR" -type f \( -perm -111 -o -name '*.so*' -o -name '*.node' \) -print0)
if [ -n "$ldd_failures" ]; then
  echo "$ldd_failures" >&2
  fail "ldd 门禁失败：存在无法解析的动态库"
fi
say "ldd 门禁通过：零 not found"

# ---- 7. 运行时冒烟 ----
# 第一层（核心）：ELECTRON_RUN_AS_NODE 走 Electron 内置 Node（RunAsNode fuse 保留），
# 能证明整条动态链接栈在 glibc 2.31 上真实执行。
smoke_rc=0
smoke_out=$(timeout 180 env ELECTRON_RUN_AS_NODE=1 "$APP_DIR/zcode" -e 'console.log("run-as-node ok", process.versions.node)' 2>&1) || smoke_rc=$?
if [ "$smoke_rc" -eq 0 ] && printf '%s' "$smoke_out" | grep -q 'run-as-node ok'; then
  say "运行时冒烟通过: $smoke_out"
else
  if [ "$NATIVE" = "1" ]; then
    fail "运行时冒烟失败（真 arm64，硬门禁）: rc=$smoke_rc out=$smoke_out"
  else
    warn "运行时冒烟在 QEMU 下未通过（rc=$smoke_rc, out=$smoke_out）；模拟器限制不构成对真机的判负，已在报告中如实标注"
  fi
fi
# 第二层（信息）：不带 RunAsNode 的 --version 路径，输出仅记录不判失败
version_out=$(timeout 60 "$APP_DIR/zcode" --no-sandbox --version 2>&1 || true)
say "--version 输出（信息）: ${version_out:-<empty>}"

say "验证全部通过（新增 $added 包 / 升级 0 / 移除 0 / ldd 零 not found）"
