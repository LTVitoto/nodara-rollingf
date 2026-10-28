"use client";

// Evidence behind an answer: the deterministic P x Q calculation of Trino for the analyzed month (every
// account against the budget, with the origin of the deviation) and the operational logs retrieved from
// pgvector with their mandatory metadata (Año, Mes, RCNTR) and the cost centers each log covers (Alcance).
import { formatMonth, formatNumber } from "../format";
import { useI18n } from "../i18n";
import type { Analysis, Source } from "../types";
import { PxqTable } from "./PxqTable";

export function AnalysisTable({ analysis }: { analysis: Analysis }) {
  const { t } = useI18n();
  const origin = analysis.origins[0] ?? null;
  return (
    <div data-testid="analysis-table">
      <h3 className="text-xs font-semibold uppercase tracking-wide text-sky-400">{t.analysis.title}</h3>
      <p className="mt-1 text-[11px] text-slate-400">
        {analysis.rcntr} · {formatMonth(analysis.period, t.locale)} · {t.analysis.origin}:{" "}
        {origin ? (
          <span data-testid="analysis-origin" className="text-slate-200">
            {origin.racct} · {t.matrix.effectNames[origin.effect]} {formatNumber(origin.amount, t.locale, 0, true)}
          </span>
        ) : (
          t.matrix.noOrigin
        )}
      </p>
      <div className="mt-2">
        <PxqTable lines={analysis.lines} driver={analysis.driver} origin={origin} testId="analysis-pxq" />
      </div>
    </div>
  );
}

export function Sources({ sources, filter }: { sources: Source[]; filter: Record<string, number | string> }) {
  const { t } = useI18n();
  return (
    <div>
      <h3 data-testid="sources-title" className="text-xs font-semibold uppercase tracking-wide text-sky-400">
        {t.sources.title}
      </h3>
      <div className="mt-1 text-[11px] text-slate-500">
        {t.sources.filter}: {t.sources.year} {filter["Año"]} · {t.sources.month} {filter["Mes"]} · RCNTR {filter["RCNTR"]}
      </div>
      {sources.length ? (
        <ul className="mt-2 space-y-2 text-xs">
          {sources.map((source) => (
            <li key={`${source.doc_id}-${source.section}`} className="rounded-lg border border-slate-800 p-2">
              <div className="font-semibold text-slate-200">{source.doc_id} §{source.section}</div>
              <div className="text-slate-400">{source.title} · {source.author_role}</div>
              <div className="mt-1 flex flex-wrap gap-1.5">
                <span className="rounded bg-slate-800 px-1.5 py-0.5 text-slate-300">{t.sources.year} {source.metadata["Año"]}</span>
                <span className="rounded bg-slate-800 px-1.5 py-0.5 text-slate-300">{t.sources.month} {source.metadata["Mes"]}</span>
                <span className="rounded bg-slate-800 px-1.5 py-0.5 font-mono text-slate-300">RCNTR {source.metadata["RCNTR"]}</span>
                {Array.isArray(source.metadata["Alcance"]) && source.metadata["Alcance"].length > 1 ? (
                  <span data-testid="source-scope" className="rounded bg-slate-800 px-1.5 py-0.5 font-mono text-slate-300">
                    {t.sources.scope} {source.metadata["Alcance"].join(" · ")}
                  </span>
                ) : null}
                <span className="px-1 py-0.5 text-slate-500">{t.sources.similarity} {formatNumber(source.similarity, t.locale, 2)}</span>
              </div>
              <div className="mt-1 font-mono text-[11px] text-slate-600">{source.source_uri}</div>
            </li>
          ))}
        </ul>
      ) : (
        <p className="mt-2 text-xs text-slate-500">{t.sources.empty}</p>
      )}
    </div>
  );
}
