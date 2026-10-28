"use client";

// Stat tiles of the analyzed month (figures computed by Trino). The delta tone follows direction × whether
// up is good, and always ships with an arrow and a word, so the color never carries the meaning alone.
import { formatCompact, formatMonth, formatNumber, formatPercent } from "../format";
import { useI18n } from "../i18n";
import type { Analysis, Metric } from "../types";

function Delta({ metric, upIsGood, period }: { metric?: Metric; upIsGood: boolean; period: string | null }) {
  const { t } = useI18n();
  const pct = metric?.delta_previous_pct;
  if (pct === null || pct === undefined || !period) return null;
  const worse = pct !== 0 && pct > 0 !== upIsGood;
  return (
    <div className={`mt-1 text-xs ${worse ? "text-red-400" : "text-emerald-400"}`}>
      {pct > 0 ? "▲" : pct < 0 ? "▼" : "■"} {formatPercent(pct, t.locale)} {t.kpi.vs(formatMonth(period, t.locale))}
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
  const { t } = useI18n();
  const locale = t.locale;
  const { OPEX: opex, USD_H: unit, HOROP: hours } = summary.totals;
  const plan = summary.forecast;
  return (
    <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
      <Tile id="opex" label={t.kpi.opex(formatMonth(summary.period, locale))} value={`USD ${formatCompact(opex?.current, locale)}`}>
        <Delta metric={opex} upIsGood={false} period={summary.previous_period} />
      </Tile>
      <Tile id="unit" label={t.kpi.unit} value={`${formatNumber(unit?.current, locale, 2)} USD/h`}>
        <Delta metric={unit} upIsGood={false} period={summary.previous_period} />
      </Tile>
      <Tile id="hours" label={t.kpi.hours} value={`${formatNumber(hours?.current, locale)} h`}>
        <Delta metric={hours} upIsGood period={summary.previous_period} />
      </Tile>
      <Tile id="plan" label={`${t.kpi.forecast} · ${summary.category}`}
            value={plan.months ? `USD ${formatCompact(plan.total_opex, locale)}` : "–"}>
        {plan.months ? (
          <div className="mt-1 text-xs text-slate-400">
            {t.kpi.closing(formatNumber(plan.last_usd_per_hour, locale, 2), formatMonth(plan.last_period, locale))}
            {plan.stable_from ? ` · ${t.kpi.stable(formatMonth(plan.stable_from, locale))}` : ""}
          </div>
        ) : null}
      </Tile>
    </div>
  );
}
