"use client";

// OPEX C1 matrix of the latest actual month: the value-chain areas, their cost centers (driver, OPEX and unit
// OPEX against the budget, origin of the deviation computed by Trino) and, expanded on demand, the P x Q lines
// of every cost center (specific consumption per input). Rows expand with a real button (aria-expanded).
import { Fragment, useEffect, useState } from "react";

import { formatMonth, formatNumber, formatPercent } from "../format";
import { useI18n } from "../i18n";
import type { Matrix } from "../types";
import { PxqTable } from "./PxqTable";

const REFRESH_MS = 30000; // the lakehouse moves with CDC

export function MatrixC1({ selected, onAnalyze }: { selected?: string; onAnalyze: (rcntr: string) => void }) {
  const { language, t } = useI18n();
  const locale = t.locale;
  const m = t.matrix;
  const [matrix, setMatrix] = useState<Matrix>();
  const [open, setOpen] = useState<Set<string>>(() => new Set());

  useEffect(() => {
    let cancelled = false;
    const load = () =>
      fetch("/api/opex/matrix", { cache: "no-store" })
        .then((r) => (r.ok ? r.json() : Promise.reject(new Error(String(r.status)))))
        .then((body: Matrix) => {
          if (!cancelled) setMatrix(body);
        })
        .catch(() => undefined);
    load();
    const id = setInterval(load, REFRESH_MS);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, []);

  const toggle = (rcntr: string) =>
    setOpen((current) => {
      const next = new Set(current);
      if (next.has(rcntr)) next.delete(rcntr);
      else next.add(rcntr);
      return next;
    });

  return (
    <section data-testid="matrix" className="mt-4 rounded-xl border border-slate-800 bg-slate-900/60 p-5">
      <h2 className="text-sm font-semibold uppercase tracking-wide text-sky-400">{m.title}</h2>
      <p className="mt-0.5 text-xs text-slate-400">
        {matrix?.period ? m.subtitle(formatMonth(matrix.period, locale), matrix.budget_category) : t.controls.loading}
      </p>
      {matrix && !matrix.areas.length ? <p className="mt-3 text-xs text-slate-500">{m.empty}</p> : null}
      {matrix?.areas.length ? (
        <div className="mt-3 overflow-x-auto">
          <table className="w-full min-w-[900px] text-right text-xs tabular-nums">
            <thead className="text-slate-400">
              <tr className="border-b border-slate-800">
                <th className="px-2 py-1.5 text-left font-medium">{m.costCenter}</th>
                <th className="px-2 py-1.5 font-medium">{m.driver}</th>
                <th className="px-2 py-1.5 font-medium">{m.opex}</th>
                <th className="px-2 py-1.5 font-medium">{m.budget}</th>
                <th className="px-2 py-1.5 font-medium">{m.deviation}</th>
                <th className="px-2 py-1.5 font-medium">{m.unitCost}</th>
                <th className="px-2 py-1.5 text-left font-medium">{m.origin}</th>
                <th className="px-2 py-1.5" />
              </tr>
            </thead>
            {matrix.areas.map((area) => (
              <tbody key={area.area} className="text-slate-200">
                <tr>
                  <th colSpan={8} className="bg-slate-950/60 px-2 py-1.5 text-left text-[11px] font-semibold uppercase tracking-wide text-slate-400">
                    {area.texts[language]}
                  </th>
                </tr>
                {area.cost_centers.map((center) => {
                  const expanded = open.has(center.rcntr);
                  const decimals = center.driver.decimals;
                  return (
                    <Fragment key={center.rcntr}>
                      <tr data-testid={`matrix-row-${center.rcntr}`}
                          className={`border-b border-slate-900 ${center.rcntr === selected ? "bg-sky-950/30" : ""}`}>
                        <td className="px-2 py-1.5 text-left">
                          <button
                            type="button"
                            data-testid={`matrix-toggle-${center.rcntr}`}
                            aria-expanded={expanded}
                            aria-controls={`pxq-${center.rcntr}`}
                            aria-label={m.expand(center.rcntr)}
                            onClick={() => toggle(center.rcntr)}
                            className="mr-1.5 inline-flex h-5 w-5 items-center justify-center rounded border border-slate-700 text-slate-300 hover:border-sky-500"
                          >
                            {expanded ? "▾" : "▸"}
                          </button>
                          <span className="font-mono text-slate-100">{center.rcntr}</span>
                          <span className="text-slate-400"> · {center.texts[language]}</span>
                        </td>
                        <td className="whitespace-nowrap px-2 py-1.5">
                          {formatNumber(center.driver.actual, locale)} / {formatNumber(center.driver.budget, locale)}
                          <span className="text-slate-500"> {center.driver.symbol}</span>
                          <div className="text-[11px] text-slate-500">{center.driver.stagr} · {formatPercent(center.driver.delta_pct, locale)}</div>
                        </td>
                        <td className="whitespace-nowrap px-2 py-1.5">{formatNumber(center.opex.actual, locale)}</td>
                        <td className="whitespace-nowrap px-2 py-1.5">{formatNumber(center.opex.budget, locale)}</td>
                        <td className={`whitespace-nowrap px-2 py-1.5 ${(center.opex.variance_pct ?? 0) > 0 ? "text-red-400" : "text-emerald-400"}`}>
                          {formatPercent(center.opex.variance_pct, locale)}
                        </td>
                        <td className="whitespace-nowrap px-2 py-1.5" data-testid="matrix-unit-cost">
                          {center.unit_cost.actual === null ? m.notComputable : formatNumber(center.unit_cost.actual, locale, decimals)}
                          {" / "}{formatNumber(center.unit_cost.budget, locale, decimals)}
                          <span className="text-slate-500"> USD/{center.driver.symbol}</span>
                        </td>
                        <td className="px-2 py-1.5 text-left" data-testid="matrix-origin">
                          {center.origin ? (
                            <>
                              <span className="font-mono text-slate-100">{center.origin.racct}</span>
                              <span className="text-slate-400"> · {m.effectNames[center.origin.effect]}</span>
                              <span className="text-red-400"> {formatNumber(center.origin.amount, locale, 0, true)}</span>
                            </>
                          ) : (
                            <span className="text-slate-500">{m.noOrigin}</span>
                          )}
                        </td>
                        <td className="whitespace-nowrap px-2 py-1.5">
                          <button
                            type="button"
                            onClick={() => onAnalyze(center.rcntr)}
                            aria-label={m.analyzeLabel(center.rcntr)}
                            className="rounded-md border border-slate-700 px-2 py-0.5 text-[11px] text-slate-300 hover:border-sky-500"
                          >
                            {m.analyze}
                          </button>
                        </td>
                      </tr>
                      {expanded ? (
                        <tr id={`pxq-${center.rcntr}`}>
                          <td colSpan={8} className="bg-slate-950/40 px-2 py-2">
                            <PxqTable lines={center.lines} driver={center.driver} origin={center.origin}
                                      testId={`matrix-lines-${center.rcntr}`} />
                          </td>
                        </tr>
                      ) : null}
                    </Fragment>
                  );
                })}
              </tbody>
            ))}
          </table>
        </div>
      ) : null}
    </section>
  );
}
