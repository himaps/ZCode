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
| 左下角【连接使用】入口移除 | `packages/ui/src/WorkspaceSidebarFooter.tsx` | ①删弹窗菜单末项【连接使用】（`app.login` 菜单项，点击会拉起云端账号登录，内网不可用）；②未登录时触发区仅保留头像，不显示"连接使用"文案（`getSidebarProfileBadge` 未登录 fallback 返回空串，span 条件渲染，aria-label 兜底 "ZCode"）；`onLogin` prop 类型保留但组件不再解构消费，传参无害（内网无账号登录入口）。合并后核对：菜单内不得再现 `app.login` 项，未登录 footer 不得出现 `sidebar.profile.notLoggedIn` 文案 |
| 复制/导出默认不含思考过程（新增开关） | `packages/shared/src/protocol.ts`（`AppSettings.includeThinkingInCopy`）、`validationAppSettings.ts`、`v4/ConversationTurnRow.tsx` `resolveAssistantCopyText(unit, includeThinking)`、`v4/ConversationTurnGroup.tsx`、`v4/conversationRowContext.ts`、`v4/SessionPane.tsx`、`settingsPageHelpers.tsx` + `SettingsPage.tsx` + i18n `settings.includeThinkingInCopy` | 复制/导出（Copy 与「导出为 markdown」共用同一 `text`）默认只取 `latestAssistantTextRow`（最终答案），不含前面的工作日志/思考文本与「已工作/提示」汇总；设置「复制/导出时包含思考过程」默认关闭，开启后还原为合并整轮助手文本 + 计划正文（上游原行为）。合并后核对：`resolveAssistantCopyText` 双参 + `includeThinkingInCopy` 开关须保留 |
| 右上角帮助菜单移除 5 个云端二级项 | `packages/ui/src/WorkspaceHelpMenuButton.tsx` | 删 用户社群 / 问题上报 / 提交漏洞 / 给产品提需求 / 检查更新 五项，保留 产品文档 / 导出日志 / 复制设备MID / 资源管理器 / 关于；清理失效 icon（Users/MessageSquare/ShieldAlert/Lightbulb/RefreshCw）、`useDesktopUpdateMenu`、`useVulnerabilityReportUrl`、`openFeatureRequest`、`handleOpenCommunity`。合并后核对：该菜单不得再现上述 5 项 |
| 托盘右键移除【检查更新】 | `packages/desktop/src/main/desktopTray.ts` | 删 production 分支的 检查更新 菜单项 + `ZCODE_PRODUCT_FLAVOR` import；保留 关于/导出日志/退出 及既有分隔。合并后核对：托盘菜单不得再现 `helpCheckForUpdates` 项 |
| 原生菜单 Help→【问题上报】移除 | `packages/desktop/src/main/desktopApplicationMenu.ts` | 删 `helpFeedback` 菜单项（`DesktopCommandIds.OpenFeedback`）；保留 资源管理器/导出日志/清除数据 |
| 任务右键/更多菜单【反馈问题】移除 | `TaskActionMenuContent.tsx`、`project-sidebar/grouped/task-context-menu-content.tsx` + 调用处 `TaskListItem`、`TaskListItemContextMenu`、`WorkspaceHeaderSections`、`grouped/task-row` | 删 `onOpenTaskFeedback` 菜单项及整条 prop/handler 链（含各 `handleOpenTaskFeedback`、`useFeedbackStore.openSubmit`、`buildTaskFeedbackDescription` 引用）。合并后核对：任务菜单不得再现 `taskList.feedback` 项 |
| 错误/连接态【反馈】按钮移除 | `ChatErrorBanner.tsx`、`v4/SessionSubscriptionErrorPanel.tsx`、`remote-connection/RemoteConnectionConnectingStep.tsx` | 删各「反馈/反馈问题」按钮 + `handleOpenFeedback` + `openFeedbackSubmit` + 反馈描述构造器（`buildErrorFeedbackDescription`/`buildRemoteConnectionFeedbackDescription`）与相关 import；仅该按钮消费的 `ChatErrorBanner` `remoteKind` prop 及 `ConversationComposer` 对应 `useOptionalTabStore` 选择器一并移除；保留 复制日志/重连/重试 等本地动作。合并后核对：错误横幅/远端连接页不得再现 `chat.error.feedback`/`remoteConnection.feedback` 按钮 |
| quickpick【问题上报】指令移除 | `packages/ui/src/quickpick/quickPickCommands.ts` | 删 `id:"feedback"` 指令（`quickPick.command.feedback`）。合并后核对：quickpick 不得再现该指令 |
| 激活页「注册码」文字改品牌红 | `packages/ui/src/activation/ActivationGate.tsx` | 激活码 `<Input>` className 加 `text-[#cf3d4f]`（定制图标品牌红，同启动屏 Z 徽章）。合并后核对：激活输入框须保留红色 |
| Windows 启动左上/顶部黑闪修复 | `packages/desktop/src/main/desktopWindowChrome.ts` `buildDesktopWindowVisualOptions()` win32 分支 | win32 `backgroundColor` 由 `#00000000`（透明黑）改为不透明 `#1c1c1c` 并去掉 `backgroundMaterial:"acrylic"`，消除首帧前标题栏黑闪（代价：Windows 失去玻璃透明，改纯深色窗体，离线可接受）。仅改 win32，macOS/Linux 不动。合并后核对：win32 分支须保留不透明深色底 |
| 模型设置仅保留自定义供应商 | `settings/ModelProviderSection.tsx`（`FORK_OFFLINE_HIDE_PRESET_PROVIDERS` 置空 `presetProviders`）、`model-provider-section/useModelProviderNavigation.ts`（`FORK_OFFLINE_HIDE_PRESET_NAV_GROUP` 过滤 preset 组）、`model-provider-section/ProviderTemplatePicker.tsx`（`FORK_OFFLINE_HIDE_PRESET_TEMPLATES` 隐藏厂商模板，只留「创建自定义供应商」卡片） | 内网无法连接厂商模型服务，隐藏预置厂商（Z.ai/BigModel + 套餐）；聊天模型选择走 service catalog，不受本设置 UI 影响。合并后核对：模型设置须只呈现自定义供应商 |
| 分享功能整体移除 | `settings/settingsPageConfig.ts`（删 `shares` 段）、`lib/settingsNavigation.ts`（`SettingsSectionId` 去 `"shares"`）、`SettingsPage.tsx`（删 `SettingsShareManagement` 分支/导入/`onOpenTask`）、`root/types.ts`+`root/RootWorkspaceContent.tsx`+`root/WorkspaceSettingsLayer.tsx`+`root/useRootWorkspaceActions.ts`（删 `onOpenTask`/`handleOpenTaskFromSettings` 链）、`WorkspaceHeaderSections/WorkspaceHeaderActionSection.tsx`（删右上角 `ConversationShareMenu` 触发）、`v4/SessionPane.tsx`（`FORK_OFFLINE_DISABLE_CONVERSATION_SHARE` gate 会话内 `ConversationSharePopover`+选择面板） | 分享依赖云端分享服务器，内网不可用。`conversation-share-interaction/` 模块文件与 `ConversationShareMenu.tsx` 暂留为死代码（未删模块清单/architecture-policy，降低合并面）。合并后核对：设置无「分享管理」段、右上角无【分享会话】、会话内无分享气泡 |
| 设置移除「自动下载并安装更新」 | `settingsPageHelpers.tsx`（删 SettingsRow+props）、`SettingsPage.tsx`（state/水合/handler/传参）、`UpdateStatusDialog.tsx`（删勾选框+`Checkbox` import）、`UpdateStatusDialogController.tsx`（state/水效/handler/传参）、`settingsSearchIndex.ts`（删条目） | 内网无更新服务器，自动下载更新无意义。shared 的 `autoDownloadAndInstallUpdates` 字段与 `autoUpdater.ts` 读取保留（恒 false，无害）。合并后核对：设置/更新弹窗不得再现该开关 |

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

- **fork 构建版本 = `<上游基线>-fork.<n>`**（当前 `3.18.2-fork.1`）：deb/exe 版本随根
  `package.json`，tag `kylin-v10sp1-aarch64-<ver>` 触发构建。`-fork.n` 后缀使 fork 版本
  与上游纯 `x.y.z` 版本**永不撞号**——见到的任何 `x.y.z-fork.n` 都明确是本仓库的自行
  升级构建（含 fork 功能：离线收敛、激活门禁、定制品牌等），不是上游发行版。
- **合并策略（重要）**：fork 版本号**不代表上游进度**。上游（zai-org/ZCode）发布任何
  新版本后——无论与 fork 版本数字是否相同、谁高谁低——都必须 fetch + merge 上游代码，
  再以合并后的新基线重新计版本（`<新上游基线>-fork.1` 起重新计数）。禁止以
  "版本号已达到/超过上游某版本"为由跳过合并。
- 比较语义：semver/deb 中 `3.18.2-fork.1 < 3.18.3`，未来合并 `3.18.3` 基线后的构建
  版本号自然大于现有 fork 构建，安装升级路径正常。
