"use client";

// Evidence behind an answer: the deterministic variance computed by Trino and the maintenance logs
// retrieved from pgvector with their mandatory metadata (Año, Mes, RCNTR).
import { formatMonth, formatNumber, formatPercent } from "../format";
import { useI18n } from "../i18n";
import type { Analysis, Metric, Source } from "../types";

const DIGITS: Record<string, number> = { USD_H: 2, USD_T: 4 };

function Row({ label, metric, digits }: { label: string; metric: Metric; digits: number }) {
  const { t } = useI18n();
  const n = (value: number | null) => formatNumber(value, t.locale, digits);
  return (
    <tr className="border-b border-slate-900">
      <td className="py-1 pr-3 text-left text-slate-300">{label}</td>
      <td className="py-1 pr-3 font-semibold text-slate-50">{n(metric.current)}</td>
      <td className="py-1 pr-3">{n(metric.previous)}</td>
      <td className="py-1 pr-3">{formatPercent(metric.delta_previous_pct, t.locale)}</td>
      <td className="py-1 pr-3">{n(metric.baseline)}</td>
      <td className="py-1 pr-3">{formatPercent(metric.delta_baseline_pct, t.locale)}</td>
      <td className="py-1">{metric.share_pct === null ? "" : `${formatNumber(metric.share_pct, t.locale, 1)} %`}</td>
    </tr>
  );
}

export function AnalysisTable({ analysis }: { analysis: Analysis }) {
  const { language, t } = useI18n();
  return (
    <div data-testid="analysis-table" className="overflow-x-auto">
      <h3 className="text-xs font-semibold uppercase tracking-wide text-sky-400">{t.analysis.title}</h3>
      <table className="mt-2 w-full text-right text-xs tabular-nums text-slate-200">
        <thead className="text-slate-400">
          <tr className="border-b border-slate-800">
            <th className="py-1 pr-3 text-left font-medium">{t.analysis.metric}</th>
            <th className="py-1 pr-3 font-medium">{formatMonth(analysis.period, t.locale)}</th>
            <th className="py-1 pr-3 font-medium">{t.analysis.previous}</th>
            <th className="py-1 pr-3 font-medium">Δ</th>
            <th className="py-1 pr-3 font-medium">{t.analysis.baseline}</th>
            <th className="py-1 pr-3 font-medium">Δ</th>
            <th className="py-1 font-medium">{t.analysis.share}</th>
          </tr>
        </thead>
        <tbody>
          {Object.entries(analysis.totals).map(([key, metric]) => (
            <Row key={key} label={t.analysis.metrics[key] ?? key} metric={metric!} digits={DIGITS[key] ?? 0} />
          ))}
          {analysis.accounts.map((account) => (
            <Row key={account.racct} label={`${account.racct} ${account.texts[language]}`} metric={account} digits={0} />
          ))}
        </tbody>
      </table>
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
