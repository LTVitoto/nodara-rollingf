"""OPEX C1 views composed from the Trino results (lakehouse.py): the cost centers of the value chain, the
monthly timeline (actuals against the budget + plan) for the chart, the P x Q matrix of every cost center
and the per-account variance analysis the AI explains. No arithmetic happens here: every figure arrives
computed by Trino."""
from __future__ import annotations

import logging

from . import lakehouse, masterdata
from .lakehouse import AnalysisNotFound

log = logging.getLogger(__name__)

_LINE_FIELDS = ("behavior", "actual_ksl", "budget_ksl", "flex_ksl", "variance", "variance_pct", "actual_msl",
                "budget_msl", "flex_msl", "actual_price", "budget_price", "price_pct", "actual_sc", "budget_sc",
                "sc_pct", "price_effect", "efficiency_effect", "volume_effect", "spending_effect")


def _area(rcntr: str) -> dict:
    area = masterdata.COST_CENTER_AREAS.get(rcntr, "")
    return {"area": area, "area_texts": masterdata.texts(masterdata.AREAS, area)}


def _driver(stagr: str | None, runit: str | None) -> dict:
    return {"stagr": stagr, "runit": runit, "symbol": masterdata.symbol(runit),
            "texts": masterdata.texts(masterdata.STATISTICAL_KEY_FIGURES, stagr or "-"),
            "decimals": masterdata.UNIT_COST_DECIMALS.get(stagr or "", 4)}


def _line(row: dict) -> dict:
    return {"racct": row["racct"], "texts": masterdata.texts(masterdata.ACCOUNTS, row["racct"]), "ruom": row["ruom"],
            "symbol": masterdata.symbol(row["ruom"]), **{field: row[field] for field in _LINE_FIELDS}}


def cost_centers() -> dict:
    """Cost centers of the lakehouse in value-chain order; the default is the first one with actuals."""
    centers = sorted(lakehouse.cost_centers(), key=lambda c: (masterdata.order(c["rcntr"]), c["rcntr"]))
    centers = [{**c, **_area(c["rcntr"]), "texts": masterdata.texts(masterdata.COST_CENTERS, c["rcntr"]),
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


def analyze(rcntr: str, category: str, period: str | None = None) -> dict:
    """P x Q deviation of the analyzed actual month (default: the latest) against the base budget, per
    account, with the ranked unfavorable effects (origin of the deviation) and the plan horizon after it."""
    rows = lakehouse.variance(rcntr, period)
    if not rows:
        raise AnalysisNotFound(f"{rcntr} {period or ''}".strip())
    head = rows[0]
    lines: dict[str, dict] = {}
    for row in rows:
        lines.setdefault(row["racct"], _line(row))
    origins = [{"racct": row["racct"], "texts": masterdata.texts(masterdata.ACCOUNTS, row["racct"]),
                "effect": row["effect"], "amount": row["amount"]}
               for row in sorted(rows, key=lambda r: r["effect_rank"])
               if row["effect_rank"] <= lakehouse.TOP_EFFECTS and row["amount"] is not None and row["amount"] > 0]
    return {
        "rcntr": rcntr,
        "rcntr_texts": masterdata.texts(masterdata.COST_CENTERS, rcntr),
        **_area(rcntr),
        "currency": lakehouse.GROUP_CURRENCY,
        "category": category,
        "category_texts": masterdata.texts(masterdata.PLAN_CATEGORIES, category),
        "budget_category": lakehouse.BUDGET_CATEGORY,
        "budget_texts": masterdata.texts(masterdata.PLAN_CATEGORIES, lakehouse.BUDGET_CATEGORY),
        "period": head["period"],
        "driver": {**_driver(head["stagr"], head["driver_unit"]), "actual": head["actual_driver"],
                   "budget": head["budget_driver"], "delta_pct": head["driver_pct"]},
        "opex": {"actual": head["opex_actual"], "budget": head["opex_budget"], "flex": head["opex_flex"],
                 "variance": head["opex_variance"], "variance_pct": head["opex_variance_pct"]},
        "unit_cost": {"actual": head["unit_actual"], "budget": head["unit_budget"], "delta_pct": head["unit_pct"]},
        "effects": {"price": head["total_price"], "efficiency": head["total_efficiency"],
                    "volume": head["total_volume"], "spending": head["total_spending"]},
        "origins": origins,
        "lines": list(lines.values()),
        "top_postings": lakehouse.top_postings(rcntr, head["period"]),
        "forecast": lakehouse.forecast(rcntr, category, head["period"]) if category else {"months": 0},
    }


def timeline(rcntr: str, category: str) -> dict:
    """Continuous monthly series for the chart: actual months (with their budget) followed by the plan."""
    periods: dict[str, dict] = {}
    driver = None
    for row in lakehouse.timeline(rcntr, category):
        month = periods.setdefault(row["period"], {
            "period": row["period"], "kind": "actual" if row["kind"] == lakehouse.ACTUAL else "plan",
            "opex": row["opex"], "driver_qty": row["driver_qty"], "unit_cost": row["unit_cost"], "accounts": {},
            "budget": None if row["budget_opex"] is None else {
                "opex": row["budget_opex"], "driver_qty": row["budget_driver"], "unit_cost": row["budget_unit_cost"],
                "delta_pct": row["opex_delta_budget_pct"], "unit_delta_pct": row["unit_delta_budget_pct"],
                "accounts": {}}})
        month["accounts"][row["racct"]] = row["ksl"]
        if month["budget"] is not None and row["budget_ksl"] is not None:
            month["budget"]["accounts"][row["racct"]] = row["budget_ksl"]
        if driver is None and row["stagr"]:
            driver = _driver(row["stagr"], row["driver_unit"])
    accounts = sorted({racct for month in periods.values() for racct in month["accounts"]})
    has_actuals = any(month["kind"] == "actual" for month in periods.values())
    return {
        "rcntr": rcntr,
        "rcntr_texts": masterdata.texts(masterdata.COST_CENTERS, rcntr),
        **_area(rcntr),
        "currency": lakehouse.GROUP_CURRENCY,
        "category": category,
        "category_texts": masterdata.texts(masterdata.PLAN_CATEGORIES, category),
        "budget_category": lakehouse.BUDGET_CATEGORY,
        "periods": list(periods.values()),
        "accounts": [{"racct": racct, "texts": masterdata.texts(masterdata.ACCOUNTS, racct)} for racct in accounts],
        "driver": driver,
        "summary": analyze(rcntr, category) if has_actuals else None,
    }


def matrix(period: str | None = None) -> dict:
    """OPEX C1 matrix: the value-chain areas, their cost centers (totals, driver, unit OPEX and origin of the
    deviation) and the P x Q lines of every cost center, for the latest actual month."""
    centers: dict[str, dict] = {}
    rows = lakehouse.matrix(period)
    for row in rows:
        center = centers.setdefault(row["rcntr"], {
            "rcntr": row["rcntr"], "texts": masterdata.texts(masterdata.COST_CENTERS, row["rcntr"]), **_area(row["rcntr"]),
            "driver": {**_driver(row["stagr"], row["driver_unit"]), "actual": row["actual_driver"],
                       "budget": row["budget_driver"], "delta_pct": row["driver_pct"]},
            "opex": {"actual": row["opex_actual"], "budget": row["opex_budget"], "variance": row["opex_variance"],
                     "variance_pct": row["opex_variance_pct"]},
            "unit_cost": {"actual": row["unit_actual"], "budget": row["unit_budget"], "delta_pct": row["unit_pct"]},
            "origin": None if row["origin_racct"] is None else {
                "racct": row["origin_racct"], "texts": masterdata.texts(masterdata.ACCOUNTS, row["origin_racct"]),
                "effect": row["origin_effect"], "amount": row["origin_amount"]},
            "lines": []})
        center["lines"].append(_line(row))
    areas: dict[str, dict] = {}
    for center in sorted(centers.values(), key=lambda c: masterdata.order(c["rcntr"])):
        areas.setdefault(center["area"], {"area": center["area"], "texts": center["area_texts"],
                                          "cost_centers": []})["cost_centers"].append(center)
    return {"period": rows[0]["period"] if rows else None, "currency": lakehouse.GROUP_CURRENCY,
            "budget_category": lakehouse.BUDGET_CATEGORY, "areas": list(areas.values())}


def warm_up() -> None:
    """Fills the in-memory cache of the lakehouse (backend start): the matrix and every cost center timeline
    with its analysis, so the first questions skip the Trino computation."""
    try:
        matrix()
        for center in cost_centers()["cost_centers"]:
            if center["last_actual"] and center["categories"]:
                timeline(center["rcntr"], center["categories"][-1])
        log.info("lakehouse cache warmed up: %s", lakehouse.cache_stats())
    except Exception as exc:  # warm-up is an optimization: the first requests compute instead
        log.warning("lakehouse cache warm-up skipped: %s", exc)
