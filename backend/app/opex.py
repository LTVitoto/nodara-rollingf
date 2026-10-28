"""Rolling forecast views composed from the Trino results (lakehouse.py): cost center scope, the
monthly timeline (actuals against the budget + plan) for the chart, and the variance analysis the AI
explains. No arithmetic happens here: every figure arrives computed by Trino."""
from __future__ import annotations

from . import lakehouse, masterdata
from .lakehouse import AnalysisNotFound

_METRIC_FIELDS = ("current", "budget", "previous", "delta_budget", "delta_budget_pct", "delta_previous",
                  "delta_previous_pct", "share_pct")


def cost_centers() -> dict:
    """Cost centers of the lakehouse in value-chain order; the default is the first one with actuals."""
    centers = sorted(lakehouse.cost_centers(), key=lambda c: (masterdata.order(c["rcntr"]), c["rcntr"]))
    centers = [{**c, "texts": masterdata.texts(masterdata.COST_CENTERS, c["rcntr"]),
                "category_texts": {cat: masterdata.texts(masterdata.PLAN_CATEGORIES, cat) for cat in c["categories"]}}
               for c in centers]
    default = next((c["rcntr"] for c in centers if c["last_actual"]), centers[0]["rcntr"] if centers else None)
    return {"cost_centers": centers, "default": default}


def scope(rcntr: str | None, category: str | None) -> tuple[str, str]:
    """Requested (or default) cost center and plan category; the latest category when none is given."""
    centers = cost_centers()
    rcntr = rcntr or centers["default"]
    center = next((c for c in centers["cost_centers"] if c["rcntr"] == rcntr), None)
    if center is None or (category and category not in center["categories"]):
        raise AnalysisNotFound(rcntr or "-")
    return center["rcntr"], category or (center["categories"][-1] if center["categories"] else "")


def _driver(stagr: str, runit: str | None) -> dict:
    return {"stagr": stagr, "runit": runit, "symbol": masterdata.UNITS.get(runit or "", runit),
            "texts": masterdata.texts(masterdata.STATISTICAL_KEY_FIGURES, stagr)}


def _values(row: dict) -> dict:
    return {field: row[field] for field in _METRIC_FIELDS}


def _primary_first(items: list[dict], driver: str | None) -> list[dict]:
    return sorted(items, key=lambda item: (item["stagr"] != driver, item["stagr"]))


def unit_driver(rcntr: str, available: list[str]) -> str | None:
    """Statistical key figure the unit OPEX of the cost center is reported against."""
    configured = masterdata.UNIT_DRIVERS.get(rcntr)
    return configured if configured in available else (sorted(available)[0] if available else None)


def analyze(rcntr: str, category: str, period: str | None = None) -> dict:
    """Deviation of the analyzed actual month (default: the latest) against the base budget, with the
    previous month as context, and the plan horizon after it."""
    rows = lakehouse.variance(rcntr, period)
    if not rows:
        raise AnalysisNotFound(f"{rcntr} {period or ''}".strip())
    head = rows[0]
    driver = unit_driver(rcntr, [row["metric"] for row in rows if row["kind"] == "driver"])
    return {
        "rcntr": rcntr,
        "rcntr_texts": masterdata.texts(masterdata.COST_CENTERS, rcntr),
        "currency": lakehouse.GROUP_CURRENCY,
        "category": category,
        "category_texts": masterdata.texts(masterdata.PLAN_CATEGORIES, category),
        "budget_category": lakehouse.BUDGET_CATEGORY,
        "budget_texts": masterdata.texts(masterdata.PLAN_CATEGORIES, lakehouse.BUDGET_CATEGORY),
        "period": head["period"],
        "previous_period": head["previous_period"],
        "driver": driver,
        "opex": next((_values(row) for row in rows if row["kind"] == "opex"), None),
        "drivers": _primary_first([{**_driver(row["metric"], row["runit"]), **_values(row)}
                                   for row in rows if row["kind"] == "driver"], driver),
        "unit_costs": _primary_first([{**_driver(row["metric"], row["runit"]), "decimals": row["decimals"],
                                       **_values(row)} for row in rows if row["kind"] == "unit"], driver),
        "accounts": [{"racct": row["metric"], "texts": masterdata.texts(masterdata.ACCOUNTS, row["metric"]),
                      **_values(row)} for row in rows if row["kind"] == "account"],
        "top_postings": lakehouse.top_postings(rcntr, head["period"]),
        "forecast": lakehouse.forecast(rcntr, category, head["period"], driver) if driver and category
                    else {"months": 0},
    }


def timeline(rcntr: str, category: str) -> dict:
    """Continuous monthly series for the chart: actual months (with their budget) followed by the plan."""
    periods: dict[str, dict] = {}
    drivers: dict[str, dict] = {}
    for row in lakehouse.timeline(rcntr, category):
        month = periods.setdefault(row["period"], {
            "period": row["period"], "kind": row["kind"], "opex": row["opex"], "accounts": {}, "drivers": {},
            "budget": None if row["budget_opex"] is None else {
                "opex": row["budget_opex"], "delta": row["opex_delta_budget"],
                "delta_pct": row["opex_delta_budget_pct"], "accounts": {}, "drivers": {}}})
        budget = month["budget"]
        if row["item"] == "account":
            month["accounts"][row["key"]] = row["value"]
            if budget is not None and row["budget_value"] is not None:
                budget["accounts"][row["key"]] = row["budget_value"]
            continue
        month["drivers"][row["key"]] = {"quantity": row["value"], "unit_cost": row["unit_cost"]}
        if budget is not None and row["budget_value"] is not None:
            budget["drivers"][row["key"]] = {"quantity": row["budget_value"], "unit_cost": row["budget_unit_cost"],
                                             "unit_delta_pct": row["unit_delta_budget_pct"]}
        drivers.setdefault(row["key"], {**_driver(row["key"], row["runit"]), "decimals": row["decimals"]})
    accounts = sorted({racct for month in periods.values() for racct in month["accounts"]})
    driver = unit_driver(rcntr, list(drivers))
    has_actuals = any(month["kind"] == "actual" for month in periods.values())
    return {
        "rcntr": rcntr,
        "rcntr_texts": masterdata.texts(masterdata.COST_CENTERS, rcntr),
        "currency": lakehouse.GROUP_CURRENCY,
        "category": category,
        "category_texts": masterdata.texts(masterdata.PLAN_CATEGORIES, category),
        "budget_category": lakehouse.BUDGET_CATEGORY,
        "periods": list(periods.values()),
        "accounts": [{"racct": racct, "texts": masterdata.texts(masterdata.ACCOUNTS, racct)} for racct in accounts],
        "drivers": _primary_first(list(drivers.values()), driver),
        "driver": driver,
        "summary": analyze(rcntr, category) if has_actuals else None,
    }
