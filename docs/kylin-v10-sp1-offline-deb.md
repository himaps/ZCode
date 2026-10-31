# 银河麒麟 V10 SP1 (aarch64 / glibc 2.31) 离线 deb 交付规范

## 目标产物

- 交付物：`zcode-kylin-v10-sp1-aarch64-glibc2.31-offline.deb`（内部包名 `zcode_<version>_arm64.deb`， deb 格式）。
- 目标系统：银河麒麟桌面操作系统 V10 SP1（2503），**aarch64**，glibc **2.31**，GCC 9.3，上游血脉 **Ubuntu 20.04 (focal)**。
- 包身份：生产 flavor（`ZCODE_ENV=production`，包名 `zcode`、可执行名 `zcode`，见 `packages/desktop/scripts/desktop-product-identity.mjs`）。
- 离线 deb = 应用本体 + 运行时依赖闭包（`/opt/ZCode/offline-deps/*.deb`）+ 依赖补齐脚本（`install-deps.sh`）。离线机是国产化场景常态，装完即可运行，不要求目标机联网。

## 版本矩阵与红线（不可协商）

1. **glibc 基线 2.31**：产物引用的最高 `GLIBC_x.y` 符号不得高于 2.31。AppImage/上游二进制不内置 glibc，该基线由"构建/打包所选的库版本 + 预编译载荷"共同决定，只能验证、不能绕过。
2. **绝不升级目标机系统组件**：第三方离线包升级 systemd/glibc 等系统件会把用户系统搞崩（deepin-screenshot 事故）。三重防线缺一不可：
   - 构建闭包基线与目标机同源（focal 容器，包名与版本即麒麟本尊）；
   - `install-deps.sh` **只装缺失的包**（`dpkg-query ${Status}` 非 `install ok installed` 才装），没有任何版本比较后的"升级"分支；
   - 闭包黑名单：`Essential: yes`、`libc6`（glibc 家族）、`systemd*`、`dbus*`、`libpam*`、`udev`、`login`、`passwd` 永不进入闭包。
3. **dpkg 全程持锁**：维护脚本（postinst）绝不嵌套 `dpkg -i`。postinst 只做检测与提示，通过 `systemd-run --on-active=10` 延迟执行 `install-deps.sh`（结果 `journalctl -u zcode-deps`），systemd 不可用时打印手动命令。
4. **V10 原版与 V10 SP1 的 `/etc/os-release VERSION_ID` 相同（都是 v10）**，只能靠 `PRETTY_NAME`/`PROJECT_CODENAME=v10sp1` 区分。本产物的 glibc 2.31 基线 **不能** 跑在 V10 原版（glibc 2.23）上。

## 构建环境选型（Ubuntu 版本说明）

| 候选 | 结论 |
| --- | --- |
| `ubuntu:20.04` focal 容器 | **选定**。与 V10 SP1 同源同版本：glibc 2.31、包名/版本一致（libicu66 等），闭包包名错配从根上消失 |
| `ghcr.io/distrotwin/kylin:v10sp1-*` | 备选（麒麟公开归档自举）。若改用必须钉带日期的 tag，滚动 tag 会跨版本漂移 |
| Debian bullseye | 仅可作符号基线参考。包名/版本与 focal 血脉不同，且已过 LTS（security pool 404），**禁止**用其闭包交付麒麟 |

focal 已过标准支持期，CI 上必须：`Acquire::Check-Valid-Until "false"`、`Acquire::http(s)::Timeout "30"`、`DEBIAN_FRONTEND=noninteractive`、`timeout` 包裹 apt、逐 suite 降级（某 suite 归档化时剔除而不是整体失败）。arm64 包一律来自 `ports.ubuntu.com`（不是 archive.ubuntu.com）。

## 构建链路

GitHub Actions（`.github/workflows/kylin-v10-sp1-arm64.yml`），触发：

- `push tag kylin-v10sp1-*` → 构建 + 验证 + 自动创建 GitHub Release；
- `workflow_dispatch` → 手动构建 + 验证（不发布）。

1. **build（ubuntu-latest, amd64 交叉出 arm64 载荷）**
   - Electron 预检门禁：下载 `electron-v<ver>-linux-arm64.zip`，`objdump -T` 扫描主二进制，最高 `GLIBC_` 引用 > 2.31 立即失败（快速失败，不打无效的包）。
   - `pnpm install --frozen-lockfile`（`pnpm-workspace.yaml` 的 `supportedArchitectures` 已含 linux/arm64/glibc；node-pty、koffi 均为随包预编译，`npmRebuild: false`）。
   - `pnpm --filter @zcode/desktop build` + `electron-builder --linux dir --arm64`（环境：`ZCODE_ENV=production`、`ZCODE_TARGET_OS=linux`、`ZCODE_TARGET_ARCH=arm64`；复用 electron-builder.config.js 的 afterPack 注入/校验钩子）。
   - focal amd64 容器内下载 arm64 依赖闭包（`packaging/kylin/v10-sp1/collect-offline-closure.sh`）：以 `depends-seeds.txt` 为根，`apt-cache depends --recurse` 按 Depends 递归展开，剔除黑名单后 `apt-get download <pkg>:arm64` 逐包下载（重试 ×3），产出闭包 `.deb` 与清单。
   - `build-offline-deb.sh` 组装 deb：载荷 `/opt/ZCode`（含 `resources/glm` JS agent bundle、`resources/tools` ripgrep/bfs/ugrep、node-pty 预编译）、`/usr/bin/zcode` 符号链接、desktop 文件与 hicolor 图标、`chrome-sandbox` 4755；`Depends = libc6 (>= 2.31), libgcc-s1, libstdc++6 + seeds`（只声明真正的 ELF 依赖；dlopen 的运行库由闭包兜底、桌面环境必有）。`dpkg-deb --build --root-owner-group -Zgzip`。
   - **载荷自检**（构建后）：`dpkg-deb -c` 断言应用本体、app.asar、install-deps.sh、闭包（≥1 个 .deb）确实在包内；随后对载荷内全部 ELF 做全量 `GLIBC_` 符号扫描门禁（≤ 2.31）。曾发生过离线包漏拷应用本体只有闭包的事故，此检查是硬门禁。
2. **verify（arm64 `ubuntu:20.04` 容器）**
   - runner 选择：`vars.ZCODE_ARM64_RUNNER`（仓库变量，如 `ubuntu-24.04-arm`）优先；未配置时默认 `ubuntu-latest` + QEMU binfmt 模拟 arm64。
   - 流程（`verify-offline-deb.sh`）：安装前 `dpkg -l` 快照 → `dpkg -i` 离线 deb（依赖未满足属预期，断言载荷已解包）→ 执行 `install-deps.sh`（只装缺失）→ `dpkg --configure -a` 必须成功（证明 Depends 与闭包覆盖一致，postinst 在此真实运行）→ **零升级断言**（快照对比：只允许新增，任何升级/替换/删除即失败——ldd 抓不住"把 systemd 升级了"这类事故）→ **ldd 门禁**（`/opt/ZCode` 下全部 ELF 零 `not found`）→ 运行时冒烟：`ELECTRON_RUN_AS_NODE=1 zcode -e`（真机 arm64 为硬门禁；QEMU 下失败仅告警——模拟器崩溃不构成对真机的判负，如实标注）。
3. **release（仅 tag）**：`gh release create`（重试 ×3），资产为 deb + sha256。

## 安装与卸载契约（目标机）

- 常规安装：`sudo dpkg -i zcode-kylin-v10-sp1-aarch64-glibc2.31-offline.deb`。麒麟桌面自带 GTK3/NSS 等依赖时直接配置完成；缺依赖时 dpkg 停在 unpacked，postinst 会安排 `install-deps.sh` 延迟补装（systemd）或提示手动执行。
- `install-deps.sh`：幂等；只装 `/opt/ZCode/offline-deps/` 内缺失包；结束后 ldd 复验主二进制，输出"全部就绪"或仍缺清单；结果进 `journalctl -u zcode-deps`。
- 卸载：`sudo dpkg -r zcode`；用户数据（`~/.zcode`）保留，不清理。
- 沙箱：`chrome-sandbox` 以 4755 随包安装；postinst 兜底 chmod。

## 所有者与事件顺序

```
GitHub Actions build job ──产出──> 离线 deb（载荷 + 闭包 + install-deps.sh）
                                        │ dpkg -i（目标机）
                                        ▼
                       postinst（dpkg 锁内：断言/缓存刷新/提示）
                                        │ systemd-run --on-active=10
                                        ▼
                       install-deps.sh（锁外：只装缺失 → ldd 复验）
                                        │
                                        ▼
                       verify job 语义：快照 → 装 → configure → 零升级 → ldd → 冒烟
```

状态所有者：dpkg 数据库（目标机）是安装状态的唯一事实；`install-deps.sh` 不自建状态文件，每次按 dpkg-query 实时判定，天然幂等。

## 已知限制与后续

- Electron 44 主二进制的实际最高 `GLIBC_` 引用需以 CI 门禁实测为准（仓库 rpm 注释记录过 Electron 41 仅引用到 2.25；44 未实测前不假设）。门禁失败时必须停下来与维护者对齐（例如降级 Electron），不允许加兜底分支掩盖。
- 默认 verify 走 QEMU；对真机的最强验证仍是在 `vars.ZCODE_ARM64_RUNNER` 配置原生 arm64 runner（或人工在麒麟机上 `dpkg -i` + `journalctl -u zcode-deps`）。
- Release 资产上限 2GiB/文件；当前载荷规模接近但未超，若超限需拆分依赖闭包为独立资产。
- 上游产物（AppImage/deb/rpm/pacman）不受本规范约束；本目录只服务麒麟 V10 SP1 aarch64 离线交付。
