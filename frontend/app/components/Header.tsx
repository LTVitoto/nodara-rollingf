"use client";

import { useI18n } from "../i18n";
import { LanguageSwitcher } from "./LanguageSwitcher";

export type Probe = { ok: boolean; error?: string } & Record<string, unknown>;
export type Status = { knowledge_base: Probe; s4hana_live: Probe; lakehouse_cdc: Probe; llm: Probe };

type NimStatus = { configured?: boolean; reachable?: boolean; listed?: boolean };
type OllamaStatus = { ok?: boolean; chat_ready?: boolean; embed_ready?: boolean };

export const nimReady = (llm?: Probe) => {
  const nim = llm?.nim as NimStatus | undefined;
  return Boolean(nim?.configured && nim.reachable && nim.listed);
};
export const nimConfigured = (llm?: Probe) => Boolean((llm?.nim as NimStatus | undefined)?.configured);
export const ollamaReady = (llm?: Probe) => {
  const ollama = llm?.ollama as OllamaStatus | undefined;
  return Boolean(ollama?.ok && ollama.chat_ready && ollama.embed_ready);
};

function Pill({ id, label, probe, detail }: { id: string; label: string; probe?: Probe; detail: (p: Probe) => string }) {
  const { t } = useI18n();
  const tone = !probe
    ? "border-slate-700 text-slate-400"
    : probe.ok
      ? "border-emerald-700 text-emerald-300"
      : "border-amber-700 text-amber-300";
  return (
    <div className={`rounded-lg border px-3 py-2 text-xs ${tone}`}>
      <div data-testid={`status-${id}`} className="font-semibold uppercase tracking-wide">{label}</div>
      <div className="mt-0.5 text-slate-300">{!probe ? t.status.checking : probe.ok ? detail(probe) : t.status.unavailable}</div>
    </div>
  );
}

export function Header({ status }: { status?: Status }) {
  const { t } = useI18n();
  return (
    <header className="flex flex-col gap-4">
      <div className="flex items-start justify-between gap-4">
        <div>
          <p className="text-xs font-semibold uppercase tracking-[0.2em] text-sky-400">{t.header.brand}</p>
          <h1 className="text-2xl font-bold">{t.header.title}</h1>
          <p className="text-sm text-slate-400">{t.header.subtitle}</p>
        </div>
        <LanguageSwitcher />
      </div>
      <div className="grid grid-cols-2 gap-2 md:grid-cols-4">
        <Pill
          id="s4"
          label={t.status.s4}
          probe={status?.s4hana_live}
          detail={(p) => t.status.s4Detail(p.acdoca_rows, p.acdocp_rows, p.finsskf_rows)}
        />
        <Pill id="cdc" label={t.status.cdc} probe={status?.lakehouse_cdc} detail={(p) => t.status.cdcDetail(p.events, p.last_lag_ms)} />
        <Pill id="logs" label={t.status.logs} probe={status?.knowledge_base} detail={(p) => t.status.logsDetail(p.embedded, p.chunks)} />
        <Pill id="llm" label={t.status.llm} probe={status?.llm} detail={(p) => t.status.enginesDetail(nimReady(p), ollamaReady(p))} />
      </div>
    </header>
  );
}
