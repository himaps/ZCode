/**
 * ZCode 离线激活系统（fork-only，不对上游）。
 *
 * 与 pdfcraft 激活系统同构的 4–6 中文词方案，字节级语义：
 * - 机器码：SHA-256( machine_id.trim().toLowerCase() 的 UTF-8 ++ "\nzcode-activation-v1" )
 *   → 词数 n = 4 + digest[31] % 3（长度编码在 digest 里，两码天然同长）
 *   → 机器码第 i 词索引 = digest[i] & 63
 * - 激活码：SHA-256( KEY ++ "zcode" ++ 机器码索引字节序列 )（三段连拼，索引是原始字节非字符串）
 *   → 前 n 字节各 & 63 → 激活码词索引
 * - APP_ID 混入激活码哈希：同一机器码在 zcode / 其他软件里产生不同激活码
 * - KEY 内嵌于分发物，是混淆标记而非秘密（与 pdfcraft 同一定位）
 *
 * 该模块保持纯函数 + WebCrypto（Node 主进程与 Chromium 渲染层都可运行），
 * 平台相关的机器标识读取与许可证落盘在 desktop 主进程（desktopActivationIpc.ts）。
 */

export const ACTIVATION_APP_ID = "zcode";
export const ACTIVATION_DOMAIN_TAG = "\nzcode-activation-v1";
/** 混淆标记，非秘密；换 KEY 会使全部已发激活码失效。 */
export const ACTIVATION_KEY = "ZCode Kylin activation ledger key 1 (a marker, not a secret)";
/** 离线激活工具（packaging/offline-kit/zcode-activation-tool.html）与这里的常量必须逐字节一致。 */

/** 64 个激活词，按索引。给定顺序不可重排（重排会使所有已发码失效）。 */
export const ACTIVATION_WORDS: readonly string[] = [
  "富强", "民主", "文明", "和谐", "自由", "平等", "公正", "法治",
  "爱国", "敬业", "诚信", "友善", "昌隆", "安泰", "开化", "盛平",
  "兴邦", "民本", "崇文", "和睦", "自主", "均平", "公允", "遵法",
  "忠邦", "恪职", "立信", "亲睦", "弘道", "笃行", "崇信", "尚和",
  "守正", "公义", "平允", "依规", "严明", "循法", "明德", "持公",
  "普惠", "安民", "固本", "维新", "合众", "宽和", "明断", "守矩",
  "崇德", "厚善", "守诚", "敬责", "报国", "敦睦", "慎行", "守信",
  "向善", "弘毅", "克己", "怀仁", "崇礼", "持节", "谦恭", "淳良",
] as const;

export const ACTIVATION_SEPARATOR = "-";

export const ACTIVATION_IPC = {
  status: "zcode-activation:status",
  activate: "zcode-activation:activate",
} as const;

export type ActivationWordError = {
  ok: false;
  reason: "bad-word" | "wrong-length" | "mismatch" | "not-activated" | "invalid-input";
  detail?: string;
};

export type ActivationOk = { ok: true; indices: number[] };

export type ActivationVerifyResult = ActivationOk | ActivationWordError;

function activationWord(index: number): string {
  const normalized =
    ((index % ACTIVATION_WORDS.length) + ACTIVATION_WORDS.length) % ACTIVATION_WORDS.length;
  return ACTIVATION_WORDS[normalized] ?? "";
}

function activationIndex(word: string): number | null {
  const index = ACTIVATION_WORDS.indexOf(word);
  return index === -1 ? null : index;
}

/** 把用户输入的激活码文本解析为索引序列；分隔符为 -，容忍空白与空段。 */
export function parseActivationCodeText(text: string): ActivationVerifyResult {
  const words = text
    .split(ACTIVATION_SEPARATOR)
    .map((word) => word.trim())
    .filter((word) => word.length > 0);
  if (words.length === 0) {
    return { ok: false, reason: "invalid-input", detail: text.trim() };
  }
  const indices: number[] = [];
  for (const word of words) {
    const index = activationIndex(word);
    if (index === null) {
      return { ok: false, reason: "bad-word", detail: word };
    }
    indices.push(index);
  }
  return { ok: true, indices };
}

/** 索引序列 → 词串（- 连接）。 */
export function renderActivationCode(indices: readonly number[]): string {
  return indices.map((index) => activationWord(index)).join(ACTIVATION_SEPARATOR);
}

async function sha256Bytes(data: Uint8Array): Promise<Uint8Array> {
  // Uint8Array 在运行时即 WebCrypto 接受的 BufferSource；shared 的 tsconfig 无 DOM lib，
  // 用显式转换对齐 node 类型签名。
  const digest = await crypto.subtle.digest("SHA-256", data as unknown as ArrayBuffer);
  return new Uint8Array(digest);
}

function utf8(text: string): Uint8Array {
  return new TextEncoder().encode(text);
}

/** 机器码派生的公共摘要：规范化机器标识 + 域标签。 */
async function activationDigest(machineId: string): Promise<Uint8Array> {
  const normalized = machineId.trim().toLowerCase();
  const input = new Uint8Array(utf8(normalized).length + utf8(ACTIVATION_DOMAIN_TAG).length);
  input.set(utf8(normalized), 0);
  input.set(utf8(ACTIVATION_DOMAIN_TAG), utf8(normalized).length);
  return sha256Bytes(input);
}

/**
 * 机器码索引。n = 4 + digest[31] % 3 ∈ [4,6]；第 i 词索引 = digest[i] & 63。
 */
export async function deriveMachineCodeIndices(machineId: string): Promise<number[]> {
  const digest = await activationDigest(machineId);
  const lastByte = digest[digest.length - 1] ?? 0;
  const count = 4 + (lastByte % 3);
  const indices: number[] = [];
  for (let i = 0; i < count; i += 1) {
    indices.push((digest[i] ?? 0) & 63);
  }
  return indices;
}

/** 激活码索引：SHA-256(KEY ++ APP_ID ++ 机器码索引字节) 的前 n 字节各 & 63。 */
export async function deriveActivationIndices(machineIndices: readonly number[]): Promise<number[]> {
  const keyBytes = utf8(ACTIVATION_KEY);
  const appIdBytes = utf8(ACTIVATION_APP_ID);
  const machineBytes = new Uint8Array(machineIndices);
  const input = new Uint8Array(keyBytes.length + appIdBytes.length + machineBytes.length);
  input.set(keyBytes, 0);
  input.set(appIdBytes, keyBytes.length);
  input.set(machineBytes, keyBytes.length + appIdBytes.length);
  const response = await sha256Bytes(input);
  const indices: number[] = [];
  for (let i = 0; i < machineIndices.length; i += 1) {
    indices.push((response[i] ?? 0) & 63);
  }
  return indices;
}

export async function deriveMachineCodeWords(machineId: string): Promise<string[]> {
  const indices = await deriveMachineCodeIndices(machineId);
  return indices.map((index) => activationWord(index));
}

export async function deriveActivationWords(machineIndices: readonly number[]): Promise<string[]> {
  const indices = await deriveActivationIndices(machineIndices);
  return indices.map((index) => activationWord(index));
}

/** .license.md 的精确内容：首行软件标识，次行激活码（与 pdfcraft 格式同构，APP_ID 为 zcode）。 */
export function licenseFileContent(codeIndices: readonly number[]): string {
  return `# ${ACTIVATION_APP_ID}\n- 激活码: ${renderActivationCode(codeIndices)}\n`;
}

export type LicenseParseResult = ActivationOk | ActivationWordError;

/** 解析 .license.md：先验软件 ID 再解析激活码（顺序与 pdfcraft status_at 一致）。 */
export function parseLicenseFile(content: string): LicenseParseResult {
  const lines = content.split(/\r?\n/);
  const header = lines[0] ?? "";
  if (!header.startsWith("# ")) {
    return { ok: false, reason: "mismatch" };
  }
  if (header.slice(2).trim() !== ACTIVATION_APP_ID) {
    return { ok: false, reason: "mismatch" };
  }
  const codeLine = (lines[1] ?? "").trim();
  const normalized = codeLine.startsWith("- 激活码: ") ? codeLine.slice("- 激活码: ".length) : codeLine;
  if (normalized.length === 0) {
    return { ok: false, reason: "not-activated" };
  }
  return parseActivationCodeText(normalized);
}

/**
 * 校验用户输入的激活码是否匹配本机机器码。
 * 长度校验在前、逐索引比较在后（与 pdfcraft activate_at 一致）。
 */
export async function verifyActivationInput(
  machineId: string,
  typed: string,
): Promise<ActivationVerifyResult> {
  const typedParsed = parseActivationCodeText(typed);
  if (!typedParsed.ok) {
    return typedParsed;
  }
  const machineIndices = await deriveMachineCodeIndices(machineId);
  if (typedParsed.indices.length !== machineIndices.length) {
    return {
      ok: false,
      reason: "wrong-length",
      detail: `${machineIndices.length}`,
    };
  }
  const expectedIndices = await deriveActivationIndices(machineIndices);
  for (let i = 0; i < expectedIndices.length; i += 1) {
    if (typedParsed.indices[i] !== expectedIndices[i]) {
      return { ok: false, reason: "mismatch" };
    }
  }
  return { ok: true, indices: typedParsed.indices };
}
