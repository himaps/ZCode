#!/bin/sh
# ZCode 离线依赖补齐脚本（随 deb 安装到 /opt/ZCode/offline-deps/install-deps.sh）。
#
# 红线（docs/kylin-v10-sp1-offline-deb.md）：
# - 只装目标机缺失的包，绝不升级已装的：todo 预过滤按 dpkg-query 状态实时判定，
#   ${Status} 为 "install ok installed" 的包任何版本都不碰；无 apt 交易、无升级分支；
# - 脚本幂等：重复执行按 dpkg 数据库实时判定收敛；
# - 真机上由 postinst 经 systemd-run 延迟调用（dpkg 维护脚本内禁止嵌套 dpkg -i），
#   也可由用户 root 手动执行；结果查看 journalctl -u zcode-deps。
#
# 安装配方：dpkg -i --force-depends（全部解包、容忍依赖序）+ dpkg --configure -a
# （此时闭包内所有包都已解包，dpkg 按依赖序统一配置）。这是离线 bundle 的标准
# 配方；不再用 apt file 仓库（--no-upgrade 的全有全无解析在闭包成员与 focal base
# 组合上会报 unmet 中止整个交易）。
set -u

DEPS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_DIR=$(CDPATH= cd -- "$DEPS_DIR/.." && pwd)
MAIN_BIN="$APP_DIR/zcode"
LOG="[zcode-deps]"

say() { echo "$LOG $*"; }

if [ "$(id -u)" != "0" ]; then
  say "ERROR: 需要 root 权限（sudo 执行本脚本）"
  exit 1
fi

# ---- 只挑缺失的包：${Status} 为 "install ok installed" 的一律跳过（任何版本都不碰） ----
todo=""
skipped=0
for deb in "$DEPS_DIR"/*.deb; do
  [ -e "$deb" ] || continue
  pkg=$(dpkg-deb -f "$deb" Package)
  status=$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || echo "not-installed")
  if [ "$status" = "install ok installed" ]; then
    skipped=$((skipped + 1))
    continue
  fi
  # 注意：$todo 有意不做引号展开，按空白拼接为一次 dpkg -i 的参数列表；
  # 路径由本脚本目录派生（/opt/ZCode/offline-deps），不含空白。
  todo="$todo $deb"
done

rc=0
if [ -n "$todo" ]; then
  say "补装缺失依赖（共 $(echo $todo | wc -w) 个；已安装跳过 $skipped 个）"
  # --force-depends：一次性解包全部，依赖序交给 configure 阶段
  if ! dpkg -i --force-depends $todo > /tmp/zcode-deps-dpkg.log 2>&1; then
    say "dpkg -i 返回非零（明细见 /tmp/zcode-deps-dpkg.log），继续 dpkg --configure -a"
  fi
  if ! dpkg --configure -a >> /tmp/zcode-deps-dpkg.log 2>&1; then
    say "dpkg --configure -a 失败（明细见 /tmp/zcode-deps-dpkg.log）"
    grep -aE 'dpkg: error|error processing|依赖问题' /tmp/zcode-deps-dpkg.log 2>/dev/null | tail -8 || true
    rc=1
  fi
else
  say "没有缺失依赖（$skipped 个均已安装）"
fi

# ---- ldd 复验：主二进制与原生模块的 ELF 依赖必须全部可解析 ----
# 范围收敛到可执行文件与共享库（perm +x / *.so* / *.node）：
# 全树逐文件 ldd 在低配目标机上要跑几分钟且没有增量信息（其余文件不是动态链接对象）。
missing_report=""
if [ -x "$MAIN_BIN" ]; then
  elfs=$(find "$APP_DIR" -type f \( -perm -111 -o -name '*.so*' -o -name '*.node' \) -size +4c | while IFS= read -r f; do
    magic=$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')
    [ "$magic" = "7f454c46" ] && printf '%s\n' "$f"
  done)
  for elf in $elfs; do
    not_found=$(ldd "$elf" 2>/dev/null | grep 'not found' || true)
    if [ -n "$not_found" ]; then
      missing_report="$missing_report
$elf:
$not_found"
    fi
  done
else
  say "ERROR: 应用本体缺失: $MAIN_BIN"
  missing_report="$MAIN_BIN"
fi

if [ -n "$missing_report" ]; then
  say "复验发现仍缺的动态库（请把以下内容反馈给维护者）: $missing_report"
  rc=1
else
  say "全部就绪：依赖闭包完整，应用 ELF 依赖均可解析"
fi

exit $rc
