"use client";

import { useI18n } from "../i18n";
import type { AskResult } from "../types";

// Every label and formatted value comes from the language context (ES / EN / PT).
export function AnswerMeta({ result }: { result: AskResult }) {
  const { t } = useI18n();
  const seconds = Object.values(result.timings_ms).reduce((total, ms) => total + ms, 0) / 1000;
  const usedLocalContingency = result.engine === "nim" && result.model_used.startsWith("ollama/");
  const figures = result.figures_check;
  return (
    <div data-testid="answer-meta" className="mt-3 space-y-1.5 border-t border-slate-800 pt-3 text-xs text-slate-500">
      <div data-testid="figures-check">
        {t.meta.figures}:{" "}
        {figures.ungrounded.length ? (
          <span className="text-amber-300">⚠ {t.meta.figuresWarn(figures.grounded, figures.checked, figures.ungrounded.join(", "))}</span>
        ) : (
          <span className="text-emerald-300">{t.meta.figuresOk(figures.checked)}</span>
        )}
      </div>
      <div>
        {t.meta.language}: {t.languageNames[result.language] ?? result.language}
        {result.language_check.status === "corrected" ? ` (${t.meta.corrected})` : ""}
      </div>
      <div>
        {t.meta.engine}: {result.engine === "nim" ? t.engine.nim : t.engine.ollama} · {t.meta.model}:{" "}
        <span className="font-mono">{result.model_used.replace(/^nim\//, "")}</span>
        {usedLocalContingency ? <span className="text-amber-300"> ({t.meta.fallback})</span> : null}
      </div>
      <div>
        {t.meta.time}: {t.meta.seconds(new Intl.NumberFormat(t.locale, { maximumFractionDigits: 1 }).format(seconds))}
        {result.trace_url ? (
          <>
            {" · "}
            <a href={result.trace_url} target="_blank" rel="noreferrer" className="text-sky-400 hover:underline">
              {t.meta.trace} ↗
            </a>
          </>
        ) : null}
      </div>
    </div>
  );
}
