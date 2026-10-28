// Payloads of the backend API (/api/v1/opex/*, /api/v1/ask). Every figure arrives computed by Trino.
import type { Engine, Language } from "./dictionaries";

export type Texts = Record<Language, string>;

// Analyzed actual month against the base budget (BUDG), with the previous actual month as context.
export type Metric = {
  current: number | null;
  budget: number | null;
  previous: number | null;
  delta_budget: number | null;
  delta_budget_pct: number | null;
  delta_previous: number | null;
  delta_previous_pct: number | null;
  share_pct: number | null;
};

// Statistical key figure (FINSSKF STAGR) a unit OPEX is reported against: symbol "h", "t", "WMT".
export type Driver = { stagr: string; runit: string; symbol: string; texts: Texts };

export type Forecast = {
  months: number;
  first_period?: string;
  last_period?: string;
  stagr?: string;
  runit?: string;
  decimals?: number;
  total_opex?: number;
  horizon_unit_cost?: number;
  first_opex?: number;
  first_unit_cost?: number;
  last_opex?: number;
  last_unit_cost?: number;
  stable_from?: string | null;
  last_vs_period_pct?: number;
};

export type Analysis = {
  rcntr: string;
  rcntr_texts: Texts;
  currency: string;
  category: string;
  category_texts: Texts;
  budget_category: string;
  budget_texts: Texts;
  period: string;
  previous_period: string | null;
  driver: string | null;
  opex: Metric | null;
  drivers: (Driver & Metric)[];
  unit_costs: (Driver & Metric & { decimals: number })[];
  accounts: (Metric & { racct: string; texts: Texts })[];
  top_postings: { belnr: string; budat: string; racct: string; sgtxt: string; ksl: number }[];
  forecast: Forecast;
};

export type DriverValue = { quantity: number | null; unit_cost: number | null };

export type Month = {
  period: string;
  kind: "actual" | "plan";
  opex: number | null;
  accounts: Record<string, number>;
  drivers: Record<string, DriverValue>;
  budget: {
    opex: number;
    delta: number | null;
    delta_pct: number | null;
    accounts: Record<string, number>;
    drivers: Record<string, DriverValue & { unit_delta_pct: number | null }>;
  } | null;
};

export type Timeline = {
  rcntr: string;
  rcntr_texts: Texts;
  currency: string;
  category: string;
  category_texts: Texts;
  budget_category: string;
  periods: Month[];
  accounts: { racct: string; texts: Texts }[];
  drivers: (Driver & { decimals: number })[];
  driver: string | null;
  summary: Analysis | null;
};

export type CostCenter = {
  rcntr: string;
  first_actual: string | null;
  last_actual: string | null;
  categories: string[];
  budget: boolean;
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
