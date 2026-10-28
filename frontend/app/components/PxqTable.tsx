"use client";

// P x Q lines of one cost center against the budget (BUDG): specific consumption (quantity per driver
// unit), unit price, cost and the price / efficiency / volume / spending effects computed by Trino.
// Effects always show their sign; the tone (red over budget, green under) only reinforces it, and the
// effect that originates the deviation is marked in bold with an outline.
import { formatNumber, formatPercent, formatPrice, formatSignificant } from "../format";
import { useI18n } from "../i18n";
import type { DriverValues, Effect, Origin, PxqLine } from "../types";

const EFFECTS: Effect[] = ["price", "efficiency", "volume", "spending"];

function tone(value: number | null): string {
  if (value === null) return "text-slate-600";
  return value > 0.5 ? "text-red-400" : value < -0.5 ? "text-emerald-400" : "text-slate-500";
}

export function PxqTable({ lines, driver, origin, testId }: {
  lines: PxqLine[];
  driver: DriverValues;
  origin: Origin | null;
  testId: string;
}) {
  const { language, t } = useI18n();
  const locale = t.locale;
  const m = t.matrix;
  const idle = driver.actual === 0;
  return (
    <div className="overflow-x-auto">
      <table data-testid={testId} className="w-full min-w-[960px] text-right text-xs tabular-nums">
        <thead className="text-slate-400">
          <tr className="border-b border-slate-800">
            <th className="px-2 py-1.5 text-left font-medium">{m.input}</th>
            <th className="px-2 py-1.5 text-left font-medium">{m.unit}</th>
            <th className="px-2 py-1.5 font-medium">{m.consumption}</th>
            <th className="px-2 py-1.5 font-medium">Δ</th>
            <th className="px-2 py-1.5 font-medium">{m.price}</th>
            <th className="px-2 py-1.5 font-medium">Δ</th>
            <th className="px-2 py-1.5 font-medium">{m.cost}</th>
            {EFFECTS.map((effect) => (
              <th key={effect} className="px-2 py-1.5 font-medium">{m.effects[effect]}</th>
            ))}
          </tr>
        </thead>
        <tbody className="text-slate-200">
          {lines.map((line) => (
            <tr key={line.racct} data-testid="pxq-line" data-racct={line.racct} className="border-b border-slate-900 align-top">
              <td className="px-2 py-1 text-left">
                <div className="font-mono text-slate-100">{line.racct}</div>
                <div className="text-[11px] text-slate-500">{line.texts[language]} · {m.behavior[line.behavior] ?? line.behavior}</div>
              </td>
              <td className="px-2 py-1 text-left">{line.ruom ? line.symbol : m.amountOnly}</td>
              <td className="whitespace-nowrap px-2 py-1" data-testid="pxq-consumption">
                {line.ruom ? (
                  <>
                    {idle && line.actual_sc === null ? m.notComputable : formatSignificant(line.actual_sc, locale)}
                    {" / "}{formatSignificant(line.budget_sc, locale)}
                    <span className="text-slate-500"> {line.symbol}/{driver.symbol}</span>
                  </>
                ) : "–"}
              </td>
              <td className="whitespace-nowrap px-2 py-1">{formatPercent(line.sc_pct, locale)}</td>
              <td className="whitespace-nowrap px-2 py-1" data-testid="pxq-price">
                {line.ruom ? `${formatPrice(line.actual_price, locale)} / ${formatPrice(line.budget_price, locale)}` : "–"}
              </td>
              <td className="whitespace-nowrap px-2 py-1">{formatPercent(line.price_pct, locale)}</td>
              <td className="whitespace-nowrap px-2 py-1">
                {formatNumber(line.actual_ksl, locale)} / {formatNumber(line.budget_ksl, locale)}
                <div className={`text-[11px] ${tone(line.variance)}`}>{formatPercent(line.variance_pct, locale)}</div>
              </td>
              {EFFECTS.map((effect) => {
                const value = line[`${effect}_effect` as const];
                const isOrigin = origin?.racct === line.racct && origin.effect === effect;
                return (
                  <td key={effect} data-testid={isOrigin ? "origin-cell" : undefined}
                      className={`whitespace-nowrap px-2 py-1 ${tone(value)} ${isOrigin ? "font-semibold outline outline-1 outline-red-400/60" : ""}`}>
                    {value === null ? "–" : formatNumber(value, locale, 0, true)}
                  </td>
                );
              })}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
