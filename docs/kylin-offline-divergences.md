# ZCode 离线 fork 分歧清单（合并上游后核对用）

himaps/ZCode 是 zai-org/ZCode 的 fork（不向上游 PR），为国产化离线环境维护以下分歧。
**每次合并 upstream/main 后按本清单逐项核对**；上游改动碰撞到这些区域时，以本清单意图为准重放。

## 1. 离线 UI 收敛

| 分歧 | 位置 | 手段 |
| --- | --- | --- |
| 移动端远程控制入口关闭 | `packages/desktop/src/renderer/src/main.tsx` `<Root>` | `webRemoteControlFeatureEnabled={false}`（现成 feature flag，Root.tsx 同时 gate 轮询） |
| 个人信息弹窗【升级】菜单项移除 | `WorkspaceSidebarFooterUsageSummary.tsx`（UsageSummaryContent） | 删 upgrade `DropdownMenuItem`；`onUpgradeClick` prop 链路一并移除（footer / SettingsPage / project-sidebar）；composer 内其他升级入口未动 |
| 个人信息弹窗【邀请好友】移除 | `WorkspaceSidebarFooter.tsx` | 删 rewards 菜单项 + `Gift`/`Badge` import + `useOpenRewards`；RewardsProvider/MarketingTouch 本体保留 |
| 界面语言仅中文/英文 | `packages/shared/src/protocol.ts` `UI_ENABLED_LOCALES` | 两处下拉（`settingsPageHelpers.tsx`、`WorkspaceSidebarFooter.tsx`）消费白名单而非 `SUPPORTED_LOCALES`；上游新增语言资源继续随包、类型不变 |
| 语音输入组件移除 | `packages/ui/src/components/ai-elements/speech-input.tsx` | 文件删除（上游本就无挂载点，属孤儿组件；若上游将来挂载需重新评估） |
| provider 登录引导关闭 | `packages/ui/src/lib/rootStartupGate.ts` `shouldEnableProviderAvailabilityLoginEntryGuard` | 固定返回 false：内网/离线使用不配置云端账号，跳过【输入 API Key / 暂时跳过】引导直达主界面；激活门禁（ActivationGate）独立负责激活拦截 |

相关 e2e（本流水线不跑，本地跑会红）：`marketing-touch-rewards.test.ts`（rewards 菜单与升级按钮断言）、coding-plan-upgrade 相关 e2e。

## 2. 离线激活门禁

见 `docs/kylin-offline-activation.md`。核心新增：`packages/shared/src/activation.ts`、
`packages/desktop/src/main/desktopActivationIpc.ts`、`packages/ui/src/activation/ActivationGate.tsx`、
preload `window.zcodeActivation`、`packaging/offline-kit/zcode-activation-tool.html`。
合并时注意上游对 `packages/desktop/src/main/index.ts` IPC 注册区、preload zcode bridge、
renderer main.tsx `<Root>` 的改动需保留我们的插入点。

## 3. 麒麟 V10 SP1 aarch64 离线交付

见 `docs/kylin-v10-sp1-offline-deb.md` 与 `.github/workflows/kylin-v10-sp1-arm64.yml`（上游没有的纯新增文件，无合并冲突面）。定制图标在 `packages/desktop/build/`（上游若回改图标，以我们的覆盖）。

## 4. 版本策略

deb/exe 版本随根 `package.json`；合并上游后版本号取上游（上游 ≥ 我们时），tag `kylin-v10sp1-aarch64-<ver>` 触发构建。
