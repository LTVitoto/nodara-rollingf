// Payloads of the backend API (/api/v1/opex/*, /api/v1/ask). Every figure arrives computed by Trino.
import type { Engine, Language } from "./dictionaries";

export type Texts = Record<Language, string>;

export type Effect = "price" | "efficiency" | "volume" | "spending";

// Statistical key figure (FINSSKF STAGR) of the cost center: symbol "m", "t", "m³", "WMT".
export type Driver = { stagr: string; runit: string; symbol: string; texts: Texts; decimals: number };

export type DriverValues = Driver & { actual: number | null; budget: number | null; delta_pct: number | null };

// One G/L account (RACCT) of a cost center in the analyzed month: P x Q against the budget (BUDG).
export type PxqLine = {
  racct: string;
  texts: Texts;
  ruom: string | null;
  symbol: string;
  behavior: "F" | "V" | "M";
  actual_ksl: number;
  budget_ksl: number;
  flex_ksl: number;
  variance: number;
  variance_pct: number | null;
  actual_msl: number | null;
  budget_msl: number | null;
  flex_msl: number | null;
  actual_price: number | null;
  budget_price: number | null;
  price_pct: number | null;
  actual_sc: number | null;
  budget_sc: number | null;
  sc_pct: number | null;
  price_effect: number | null;
  efficiency_effect: number | null;
  volume_effect: number | null;
  spending_effect: number | null;
};

export type Origin = { racct: string; texts: Texts; effect: Effect; amount: number };

export type Forecast = {
  months: number;
  first_period?: string;
  last_period?: string;
  total_opex?: number;
  horizon_unit_cost?: number | null;
  first_opex?: number;
  first_unit_cost?: number | null;
  last_opex?: number;
  last_unit_cost?: number | null;
  stable_from?: string | null;
  last_vs_period_pct?: number | null;
};

export type Totals = { actual: number; budget: number; variance: number; variance_pct: number | null; flex?: number };
export type UnitCost = { actual: number | null; budget: number | null; delta_pct: number | null };

export type Analysis = {
  rcntr: string;
  rcntr_texts: Texts;
  area: string;
  area_texts: Texts;
  currency: string;
  category: string;
  category_texts: Texts;
  budget_category: string;
  budget_texts: Texts;
  period: string;
  driver: DriverValues;
  opex: Totals;
  unit_cost: UnitCost;
  effects: Record<Effect, number | null>;
  origins: Origin[];
  lines: PxqLine[];
  top_postings: { belnr: string; budat: string; racct: string; sgtxt: string; ksl: number; msl: number; runit: string | null }[];
  forecast: Forecast;
};

export type Month = {
  period: string;
  kind: "actual" | "plan";
  opex: number | null;
  driver_qty: number | null;
  unit_cost: number | null;
  accounts: Record<string, number>;
  budget: {
    opex: number;
    driver_qty: number | null;
    unit_cost: number | null;
    delta_pct: number | null;
    unit_delta_pct: number | null;
    accounts: Record<string, number>;
  } | null;
};

export type Timeline = {
  rcntr: string;
  rcntr_texts: Texts;
  area: string;
  area_texts: Texts;
  currency: string;
  category: string;
  category_texts: Texts;
  budget_category: string;
  periods: Month[];
  accounts: { racct: string; texts: Texts }[];
  driver: Driver | null;
  summary: Analysis | null;
};

export type MatrixCenter = {
  rcntr: string;
  texts: Texts;
  area: string;
  area_texts: Texts;
  driver: DriverValues;
  opex: Totals;
  unit_cost: UnitCost;
  origin: Origin | null;
  lines: PxqLine[];
};

export type Matrix = {
  period: string | null;
  currency: string;
  budget_category: string;
  areas: { area: string; texts: Texts; cost_centers: MatrixCenter[] }[];
};

export type CostCenter = {
  rcntr: string;
  first_actual: string | null;
  last_actual: string | null;
  categories: string[];
  budget: boolean;
  area: string;
  area_texts: Texts;
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
  metadata: Record<string, number | string | string[]>;  // Año, Mes, RCNTR + Alcance (cost centers it covers)
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
