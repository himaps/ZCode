/* eslint-disable max-lines -- 门禁屏的状态机、验证交互与版式同属一个组件，拆开会割裂激活语义 */
// ZCode 离线激活门禁（fork-only）：未激活时整屏替换主 UI。
// 平台未实现 activation（web / 手机远控）时直接放行——门禁只属于桌面交付形态。
// 平台操作经 IPlatformService 注入（遵守“UI 不直接调用 window.zcode”的边界）。
import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import { CheckCircle2Icon, CopyIcon, Loader2Icon, ShieldCheckIcon } from "lucide-react";
import { Button } from "@/components/ui/button.js";
import { Input } from "@/components/ui/input.js";
import {
  parseActivationCodeText,
  type ActivationStatusResult,
  type IPlatformService,
} from "@zcode/shared";

type GatePhase =
  | { kind: "checking" }
  | { kind: "ok" }
  | { kind: "missing-bridge" }
  | { kind: "machine-id-error"; detail: string }
  | { kind: "gated"; machineCode: string };

function errorText(reason: string | undefined, detail: string | undefined): string {
  switch (reason) {
    case "bad-word":
      return `不是有效的激活词：${detail ?? "?"}`;
    case "wrong-length":
      return "激活码应为 4 个词语，请核对后重新输入";
    case "mismatch":
      return "激活码与本机机器码不匹配";
    case "invalid-input":
      return "请输入激活码";
    case "write-failed":
      return `激活码正确，但写入许可证文件失败：${detail ?? ""}`;
    case "machine-id-unavailable":
      return `无法读取机器标识，无法激活：${detail ?? ""}`;
    default:
      return "激活失败，请重试";
  }
}

export function ActivationGate({
  platform,
  children,
}: {
  platform: IPlatformService;
  children: ReactNode;
}) {
  const [phase, setPhase] = useState<GatePhase>({ kind: "checking" });
  const [typed, setTyped] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [copied, setCopied] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    let cancelled = false;
    // 平台未实现 activation（web / 手机远控）→ 非桌面交付形态，放行
    const status = platform.activation?.status.bind(platform.activation);
    if (!status) {
      setPhase({ kind: "missing-bridge" });
      return;
    }
    status()
      .then((state: ActivationStatusResult) => {
        if (cancelled) return;
        if (state.activated) {
          setPhase({ kind: "ok" });
        } else if (state.machineIdError || !state.machineCode) {
          setPhase({
            kind: "machine-id-error",
            detail: state.machineIdError ?? "unknown",
          });
        } else {
          setPhase({ kind: "gated", machineCode: state.machineCode });
        }
      })
      .catch(() => {
        if (!cancelled) setPhase({ kind: "missing-bridge" });
      });
    return () => {
      cancelled = true;
    };
  }, [platform]);

  const machineWords = phase.kind === "gated" ? phase.machineCode.split("-") : [];

  const submit = useCallback(async () => {
    const activate = platform.activation?.activate.bind(platform.activation);
    if (!activate || phase.kind !== "gated") return;
    // 客户端先做轻校验，给出即时反馈；权威校验在主进程。
    const parsed = parseActivationCodeText(typed);
    if (!parsed.ok) {
      setError(errorText(parsed.reason, parsed.detail));
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      const result = await activate(typed);
      if (result.ok) {
        setPhase({ kind: "ok" });
      } else {
        setError(errorText(result.reason, result.detail));
        inputRef.current?.select();
      }
    } catch {
      setError("激活失败，请重试");
    } finally {
      setSubmitting(false);
    }
  }, [platform, phase, typed]);

  const copyMachineCode = useCallback(() => {
    if (phase.kind !== "gated") return;
    void navigator.clipboard.writeText(phase.machineCode);
    setCopied(true);
    setTimeout(() => setCopied(false), 1600);
  }, [phase]);

  if (phase.kind === "checking") {
    return (
      <div className="flex h-screen w-screen items-center justify-center bg-background">
        <Loader2Icon className="size-6 animate-spin text-muted-foreground" />
      </div>
    );
  }

  if (phase.kind === "ok" || phase.kind === "missing-bridge") {
    return <>{children}</>;
  }

  if (phase.kind === "machine-id-error") {
    return (
      <div className="flex h-screen w-screen items-center justify-center bg-background p-6">
        <div className="max-w-md rounded-xl border border-destructive/30 bg-card p-6 text-card-foreground shadow-lg">
          <div className="flex items-center gap-2 text-destructive">
            <ShieldCheckIcon className="size-5" />
            <p className="font-semibold">无法读取机器标识</p>
          </div>
          <p className="mt-3 text-sm text-muted-foreground">
            激活需要读取本机硬件标识，但读取失败。请把以下信息反馈给维护者：
          </p>
          <p className="mt-2 rounded-md bg-muted p-2 font-mono text-xs break-all">{phase.detail}</p>
        </div>
      </div>
    );
  }

  // gated：全屏激活面板
  return (
    <div className="relative flex h-screen w-screen items-center justify-center overflow-hidden bg-background p-6">
      {/* 背景装饰：柔和径向渐变，呼应登录页观感 */}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0 bg-[radial-gradient(60%_60%_at_50%_0%,hsl(var(--primary)/0.10),transparent_70%)]"
      />
      <div className="relative z-10 w-full max-w-lg">
        <div className="rounded-2xl border bg-card p-8 text-card-foreground shadow-xl">
          <div className="flex flex-col items-center text-center">
            <div className="flex size-12 items-center justify-center rounded-xl bg-primary/10">
              <ShieldCheckIcon className="size-6 text-primary" />
            </div>
            <h1 className="mt-4 text-xl font-semibold tracking-tight">激活 ZCode</h1>
            <p className="mt-1.5 text-sm text-muted-foreground">
              离线激活 · 免费使用 · 激活码与本机绑定
            </p>
          </div>

          <div className="mt-7">
            <div className="flex items-center justify-between">
              <p className="text-sm font-medium">本机机器码</p>
              <button
                type="button"
                onClick={copyMachineCode}
                className="inline-flex items-center gap-1 rounded-md px-2 py-1 text-xs text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
              >
                {copied ? <CheckCircle2Icon className="size-3.5" /> : <CopyIcon className="size-3.5" />}
                {copied ? "已复制" : "复制"}
              </button>
            </div>
            <div className="mt-2 flex flex-wrap justify-center gap-2 rounded-xl border border-primary/25 bg-primary/5 px-4 py-4">
              {machineWords.map((word, index) => (
                <span
                  key={`${word}-${index}`}
                  className="rounded-lg border border-primary/20 bg-background px-3 py-1.5 text-lg font-semibold tracking-wide text-foreground"
                >
                  {word}
                </span>
              ))}
            </div>
            <p className="mt-2 text-center text-xs text-muted-foreground">
              把机器码发给维护者，换取对应的激活码
            </p>
          </div>

          <div className="mt-6">
            <p className="text-sm font-medium">输入激活码</p>
            <Input
              ref={inputRef}
              value={typed}
              onChange={(event) => setTyped(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === "Enter" && !submitting) void submit();
              }}
              placeholder="4 个词语，用 - 连接"
              className="mt-2 h-11 border-primary/30 text-base tracking-wide"
              autoComplete="off"
              spellCheck={false}
              autoFocus
            />
            {error ? <p className="mt-2 text-sm text-destructive">{error}</p> : null}
            <Button
              type="button"
              className="mt-4 h-11 w-full text-base font-medium"
              disabled={submitting || typed.trim().length === 0}
              onClick={() => void submit()}
            >
              {submitting ? <Loader2Icon className="size-4 animate-spin" /> : null}
              激活
            </Button>
          </div>

          <p className="mt-6 border-t pt-4 text-center text-xs text-muted-foreground">
            激活码由维护者通过离线激活工具生成，与机器码一一对应
          </p>
        </div>
      </div>
    </div>
  );
}
