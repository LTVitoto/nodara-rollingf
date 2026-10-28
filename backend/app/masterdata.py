"""SAP master-data texts outside the simulated table scope — SKAT (G/L accounts), TKA03 (statistical
key figures), CSKT (cost centers) and the plan categories of ACDOCP — in the three supported languages."""
from __future__ import annotations

ACCOUNTS = {
    "0061100100": {"es": "Repuestos y componentes", "en": "Spare parts and components", "pt": "Peças e componentes"},
    "0061100200": {"es": "Combustible diésel", "en": "Diesel fuel", "pt": "Combustível diesel"},
    "0061100300": {"es": "Neumáticos", "en": "Tyres", "pt": "Pneus"},
    "0062100100": {"es": "Servicios de mantención", "en": "Maintenance services", "pt": "Serviços de manutenção"},
    "0063100100": {"es": "Remuneraciones", "en": "Payroll", "pt": "Folha de pagamento"},
}
STATISTICAL_KEY_FIGURES = {
    "HOROP": {"es": "Horas operativas", "en": "Operating hours", "pt": "Horas operacionais"},
    "TONMOV": {"es": "Toneladas movidas", "en": "Tonnes hauled", "pt": "Toneladas movimentadas"},
}
COST_CENTERS = {
    "RCNTR_MINA_CAEX": {"es": "Mina · Flota CAEX", "en": "Mine · CAEX haul fleet", "pt": "Mina · Frota CAEX"},
}
PLAN_CATEGORIES = {
    "RF18M": {"es": "Rolling Forecast 18 meses (SAC)", "en": "18-month rolling forecast (SAC)",
              "pt": "Rolling Forecast 18 meses (SAC)"},
}


def texts(table: dict[str, dict[str, str]], key: str) -> dict[str, str]:
    """Texts of a master-data key; an unknown key (not yet in the text table) is shown as is."""
    return table.get(key) or {"es": key, "en": key, "pt": key}
