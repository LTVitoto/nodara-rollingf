"""Rolling forecast views composed from the Trino results (lakehouse.py): cost center scope, the
monthly timeline (actuals + plan) for the chart, and the variance analysis the AI explains.
No arithmetic happens here: every figure arrives computed by Trino."""
from __future__ import annotations

from . import lakehouse, masterdata
from .lakehouse import AnalysisNotFound

TOTALS = ("OPEX", "HOROP", "TONMOV", "USD_H", "USD_T")
_METRIC_FIELDS = ("current", "previous", "baseline", "delta_previous", "delta_previous_pct",
                  "delta_baseline", "delta_baseline_pct", "share_pct")


def cost_centers() -> dict:
    centers = [{**c, "texts": masterdata.texts(masterdata.COST_CENTERS, c["rcntr"]),
                "category_texts": {cat: masterdata.texts(masterdata.PLAN_CATEGORIES, cat) for cat in c["categories"]}}
               for c in lakehouse.cost_centers()]
    default = next((c["rcntr"] for c in centers if c["last_actual"]), centers[0]["rcntr"] if centers else None)
    return {"cost_centers": centers, "default": default}


def scope(rcntr: str | None, category: str | None) -> tuple[str, str]:
    """Requested (or default) cost center and plan category; the latest category when none is given."""
    centers = lakehouse.cost_centers()
    if rcntr:
        center = next((c for c in centers if c["rcntr"] == rcntr), None)
    else:
        center = next((c for c in centers if c["last_actual"]), centers[0] if centers else None)
    if center is None or (category and category not in center["categories"]):
        raise AnalysisNotFound(rcntr or "-")
    return center["rcntr"], category or (center["categories"][-1] if center["categories"] else "")


def analyze(rcntr: str, category: str, period: str | None = None) -> dict:
    """Deviation of the analyzed actual month (default: the latest) and the plan horizon after it."""
    rows = lakehouse.variance(rcntr, category, period)
    if not rows:
        raise AnalysisNotFound(f"{rcntr} {period or ''}".strip())
    metrics = {row["metric"]: {field: row[field] for field in _METRIC_FIELDS} for row in rows}
    head = rows[0]
    return {
        "rcntr": rcntr,
        "rcntr_texts": masterdata.texts(masterdata.COST_CENTERS, rcntr),
        "currency": lakehouse.GROUP_CURRENCY,
        "category": category,
        "category_texts": masterdata.texts(masterdata.PLAN_CATEGORIES, category),
        "period": head["period"],
        "previous_period": head["previous_period"],
        "baseline": {"months": head["baseline_months"], "from": head["baseline_from"], "to": head["baseline_to"]},
        "totals": {key: metrics[key] for key in TOTALS if key in metrics},
        "accounts": [{"racct": key, "texts": masterdata.texts(masterdata.ACCOUNTS, key), **values}
                     for key, values in metrics.items() if key not in TOTALS],
        "top_postings": lakehouse.top_postings(rcntr, head["period"]),
        "forecast": lakehouse.forecast(rcntr, category, head["period"]),
    }


def timeline(rcntr: str, category: str) -> dict:
    """Continuous monthly series for the chart: actual months followed by the plan months."""
    periods: dict[str, dict] = {}
    for row in lakehouse.timeline(rcntr, category):
        month = periods.setdefault(row["period"], {
            "period": row["period"], "kind": row["kind"], "opex": row["opex"], "hours": row["hours"],
            "tonnes": row["tonnes"], "usd_per_hour": row["usd_per_hour"], "usd_per_tonne": row["usd_per_tonne"],
            "accounts": {}})
        month["accounts"][row["racct"]] = row["ksl"]
    accounts = sorted({racct for month in periods.values() for racct in month["accounts"]})
    has_actuals = any(month["kind"] == "actual" for month in periods.values())
    return {
        "rcntr": rcntr,
        "rcntr_texts": masterdata.texts(masterdata.COST_CENTERS, rcntr),
        "currency": lakehouse.GROUP_CURRENCY,
        "category": category,
        "category_texts": masterdata.texts(masterdata.PLAN_CATEGORIES, category),
        "periods": list(periods.values()),
        "accounts": [{"racct": racct, "texts": masterdata.texts(masterdata.ACCOUNTS, racct)} for racct in accounts],
        "summary": analyze(rcntr, category) if has_actuals else None,
    }
