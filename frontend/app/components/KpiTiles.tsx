"use client";

// Stat tiles of the analyzed month against the base budget (figures computed by Trino). The delta tone
// follows direction × whether up is good, and always ships with an arrow and a word, so the color never
// carries the meaning alone; the previous month follows as muted context.
import { formatCompact, formatMonth, formatNumber, formatPercent } from "../format";
import { useI18n } from "../i18n";
import type { Analysis, Metric } from "../types";

function Delta({ metric, upIsGood, previous }: { metric?: Metric | null; upIsGood: boolean; previous: string | null }) {
  const { t } = useI18n();
  const pct = metric?.delta_budget_pct;
  const prev = metric?.delta_previous_pct;
  const worse = pct !== null && pct !== undefined && pct !== 0 && pct > 0 !== upIsGood;
  return (
    <>
      {pct !== null && pct !== undefined ? (
        <div className={`mt-1 text-xs ${worse ? "text-red-400" : "text-emerald-400"}`}>
          {pct > 0 ? "▲" : pct < 0 ? "▼" : "■"} {formatPercent(pct, t.locale)} {t.kpi.vsBudget}
          <span className="text-slate-500"> · {worse ? t.kpi.worse : t.kpi.better}</span>
        </div>
      ) : null}
      {prev !== null && prev !== undefined && previous ? (
        <div className="mt-0.5 text-[11px] text-slate-500">
          {formatPercent(prev, t.locale)} {t.kpi.vsPrevious(formatMonth(previous, t.locale))}
        </div>
      ) : null}
    </>
  );
}

function Tile({ id, label, value, children }: { id: string; label: string; value: string; children?: React.ReactNode }) {
  return (
    <div data-testid={`kpi-${id}`} className="rounded-xl border border-slate-800 bg-slate-900/60 p-4">
      <div className="text-xs text-slate-400">{label}</div>
      <div className="mt-1 text-2xl font-semibold text-slate-50">{value}</div>
      {children}
    </div>
  );
}

export function KpiTiles({ summary }: { summary: Analysis }) {
  const { language, t } = useI18n();
  const locale = t.locale;
  const unit = summary.unit_costs.find((u) => u.stagr === summary.driver) ?? summary.unit_costs[0];
  const driver = summary.drivers.find((d) => d.stagr === summary.driver) ?? summary.drivers[0];
  const plan = summary.forecast;
  return (
    <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
      <Tile id="opex" label={t.kpi.opex(formatMonth(summary.period, locale))}
            value={`USD ${formatCompact(summary.opex?.current, locale)}`}>
        <Delta metric={summary.opex} upIsGood={false} previous={summary.previous_period} />
      </Tile>
      <Tile id="unit" label={t.kpi.unit(unit?.symbol ?? "–")}
            value={unit ? `${formatNumber(unit.current, locale, unit.decimals)} USD/${unit.symbol}` : "–"}>
        <Delta metric={unit} upIsGood={false} previous={summary.previous_period} />
      </Tile>
      <Tile id="driver" label={driver ? `${driver.texts[language]} (${driver.stagr})` : "–"}
            value={driver ? `${formatNumber(driver.current, locale)} ${driver.symbol}` : "–"}>
        <Delta metric={driver} upIsGood previous={summary.previous_period} />
      </Tile>
      <Tile id="plan" label={`${t.kpi.forecast} · ${summary.category}`}
            value={plan.months ? `USD ${formatCompact(plan.total_opex, locale)}` : "–"}>
        {plan.months && unit ? (
          <div className="mt-1 text-xs text-slate-400">
            {t.kpi.closing(`${formatNumber(plan.last_unit_cost, locale, plan.decimals ?? unit.decimals)} USD/${unit.symbol}`,
                           formatMonth(plan.last_period, locale))}
            {plan.stable_from ? ` · ${t.kpi.stable(formatMonth(plan.stable_from, locale))}` : ""}
          </div>
        ) : null}
      </Tile>
    </div>
  );
}
