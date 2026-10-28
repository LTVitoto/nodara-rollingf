"use client";

// Stat tiles of the analyzed month against the base budget (figures computed by Trino). The delta tone
// follows direction × whether up is good, and always ships with an arrow and a word, so the color never
// carries the meaning alone. A zero driver makes the unit OPEX not computable, and the tile says so.
import { formatCompact, formatMonth, formatNumber, formatPercent } from "../format";
import { useI18n } from "../i18n";
import type { Analysis } from "../types";

function Delta({ pct, upIsGood }: { pct: number | null | undefined; upIsGood: boolean }) {
  const { t } = useI18n();
  if (pct === null || pct === undefined) return null;
  const worse = pct !== 0 && pct > 0 !== upIsGood;
  return (
    <div className={`mt-1 text-xs ${worse ? "text-red-400" : "text-emerald-400"}`}>
      {pct > 0 ? "▲" : pct < 0 ? "▼" : "■"} {formatPercent(pct, t.locale)} {t.kpi.vsBudget}
      <span className="text-slate-500"> · {worse ? t.kpi.worse : t.kpi.better}</span>
    </div>
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
  const { driver, opex, unit_cost: unit, forecast: plan } = summary;
  const unitLabel = `USD/${driver.symbol}`;
  return (
    <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
      <Tile id="opex" label={t.kpi.opex(formatMonth(summary.period, locale))} value={`USD ${formatCompact(opex.actual, locale)}`}>
        <Delta pct={opex.variance_pct} upIsGood={false} />
      </Tile>
      <Tile id="unit" label={t.kpi.unit(driver.symbol)}
            value={unit.actual === null ? "–" : `${formatNumber(unit.actual, locale, driver.decimals)} ${unitLabel}`}>
        {unit.actual === null ? (
          <div className="mt-1 text-xs text-amber-300">{t.kpi.notComputable}</div>
        ) : (
          <Delta pct={unit.delta_pct} upIsGood={false} />
        )}
      </Tile>
      <Tile id="driver" label={`${driver.texts[language]} (${driver.stagr})`}
            value={`${formatNumber(driver.actual, locale)} ${driver.symbol}`}>
        <Delta pct={driver.delta_pct} upIsGood />
      </Tile>
      <Tile id="plan" label={`${t.kpi.forecast} · ${summary.category}`}
            value={plan.months ? `USD ${formatCompact(plan.total_opex, locale)}` : "–"}>
        {plan.months ? (
          <div className="mt-1 text-xs text-slate-400">
            {t.kpi.closing(`${formatNumber(plan.last_unit_cost, locale, driver.decimals)} ${unitLabel}`,
                           formatMonth(plan.last_period, locale))}
            {plan.stable_from ? ` · ${t.kpi.stable(formatMonth(plan.stable_from, locale))}` : ""}
          </div>
        ) : null}
      </Tile>
    </div>
  );
}
