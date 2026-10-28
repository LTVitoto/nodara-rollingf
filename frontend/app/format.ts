// Display formatting of Trino figures in the UI locale (formatting only: no arithmetic on the data).

export function formatNumber(value: number | null | undefined, locale: string, digits = 0, signed = false): string {
  if (value === null || value === undefined) return "–";
  return new Intl.NumberFormat(locale, {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
    signDisplay: signed ? "exceptZero" : "auto",
  }).format(value);
}

export function formatCompact(value: number | null | undefined, locale: string): string {
  if (value === null || value === undefined) return "–";
  return new Intl.NumberFormat(locale, { notation: "compact", maximumFractionDigits: 2 }).format(value);
}

export function formatPercent(value: number | null | undefined, locale: string): string {
  return value === null || value === undefined ? "–" : `${formatNumber(value, locale, 1, true)} %`;
}

// "2026-10" → "oct 26" / "Oct 26" / "out. 26"
export function formatMonth(period: string | null | undefined, locale: string): string {
  if (!period) return "–";
  const [year, month] = period.split("-").map(Number);
  return new Intl.DateTimeFormat(locale, { month: "short", year: "2-digit", timeZone: "UTC" }).format(
    new Date(Date.UTC(year, month - 1, 1)),
  );
}
