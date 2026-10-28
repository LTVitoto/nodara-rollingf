// Payloads of the backend API (/api/v1/opex/*, /api/v1/ask). Every figure arrives computed by Trino.
import type { Engine, Language } from "./dictionaries";

export type Texts = Record<Language, string>;

export type Metric = {
  current: number | null;
  previous: number | null;
  baseline: number | null;
  delta_previous: number | null;
  delta_previous_pct: number | null;
  delta_baseline: number | null;
  delta_baseline_pct: number | null;
  share_pct: number | null;
};

export type Forecast = {
  months: number;
  first_period?: string;
  last_period?: string;
  total_opex?: number;
  horizon_usd_per_hour?: number;
  first_opex?: number;
  first_usd_per_hour?: number;
  last_opex?: number;
  last_usd_per_hour?: number;
  stable_from?: string | null;
  last_vs_period_pct?: number;
};

export type Analysis = {
  rcntr: string;
  rcntr_texts: Texts;
  currency: string;
  category: string;
  category_texts: Texts;
  period: string;
  previous_period: string | null;
  baseline: { months: number; from: string | null; to: string | null };
  totals: Partial<Record<"OPEX" | "HOROP" | "TONMOV" | "USD_H" | "USD_T", Metric>>;
  accounts: (Metric & { racct: string; texts: Texts })[];
  top_postings: { belnr: string; budat: string; racct: string; sgtxt: string; ksl: number }[];
  forecast: Forecast;
};

export type Month = {
  period: string;
  kind: "actual" | "plan";
  opex: number;
  hours: number | null;
  tonnes: number | null;
  usd_per_hour: number | null;
  usd_per_tonne: number | null;
  accounts: Record<string, number>;
};

export type Timeline = {
  rcntr: string;
  rcntr_texts: Texts;
  currency: string;
  category: string;
  category_texts: Texts;
  periods: Month[];
  accounts: { racct: string; texts: Texts }[];
  summary: Analysis | null;
};

export type CostCenter = {
  rcntr: string;
  first_actual: string | null;
  last_actual: string | null;
  categories: string[];
  texts: Texts;
  category_texts: Record<string, Texts>;
};

export type Source = {
  doc_id: string;
  title: string;
  author_role: string;
  source_uri: string;
  section: string;
  similarity: number;
  excerpt: string;
  metadata: Record<string, number | string>;
};

export type AskResult = {
  answer: string;
  language: string;
  language_check: { status: string };
  figures_check: { checked: number; grounded: number; ungrounded: string[] };
  engine: Engine;
  model_used: string;
  trace_url: string | null;
  rcntr: string;
  period: string;
  analysis: Analysis;
  retrieval_filter: Record<string, number | string>;
  sources: Source[];
  timings_ms: Record<string, number>;
};
