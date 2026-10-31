#!/bin/sh
# ZCode 离线依赖补齐脚本（随 deb 安装到 /opt/ZCode/offline-deps/install-deps.sh）。
#
# 红线（docs/kylin-v10-sp1-offline-deb.md）：
# - 只装目标机缺失的包，绝不升级已装的：主路径用 apt --no-upgrade（apt 原生保证
#   "已装即跳过，无论版本"），回退路径按 dpkg-query 状态实时判定；
# - 脚本幂等：安装状态以 dpkg 数据库为唯一事实，每次实时判定；
# - 真机上由 postinst 经 systemd-run 延迟调用（dpkg 维护脚本内禁止嵌套 dpkg -i），
#   也可由用户 root 手动执行；结果查看 journalctl -u zcode-deps。
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

rc=0

# ---- 主路径：闭包目录作为本地 file 仓库，apt --no-upgrade 只装缺失 ----
# 独立的 lists/cache/sourceparts 目录，不触碰系统 apt 状态；--no-upgrade 下
# apt 原生跳过任何已安装的包（无论版本），并按依赖序正确解包与配置。
if [ -f "$DEPS_DIR/Packages" ] && command -v apt-get >/dev/null 2>&1; then
  WORK=/tmp/zcode-offline-apt
  mkdir -p "$WORK/lists" "$WORK/cache/archives/partial"
  LIST_FILE="$WORK/zcode-offline.list"
  echo "deb [trusted=yes] file://$DEPS_DIR ./" > "$LIST_FILE"
  APT_OPTS="-o Dir::Etc::sourcelist=$LIST_FILE \
-o Dir::Etc::sourceparts=/dev/null \
-o Dir::State::lists=$WORK/lists \
-o Dir::Cache::archives=$WORK/cache/archives \
-o APT::Get::AllowUnauthenticated=true \
-o Acquire::AllowDowngradeToInsecureRepositories=true"
  if apt-get $APT_OPTS update > /tmp/zcode-deps-apt-update.log 2>&1 \
      && apt-get $APT_OPTS install -y --no-upgrade --no-install-recommends \
           $(cat "$DEPS_DIR/depends-seeds.txt") > /tmp/zcode-deps-apt-install.log 2>&1; then
    say "apt 本地仓库补装完成（--no-upgrade：已装包一律未触碰）"
    APT_OK=1
  else
    say "apt 本地仓库路径失败（unmet 明细如下），回退 dpkg -i"
    grep -aE '^(E:|The following packages| [a-z])' /tmp/zcode-deps-apt-install.log 2>/dev/null | tail -12 || true
    tail -5 /tmp/zcode-deps-apt-install.log 2>/dev/null || true
    APT_OK=0
  fi
else
  APT_OK=0
  say "缺少 Packages 索引或 apt-get，走 dpkg -i 回退路径"
fi

# ---- 回退路径：dpkg -i 只挑缺失的包 ----
# ${Status} 为 "install ok installed" 的一律跳过（任何版本都不碰）。
if [ "${APT_OK:-0}" != "1" ]; then
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

  if [ -n "$todo" ]; then
    say "dpkg -i 回退：补装缺失依赖（共 $(echo $todo | wc -w) 个；已安装跳过 $skipped 个）"
    # 一次性交给 dpkg，包间顺序由 dpkg 自行处理
    if ! dpkg -i $todo; then
      say "dpkg -i 返回非零，尝试 dpkg --configure -a 收尾"
      dpkg --configure -a || rc=1
    fi
  else
    say "没有缺失依赖（$skipped 个均已安装）"
  fi
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
