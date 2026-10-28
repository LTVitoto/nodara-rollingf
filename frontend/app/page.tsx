"use client";

import { useEffect, useMemo, useState } from "react";

import { ChatPanel } from "./components/ChatPanel";
import { ForecastChart, OPEX, type Measure } from "./components/ForecastChart";
import { Header, nimConfigured, type Status } from "./components/Header";
import { KpiTiles } from "./components/KpiTiles";
import { useI18n, type Engine } from "./i18n";
import type { CostCenter, Timeline } from "./types";

const ENGINE_KEY = "nodara.engine";
const TIMELINE_REFRESH_MS = 20000; // the lakehouse moves with CDC: refresh the chart in place
const EMPHASIS_MIN_PCT = 5; // only a material overrun vs budget (Trino's %) gets the accent hue

export default function Home() {
  const { language, t } = useI18n();
  const [status, setStatus] = useState<Status>();
  const [engine, setEngineState] = useState<Engine>("nim");
  const [centers, setCenters] = useState<CostCenter[]>([]);
  const [rcntr, setRcntr] = useState<string>();
  const [timeline, setTimeline] = useState<Timeline>();
  const [switching, setSwitching] = useState(false);
  const [notice, setNotice] = useState<"notReady" | "backendUnavailable">();
  const [measure, setMeasure] = useState<Measure>(OPEX);
  const nimAvailable = !status || nimConfigured(status.llm);

  useEffect(() => {
    try {
      const saved = window.localStorage.getItem(ENGINE_KEY);
      if (saved === "nim" || saved === "ollama") setEngineState(saved);
    } catch {
      // storage unavailable: keep the default engine
    }
    const load = () =>
      fetch("/api/status", { cache: "no-store" })
        .then((r) => r.json())
        .then(setStatus)
        .catch(() => setStatus(undefined));
    load();
    const id = setInterval(load, 15000);
    return () => clearInterval(id);
  }, []);

  useEffect(() => {
    if (!nimAvailable && engine === "nim") setEngineState("ollama");
  }, [nimAvailable, engine]);

  // Cost centers come from the lakehouse; retry while the CDC is still loading it.
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout>;
    let cancelled = false;
    const load = () =>
      fetch("/api/opex/cost-centers", { cache: "no-store" })
        .then(async (r) => {
          if (!r.ok) throw new Error(r.status === 502 ? "backendUnavailable" : "notReady");
          const body = await r.json();
          if (cancelled) return;
          setCenters(body.cost_centers);
          setRcntr((current) => current ?? body.default ?? undefined);
          setNotice(body.cost_centers.length ? undefined : "notReady");
          if (!body.cost_centers.length) timer = setTimeout(load, 5000);
        })
        .catch((error: Error) => {
          if (cancelled) return;
          setNotice(error.message === "backendUnavailable" ? "backendUnavailable" : "notReady");
          timer = setTimeout(load, 5000);
        });
    load();
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, []);

  useEffect(() => {
    if (!rcntr) return;
    let cancelled = false;
    const load = (initial: boolean) => {
      if (initial) setSwitching(true);
      fetch(`/api/opex/timeline?rcntr=${encodeURIComponent(rcntr)}`, { cache: "no-store" })
        .then((r) => (r.ok ? r.json() : Promise.reject(new Error(String(r.status)))))
        .then((body: Timeline) => {
          if (!cancelled) setTimeline(body);
        })
        .catch(() => {
          if (!cancelled && initial) setNotice("notReady");
        })
        .finally(() => {
          if (!cancelled && initial) setSwitching(false);
        });
    };
    load(true);
    const id = setInterval(() => load(false), TIMELINE_REFRESH_MS);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, [rcntr]);

  // The cost element that drives the deviation vs budget of the analyzed month gets the accent hue
  // (none when no account overruns its budget materially, e.g. fixed costs on budget).
  const emphasis = useMemo(() => {
    const overruns = (timeline?.summary?.accounts ?? []).filter((a) => (a.delta_budget_pct ?? 0) >= EMPHASIS_MIN_PCT);
    return overruns.reduce<(typeof overruns)[number] | undefined>(
      (best, account) => ((account.delta_budget ?? -Infinity) > (best?.delta_budget ?? -Infinity) ? account : best),
      undefined,
    )?.racct ?? null;
  }, [timeline]);

  // OPEX plus the unit OPEX of every driver of the cost center; a measure the selected cost center does
  // not have falls back to OPEX.
  const measures: { id: Measure; label: string }[] = [
    { id: OPEX, label: t.controls.opex },
    ...(timeline?.drivers ?? []).map((d) => ({ id: d.stagr, label: `USD/${d.symbol}` })),
  ];
  const shown = measures.some((option) => option.id === measure) ? measure : OPEX;

  function setEngine(next: Engine) {
    setEngineState(next);
    try {
      window.localStorage.setItem(ENGINE_KEY, next);
    } catch {
      // not persisted, still applied for this session
    }
  }

  return (
    <main className="mx-auto max-w-6xl px-4 py-8">
      <Header status={status} />

      <section className="mt-6 flex flex-wrap items-end gap-4">
        <label className="flex w-full min-w-0 flex-col gap-1 text-xs text-slate-400 sm:w-auto">
          {t.controls.costCenter}
          <select
            data-testid="cost-center-select"
            value={rcntr ?? ""}
            onChange={(e) => setRcntr(e.target.value)}
            className="w-full min-w-0 rounded-lg border border-slate-700 bg-slate-950 px-3 py-2 font-mono text-sm text-slate-100 outline-none focus:border-sky-500 sm:min-w-72"
          >
            {centers.map((center) => (
              <option key={center.rcntr} value={center.rcntr}>
                {center.rcntr} · {center.texts[language]}
              </option>
            ))}
          </select>
        </label>
        <div className="flex flex-col gap-1 text-xs text-slate-400">
          <span id="measure-label">{t.controls.measure}</span>
          <div role="group" aria-labelledby="measure-label" className="inline-flex rounded-lg border border-slate-700 p-0.5">
            {measures.map((option) => (
              <button
                key={option.id}
                type="button"
                onClick={() => setMeasure(option.id)}
                aria-pressed={shown === option.id}
                className={`rounded-md px-3 py-1.5 font-semibold transition-colors ${
                  shown === option.id ? "bg-sky-600 text-white" : "text-slate-400 hover:text-slate-100"
                }`}
              >
                {option.label}
              </button>
            ))}
          </div>
        </div>
      </section>

      {notice && !timeline ? (
        <div className="mt-4 rounded-lg border border-amber-700 bg-amber-950/40 p-3 text-sm text-amber-200">
          {notice === "notReady" ? t.controls.notReady : t.errors.backendUnavailable}
        </div>
      ) : null}

      {timeline?.summary ? (
        <div className="mt-4">
          <KpiTiles summary={timeline.summary} />
        </div>
      ) : null}

      <section
        className="mt-4 rounded-xl border border-slate-800 bg-slate-900/60 p-5 transition-opacity"
        style={{ opacity: switching && timeline ? 0.55 : 1 }}
      >
        <h2 className="text-sm font-semibold uppercase tracking-wide text-sky-400">{t.chart.title}</h2>
        <p className="mt-0.5 text-xs text-slate-400">
          {timeline ? `${timeline.rcntr} · ${t.chart.subtitle(timeline.budget_category, timeline.category)}` : t.controls.loading}
        </p>
        <div className="mt-4">
          {timeline ? <ForecastChart timeline={timeline} measure={shown} emphasis={emphasis} /> : null}
        </div>
      </section>

      <ChatPanel rcntr={rcntr} engine={engine} onEngineChange={setEngine} nimAvailable={nimAvailable} />
    </main>
  );
}
