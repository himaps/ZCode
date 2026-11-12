/* eslint-disable max-lines -- 激活门禁的机器标识读取、许可证落盘与 IPC 注册同属一个进程会话 */
// ZCode 离线激活（fork-only）：主进程侧机器标识读取、许可证验证与落盘、IPC 注册。
// 算法与词表在 @zcode/shared 的 activation 模块（与离线 HTML 工具逐字节一致）。
import { execFile } from "node:child_process";
import { join } from "node:path";
import { promisify } from "node:util";
import { ipcMain } from "electron";
import {
  ACTIVATION_IPC,
  deriveMachineCodeIndices,
  licenseFileContent,
  parseLicenseFile,
  renderActivationCode,
  verifyActivationInput,
} from "@zcode/shared";
import { getDataBaseDir } from "@zcode/services/node";
import { readFileSync, writeFileSync } from "node:fs";

const execFileAsync = promisify(execFile);

/**
 * 读取本机硬件标识（与 pdfcraft 激活系统同源的平台顺序）：
 * - Windows: HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid
 * - Linux: /sys/class/dmi/id/product_uuid → board_serial → /etc/machine-id → dbus machine-id
 * - macOS: IOPlatformUUID
 * 返回前统一 trim().toLowerCase()（哈希输入的规范化在 activation 模块再做一次，等价）。
 */
async function readMachineId(): Promise<string> {
  const platform = process.platform;
  if (platform === "win32") {
    const { stdout } = await execFileAsync("reg", [
      "query",
      "HKLM\\SOFTWARE\\Microsoft\\Cryptography",
      "/v",
      "MachineGuid",
    ]);
    // 输出行形如 "    MachineGuid    REG_SZ    xxxxxxxx-...."
    const match = stdout.match(/MachineGuid\s+REG_SZ\s+(\S+)/);
    if (match?.[1]) {
      return match[1];
    }
    throw new Error("MachineGuid not found in registry");
  }
  if (platform === "darwin") {
    const { stdout } = await execFileAsync("ioreg", ["-rd1", "-c", "IOPlatformExpertDevice"]);
    const match = stdout.match(/"IOPlatformUUID"\s*=\s*"([^"]+)"/);
    if (match?.[1]) {
      return match[1];
    }
    throw new Error("IOPlatformUUID not found");
  }
  // linux：按序第一个非空文件
  const files = [
    "/sys/class/dmi/id/product_uuid",
    "/sys/class/dmi/id/board_serial",
    "/etc/machine-id",
    "/var/lib/dbus/machine-id",
  ];
  for (const file of files) {
    try {
      const content = readFileSync(file, "utf8");
      if (content.trim().length > 0) {
        return content;
      }
    } catch {
      // 尝试下一个候选
    }
  }
  throw new Error(`no machine identifier found (${files.join(", ")})`);
}

/** 许可证文件路径：用户数据根目录下的 .license.md（离线机用户可写）。 */
function licensePath(): string {
  return join(getDataBaseDir(), ".license.md");
}

type ActivationStatusPayload = {
  activated: boolean;
  /** 机器码词串（- 连接）；机器标识读取失败时为 null。 */
  machineCode: string | null;
  machineIdError: string | null;
};

async function buildStatusPayload(): Promise<ActivationStatusPayload> {
  let machineId: string;
  try {
    machineId = await readMachineId();
  } catch (error) {
    return {
      activated: false,
      machineCode: null,
      machineIdError: error instanceof Error ? error.message : String(error),
    };
  }
  const indices = await deriveMachineCodeIndices(machineId);
  const machineCode = renderActivationCode(indices);
  try {
    const parsed = parseLicenseFile(readFileSync(licensePath(), "utf8"));
    if (parsed.ok) {
      const machineLen = indices.length;
      // 存储码长度与本机机器码同长且逐索引相等才算激活
      const verified = await verifyActivationInput(machineId, renderActivationCode(parsed.indices));
      if (verified.ok && parsed.indices.length === machineLen) {
        return { activated: true, machineCode, machineIdError: null };
      }
    }
  } catch {
    // 文件不存在/不可读 = 未激活
  }
  return { activated: false, machineCode, machineIdError: null };
}

export function registerDesktopActivationIpc(): void {
  ipcMain.handle(ACTIVATION_IPC.status, async (): Promise<ActivationStatusPayload> => {
    return buildStatusPayload();
  });

  ipcMain.handle(
    ACTIVATION_IPC.activate,
    async (_event, typed: unknown): Promise<{ ok: boolean; reason?: string; detail?: string }> => {
      if (typeof typed !== "string" || typed.trim().length === 0) {
        return { ok: false, reason: "invalid-input" };
      }
      let machineId: string;
      try {
        machineId = await readMachineId();
      } catch (error) {
        return {
          ok: false,
          reason: "machine-id-unavailable",
          detail: error instanceof Error ? error.message : String(error),
        };
      }
      const verified = await verifyActivationInput(machineId, typed);
      if (!verified.ok) {
        return { ok: false, reason: verified.reason, detail: verified.detail };
      }
      try {
        writeFileSync(licensePath(), licenseFileContent(verified.indices), "utf8");
      } catch (error) {
        return {
          ok: false,
          reason: "write-failed",
          detail: error instanceof Error ? error.message : String(error),
        };
      }
      return { ok: true };
    },
  );
}
