"""SAP master data outside the simulated table scope — texts of SKAT (G/L accounts), TKA03 (statistical
key figures), T006A (units), CSKT (cost centers) and the plan categories of ACDOCP in the three supported
languages — plus the unit-cost driver of each cost center: the statistical key figure its unit OPEX is
reported against."""
from __future__ import annotations

ACCOUNTS = {
    "0061100100": {"es": "Repuestos y componentes", "en": "Spare parts and components", "pt": "Peças e componentes"},
    "0061100200": {"es": "Combustible diésel", "en": "Diesel fuel", "pt": "Combustível diesel"},
    "0061100300": {"es": "Neumáticos", "en": "Tyres", "pt": "Pneus"},
    "0061100400": {"es": "Reactivos de proceso", "en": "Process reagents", "pt": "Reagentes de processo"},
    "0062100100": {"es": "Servicios de mantención", "en": "Maintenance services", "pt": "Serviços de manutenção"},
    "0062100200": {"es": "Almacenamiento", "en": "Storage", "pt": "Armazenagem"},
    "0062100300": {"es": "Energía eléctrica", "en": "Electric power", "pt": "Energia elétrica"},
    "0063100100": {"es": "Remuneraciones", "en": "Payroll", "pt": "Folha de pagamento"},
}
STATISTICAL_KEY_FIGURES = {
    "HOROP": {"es": "Horas operativas", "en": "Operating hours", "pt": "Horas operacionais"},
    "TONMOV": {"es": "Toneladas movidas", "en": "Tonnes moved", "pt": "Toneladas movimentadas"},
    "TONAPI": {"es": "Toneladas apiladas", "en": "Tonnes stacked", "pt": "Toneladas empilhadas"},
    "TONPRO": {"es": "Toneladas procesadas", "en": "Tonnes processed", "pt": "Toneladas processadas"},
    "TONEMB": {"es": "Toneladas embarcadas", "en": "Tonnes shipped", "pt": "Toneladas embarcadas"},
}
UNITS = {"H": "h", "TO": "t", "WMT": "WMT"}  # internal unit of measure → external symbol
# Value-chain order of the C1 OPEX: the order of the cost center selector.
COST_CENTERS = {
    "RCNTR_MINA_CAEX": {"es": "Mina · Flota CAEX", "en": "Mine · CAEX haul fleet", "pt": "Mina · Frota CAEX"},
    "RCNTR_MINA_TRUCK": {"es": "Mina · Extracción", "en": "Mine · Extraction", "pt": "Mina · Extração"},
    "RCNTR_LIXIV_SXEW": {"es": "Planta de Lixiviación SX-EW", "en": "SX-EW leaching plant",
                         "pt": "Planta de lixiviação SX-EW"},
    "RCNTR_CONCEN_FLOT": {"es": "Planta Concentradora · Flotación", "en": "Concentrator · Flotation",
                          "pt": "Concentrador · Flotação"},
    "RCNTR_PUERTO_EMB": {"es": "Puerto · Embarque", "en": "Port · Shipping", "pt": "Porto · Embarque"},
}
UNIT_DRIVERS = {
    "RCNTR_MINA_CAEX": "HOROP",
    "RCNTR_MINA_TRUCK": "TONMOV",
    "RCNTR_LIXIV_SXEW": "TONAPI",
    "RCNTR_CONCEN_FLOT": "TONPRO",
    "RCNTR_PUERTO_EMB": "TONEMB",
}
PLAN_CATEGORIES = {
    "BUDG": {"es": "Presupuesto base (SAC)", "en": "Base budget (SAC)", "pt": "Orçamento base (SAC)"},
    "RF18M": {"es": "Rolling Forecast 18 meses (SAC)", "en": "18-month rolling forecast (SAC)",
              "pt": "Rolling Forecast 18 meses (SAC)"},
}


def texts(table: dict[str, dict[str, str]], key: str) -> dict[str, str]:
    """Texts of a master-data key; an unknown key (not yet in the text table) is shown as is."""
    return table.get(key) or {"es": key, "en": key, "pt": key}


def order(rcntr: str) -> int:
    """Position of a cost center in the value chain (unknown ones go last)."""
    return list(COST_CENTERS).index(rcntr) if rcntr in COST_CENTERS else len(COST_CENTERS)
