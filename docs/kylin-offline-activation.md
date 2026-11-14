# ZCode 离线激活系统（fork-only）

fork-only 功能，不对上游。激活门禁在启动后整屏拦截主 UI；算法与 pdfcraft 激活系统同构（中文词；fork 差异：固定 4 词，pdfcraft 为 4–6 可变长度），应用标识换成 zcode。

## 设计

- **机器码**：`SHA-256(machine_id.trim().toLowerCase() ++ "\nzcode-activation-v1")`，词数固定 4（fork 差异：pdfcraft 为 `4 + digest[31] % 3`），第 i 词索引 = `digest[i] & 63`
- **激活码**：`SHA-256(KEY ++ "zcode" ++ 机器码索引字节)`，前 n 字节各 `& 63`。KEY = `ZCode Kylin activation ledger key 1 (a marker, not a secret)`（混淆标记，非秘密）
- **词表**：64 个双字中文词（与 pdfcraft 同表），顺序不可重排
- **隔离**：APP_ID (`"zcode"`) 混入激活码哈希——同一机器码在其他软件中的激活码不同
- 机器标识：Windows `HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid`；Linux `product_uuid → board_serial → /etc/machine-id → dbus machine-id` 按序第一个非空；macOS `IOPlatformUUID`

## 状态所有者与事件顺序

```
启动 → main 读机器标识 + 派生机器码
     → 读 <数据根>/.license.md（首行 "# zcode"、次行 "- 激活码: 词-词-…"）
     → IPC status → 渲染层 ActivationGate
        ├─ 已激活 → 渲染主 UI
        └─ 未激活 → 整屏激活面板（机器码 chips + 激活码输入框）
             └─ 输入激活码 → IPC activate → 主进程验证（长度→逐索引）→ 写 .license.md → 放行
```

- dpkg 数据库之外，`.license.md` 是激活状态的唯一事实；文件缺失 = 未激活，验证每轮实时进行（无独立状态文件）
- 许可证路径：`~/.zcode/.license.md`（与其他应用数据聚在一起）。早期版本在 HOME 根
  （`getDataBaseDir()` 直下），status 检查时对已激活机器做一次性迁移（旧文件解析正确
  即写入新路径并删除），activate 写入后也会清理旧位置残留
- 退出按钮：激活面板提供【退出应用】，走专用 `zcode-activation:quit` → `app.quit()`
  （不经 close-to-tray/确认退出，激活屏上退出语义确定）

## 代码位置

| 文件 | 职责 |
| --- | --- |
| `packages/shared/src/activation.ts` | 纯算法（词表/派生/解析/校验/license 内容），WebCrypto，主进程与渲染层共用 |
| `packages/desktop/src/main/desktopActivationIpc.ts` | 机器标识读取、license 落盘、`zcode-activation:status/activate/quit` IPC |
| `packages/desktop/src/preload/index.ts` | `window.zcodeActivation.{status,activate}` |
| `packages/ui/src/activation/ActivationGate.tsx` | 启动门禁屏（渲染层；桥接缺失即非桌面环境，放行） |
| `packaging/offline-kit/zcode-activation-tool.html` | 维护者侧离线激活工具（纯静态，WebCrypto） |

## 验收（已实证）

- 算法对拍：TS 实现借 pdfcraft 常量复算 pdfcraft 官方测试向量逐字节一致（固定 4 词后 pdfcraft 的 `kylin-v20-desktop` 向量仍精确匹配，其机器码本就是 4 词）；长度不变式 200/200 恒为 4 词
- HTML 工具与 activation.ts 常量一致性断言 + zcode 金标向量 4/4（`test-machine-001`、`kylin-v20-desktop`、`linux-abc123`、`zcode-dev-01`）
- 错误路径：非法词 / 长度不符 / 不匹配 / 写入失败均有明确中文文案

## 金标向量（固定 4 词方案，改动算法后必须重算并对拍）

| machine_id | 机器码 | 激活码 |
| --- | --- | --- |
| `test-machine-001` | 明断-崇德-崇文-弘毅 | 报国-持公-平等-友善 |
| `kylin-v20-desktop` | 报国-友善-自由-恪职 | 崇信-崇信-遵法-均平 |
| `linux-abc123` | 崇信-崇德-富强-向善 | 诚信-固本-弘道-恪职 |
| `zcode-dev-01` | 慎行-和睦-宽和-守信 | 文明-谦恭-爱国-尚和 |

## 已知限制

- KEY 随包分发，门禁是防误用标记而非抗逆向机制（与 pdfcraft 定位一致）
- 门禁在渲染层：桌面交付形态内有效；绕过需改包，不在威胁模型内
