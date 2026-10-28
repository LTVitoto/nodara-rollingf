"use client";

// Monthly OPEX timeline: actual months (ACDOCA) followed by the plan months (ACDOCP) as one continuous
// column chart, each actual month with its base budget (BUDG) as a reference tick. Emphasis form: the
// cost element that drives the deviation in the accent hue, the rest of the OPEX in the de-emphasis
// gray, plan months in dimmer steps of both. One y-axis per measure (never dual-axis): the measure
// toggle swaps USD ↔ the unit OPEX of the cost center driver (USD/m, USD/t, USD/m³, USD/WMT). Colors
// validated with the dataviz validator on the panel surface #0f172a: CVD ΔE ≥ 14.6, normal-vision
// ΔE ≥ 15.7, contrast ≥ 3.3:1; the budget tick is a neutral reference mark (ink, 14:1) with a 2px
// surface halo, named in the legend, the tooltip and the table (never color alone).
import { useEffect, useRef, useState } from "react";

import { formatCompact, formatMonth, formatNumber, formatPercent } from "../format";
import { useI18n } from "../i18n";
import type { Month, Timeline } from "../types";

// OPEX in USD or the unit OPEX of the cost center driver (OPEX / driver, computed by Trino).
export type Measure = "opex" | "unit";
export const OPEX: Measure = "opex";
export const UNIT: Measure = "unit";

const COLOR = {
  accent: "#3987e5",
  accentPlan: "#256abf",
  rest: "#898781",
  restPlan: "#6f6e69",
  budget: "#e2e8f0",
  surface: "#0f172a",
  grid: "#1e293b",
  baseline: "#334155",
  ink: "#e2e8f0",
  muted: "#94a3b8",
};
const PLOT_HEIGHT = 260;
const MARGIN = { top: 34, right: 12, bottom: 30, left: 52 };
const MAX_BAR = 24;
const TOOLTIP_WIDTH = 256;
const GAP = 2;
const RADIUS = 4;
const TICK_OVERHANG = 4;

function valueOf(month: Month, measure: Measure): number | null {
  return measure === OPEX ? month.opex : month.unit_cost;
}

function budgetOf(month: Month, measure: Measure): number | null {
  return (measure === OPEX ? month.budget?.opex : month.budget?.unit_cost) ?? null;
}

function budgetDelta(month: Month, measure: Measure): number | null {
  return (measure === OPEX ? month.budget?.delta_pct : month.budget?.unit_delta_pct) ?? null;
}

// Clean y-axis ticks (1 / 2 / 2.5 / 5 × 10^k): chart geometry, not data.
function ticks(max: number): number[] {
  if (!(max > 0)) return [0, 1];
  const raw = max / 4;
  const power = 10 ** Math.floor(Math.log10(raw));
  const step = [1, 2, 2.5, 5, 10].map((m) => m * power).find((s) => s >= raw) ?? 10 * power;
  return Array.from({ length: Math.ceil(max / step) + 1 }, (_, i) => i * step);
}

// Column path: 4px rounded data-end on top, square at the baseline.
function column(x: number, top: number, bottom: number, width: number, rounded: boolean): string {
  const r = rounded ? Math.min(RADIUS, width / 2, Math.max(0, bottom - top)) : 0;
  return `M${x},${bottom}V${top + r}Q${x},${top} ${x + r},${top}H${x + width - r}Q${x + width},${top} ${x + width},${top + r}V${bottom}Z`;
}

function TooltipRow({ label, value, strong = false, mark }: {
  label: string;
  value: string;
  strong?: boolean;
  mark?: string;
}) {
  return (
    <div className="flex items-center justify-between gap-3">
      <dt className="flex min-w-0 items-center gap-1.5 text-slate-400">
        {mark ? <span className="inline-block h-0.5 w-3 shrink-0" style={{ background: mark }} /> : null}
        <span className="truncate">{label}</span>
      </dt>
      <dd className={`whitespace-nowrap tabular-nums ${strong ? "font-semibold text-slate-50" : "text-slate-100"}`}>{value}</dd>
    </div>
  );
}

export function ForecastChart({ timeline, measure, emphasis }: {
  timeline: Timeline;
  measure: Measure;
  emphasis: string | null;
}) {
  const { language, t } = useI18n();
  const locale = t.locale;
  const wrapper = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(880);
  const [active, setActive] = useState<number | null>(null);
  const [table, setTable] = useState(false);

  useEffect(() => {
    const element = wrapper.current;
    if (!element) return;
    const observer = new ResizeObserver(([entry]) => setWidth(Math.max(300, Math.floor(entry.contentRect.width))));
    observer.observe(element);
    return () => observer.disconnect();
  }, [table]);

  const months = timeline.periods;
  const budgetLabel = t.chart.budget(timeline.budget_category);
  const driver = timeline.driver;
  const digits = measure === UNIT && driver ? driver.decimals : 0;
  const unit = measure === UNIT && driver ? `USD/${driver.symbol}` : "USD";
  const accountName = (racct: string) => timeline.accounts.find((a) => a.racct === racct)?.texts[language] ?? racct;
  const stacked = measure === OPEX && emphasis !== null;
  const hasBudget = months.some((m) => budgetOf(m, measure) !== null);
  const yTicks = ticks(Math.max(0, ...months.flatMap((m) => [valueOf(m, measure) ?? 0, budgetOf(m, measure) ?? 0])));
  const yMax = yTicks[yTicks.length - 1];
  const plotWidth = width - MARGIN.left - MARGIN.right;
  const band = plotWidth / Math.max(months.length, 1);
  const barWidth = Math.min(MAX_BAR, band * 0.62);
  const y = (value: number) => MARGIN.top + PLOT_HEIGHT - (value / yMax) * PLOT_HEIGHT;
  const baseline = MARGIN.top + PLOT_HEIGHT;
  const firstPlan = months.findIndex((m) => m.kind === "plan");
  const lastActual = firstPlan === -1 ? months.length - 1 : firstPlan - 1;
  const labelled = new Set([lastActual, months.length - 1].filter((i) => i >= 0));
  const labelEvery = Math.max(1, Math.ceil(46 / band));
  const display = (value: number | null) => (measure === OPEX ? formatCompact(value, locale) : formatNumber(value, locale, digits));
  // Tooltip value of the shown measure, written like its row: "USD 1.234" or the bare unit OPEX.
  const tooltipValue = (value: number | null) =>
    measure === OPEX ? `USD ${formatNumber(value, locale)}` : formatNumber(value, locale, digits);
  const kind = (month: Month) => (month.kind === "actual" ? t.chart.actual : t.chart.plan);
  const focused = active === null ? null : months[active];
  const focusedBudget = focused ? budgetOf(focused, measure) : null;
  // Tooltip beside the hovered column, clamped inside the chart (no horizontal page scroll on phones).
  const tooltipWidth = Math.min(TOOLTIP_WIDTH, width);
  const anchor = MARGIN.left + band * (active ?? 0);
  const tooltipLeft = Math.max(0, Math.min(width - tooltipWidth,
    anchor + band / 2 > width / 2 ? anchor - tooltipWidth - 8 : anchor + band + 8));

  const toggle = (
    <button
      type="button"
      onClick={() => setTable((value) => !value)}
      className="rounded-md border border-slate-700 px-2.5 py-1 text-xs text-slate-300 hover:border-sky-500"
    >
      {table ? t.chart.showChart : t.chart.showTable}
    </button>
  );

  const legend = (
    <ul className="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-slate-300">
      {stacked ? (
        <>
          <li className="flex items-center gap-1.5">
            <span className="inline-block h-2.5 w-2.5 rounded-sm" style={{ background: COLOR.accent }} />
            {emphasis} {accountName(emphasis!)}
          </li>
          <li className="flex items-center gap-1.5">
            <span className="inline-block h-2.5 w-2.5 rounded-sm" style={{ background: COLOR.rest }} />
            {t.chart.rest}
          </li>
        </>
      ) : null}
      {hasBudget ? (
        <li className="flex items-center gap-1.5">
          <svg width={14} height={8} aria-hidden="true">
            <line x1={1} x2={13} y1={4} y2={4} stroke={COLOR.budget} strokeWidth={2} strokeLinecap="round" />
          </svg>
          {budgetLabel}
        </li>
      ) : null}
      <li className="flex items-center gap-1.5 text-slate-400">
        <span className="inline-block h-2.5 w-2.5 rounded-sm" style={{ background: COLOR.accent }} />
        {t.chart.actual}
        <span className="ml-2 inline-block h-2.5 w-2.5 rounded-sm" style={{ background: COLOR.accentPlan }} />
        {t.chart.plan} · {timeline.category}
      </li>
    </ul>
  );

  if (table) {
    return (
      <div data-testid="chart-table">
        <div className="flex flex-wrap items-center justify-between gap-2">{legend}{toggle}</div>
        <div className="mt-3 overflow-x-auto">
          <table className="w-full text-right text-xs tabular-nums">
            <thead className="text-slate-400">
              <tr className="border-b border-slate-800">
                <th className="py-1.5 pr-3 text-left font-medium">{t.chart.period}</th>
                <th className="py-1.5 pr-3 text-left font-medium">{t.chart.kind}</th>
                <th className="py-1.5 pr-3 font-medium">{t.chart.total}</th>
                <th className="py-1.5 pr-3 font-medium">{budgetLabel}</th>
                <th className="py-1.5 pr-3 font-medium">{t.chart.deviation}</th>
                {timeline.accounts.map((a) => (
                  <th key={a.racct} className="py-1.5 pr-3 font-medium">{a.texts[language]}</th>
                ))}
                {driver ? (
                  <>
                    <th className="py-1.5 pr-3 font-medium">{driver.texts[language]} ({driver.symbol})</th>
                    <th className="py-1.5 pr-3 font-medium">{t.chart.unit(driver.symbol)}</th>
                  </>
                ) : null}
              </tr>
            </thead>
            <tbody className="text-slate-200">
              {months.map((m) => (
                <tr key={m.period} className="border-b border-slate-900">
                  <td className="py-1 pr-3 text-left">{formatMonth(m.period, locale)}</td>
                  <td className="py-1 pr-3 text-left text-slate-400">{kind(m)}</td>
                  <td className="py-1 pr-3">{formatNumber(m.opex, locale)}</td>
                  <td className="py-1 pr-3">{formatNumber(m.budget?.opex, locale)}</td>
                  <td className="py-1 pr-3">{formatPercent(m.budget?.delta_pct, locale)}</td>
                  {timeline.accounts.map((a) => (
                    <td key={a.racct} className="py-1 pr-3">{formatNumber(m.accounts[a.racct], locale)}</td>
                  ))}
                  {driver ? (
                    <>
                      <td className="py-1 pr-3">{formatNumber(m.driver_qty, locale)}</td>
                      <td className="py-1 pr-3">{formatNumber(m.unit_cost, locale, driver.decimals)}</td>
                    </>
                  ) : null}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    );
  }

  return (
    <div>
      <div className="flex flex-wrap items-center justify-between gap-2">{legend}{toggle}</div>
      <div ref={wrapper} className="relative mt-3 w-full" onPointerLeave={() => setActive(null)}>
        <svg
          data-testid="chart"
          role="img"
          aria-label={t.chart.aria(timeline.rcntr)}
          width={width}
          height={baseline + MARGIN.bottom}
          className="block select-none"
        >
          {yTicks.map((tick) => (
            <g key={tick}>
              <line x1={MARGIN.left} x2={width - MARGIN.right} y1={y(tick)} y2={y(tick)}
                    stroke={tick === 0 ? COLOR.baseline : COLOR.grid} strokeWidth={1} />
              <text x={MARGIN.left - 8} y={y(tick)} dy="0.32em" textAnchor="end" fontSize={11} fill={COLOR.muted}
                    className="tabular-nums">
                {measure === OPEX ? formatCompact(tick, locale) : formatNumber(tick, locale, tick % 1 ? digits : 0)}
              </text>
            </g>
          ))}
          <text x={MARGIN.left} y={12} fontSize={11} fill={COLOR.muted}>{unit}</text>

          {firstPlan > 0 ? (
            <g>
              <line x1={MARGIN.left + band * firstPlan} x2={MARGIN.left + band * firstPlan} y1={MARGIN.top - 16}
                    y2={baseline} stroke={COLOR.baseline} strokeWidth={1} />
              <text x={MARGIN.left + band * firstPlan - 6} y={MARGIN.top - 6} textAnchor="end" fontSize={11}
                    fill={COLOR.muted}>{t.chart.actual}</text>
              <text x={MARGIN.left + band * firstPlan + 6} y={MARGIN.top - 6} fontSize={11}
                    fill={COLOR.muted}>{t.chart.plan} · {timeline.category}</text>
            </g>
          ) : null}

          {active !== null ? (
            <rect x={MARGIN.left + band * active} y={MARGIN.top} width={band} height={PLOT_HEIGHT}
                  fill="#1e293b" opacity={0.6} />
          ) : null}

          {months.map((m, i) => {
            const value = valueOf(m, measure);
            const budget = budgetOf(m, measure);
            const x = MARGIN.left + band * i + (band - barWidth) / 2;
            const plan = m.kind === "plan";
            const accent = plan ? COLOR.accentPlan : COLOR.accent;
            const part = stacked ? m.accounts[emphasis!] ?? 0 : null;
            // Value label above the bar or its budget tick, whichever is higher (layout only).
            const labelTop = Math.min(value === null ? baseline : y(value), budget === null ? baseline : y(budget));
            return (
              <g key={m.period} data-testid={plan ? "bar-plan" : "bar-actual"}>
                {value !== null && part === null ? (
                  <path d={column(x, y(value), baseline, barWidth, true)} fill={accent} />
                ) : null}
                {value !== null && part !== null ? (
                  <>
                    <path d={column(x, y(part), baseline, barWidth, y(value) >= y(part) - GAP)} fill={accent} />
                    {y(value) < y(part) - GAP ? (
                      <path d={column(x, y(value), y(part) - GAP, barWidth, true)}
                            fill={plan ? COLOR.restPlan : COLOR.rest} />
                    ) : null}
                  </>
                ) : null}
                {budget !== null ? (
                  <g data-testid="budget-marker">
                    <line x1={x - TICK_OVERHANG} x2={x + barWidth + TICK_OVERHANG} y1={y(budget)} y2={y(budget)}
                          stroke={COLOR.surface} strokeWidth={6} strokeLinecap="round" />
                    <line x1={x - TICK_OVERHANG} x2={x + barWidth + TICK_OVERHANG} y1={y(budget)} y2={y(budget)}
                          stroke={COLOR.budget} strokeWidth={2} strokeLinecap="round" />
                  </g>
                ) : null}
                {value !== null && labelled.has(i) ? (
                  <text x={x + barWidth / 2} y={labelTop - 6} textAnchor="middle" fontSize={11} fontWeight={600}
                        fill={COLOR.ink}>{display(value)}</text>
                ) : null}
                {(i - lastActual) % labelEvery === 0 ? (
                  <text x={x + barWidth / 2} y={baseline + 18} textAnchor="middle" fontSize={10.5}
                        fill={i === lastActual ? COLOR.ink : COLOR.muted}>{formatMonth(m.period, locale)}</text>
                ) : null}
                <rect
                  x={MARGIN.left + band * i}
                  y={MARGIN.top}
                  width={band}
                  height={PLOT_HEIGHT + 20}
                  fill="transparent"
                  tabIndex={0}
                  aria-label={`${formatMonth(m.period, locale)} · ${kind(m)} · ${display(value)} ${unit}`
                    + (budget !== null ? ` · ${budgetLabel} ${display(budget)}` : "")}
                  onPointerEnter={() => setActive(i)}
                  onFocus={() => setActive(i)}
                  onBlur={() => setActive(null)}
                  className="cursor-crosshair outline-none"
                />
              </g>
            );
          })}
        </svg>

        {focused ? (
          <div
            data-testid="chart-tooltip"
            role="status"
            className="pointer-events-none absolute top-2 z-10 rounded-lg border border-slate-700 bg-slate-950/95 p-3 text-xs shadow-xl"
            style={{ left: tooltipLeft, width: tooltipWidth }}
          >
            <div className="mb-2 flex items-baseline justify-between text-slate-400">
              <span className="font-semibold text-slate-200">{formatMonth(focused.period, locale)}</span>
              <span>{kind(focused)}</span>
            </div>
            <dl className="space-y-1">
              <TooltipRow label={t.chart.total} value={`USD ${formatNumber(focused.opex, locale)}`} strong />
              {focusedBudget !== null ? (
                <>
                  <TooltipRow label={budgetLabel} value={tooltipValue(focusedBudget)} mark={COLOR.budget} />
                  <TooltipRow label={t.chart.deviation} value={formatPercent(budgetDelta(focused, measure), locale)} />
                </>
              ) : null}
              {timeline.accounts.map((a) => (
                <TooltipRow key={a.racct} label={a.texts[language]} value={formatNumber(focused.accounts[a.racct], locale)}
                            mark={a.racct === emphasis ? COLOR.accent : COLOR.rest} />
              ))}
              {driver ? (
                <div className="space-y-1 border-t border-slate-800 pt-1">
                  <TooltipRow label={driver.texts[language]} value={`${formatNumber(focused.driver_qty, locale)} ${driver.symbol}`} />
                  <TooltipRow label={t.chart.unit(driver.symbol)} value={formatNumber(focused.unit_cost, locale, driver.decimals)}
                              strong={measure === UNIT} />
                </div>
              ) : null}
            </dl>
          </div>
        ) : null}
      </div>
    </div>
  );
}
