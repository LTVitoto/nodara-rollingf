"""SAP master data outside the simulated table scope — texts of SKAT (G/L accounts), TKA03 (statistical
key figures), T006A (units), CSKT (cost centers) and the plan categories of ACDOCP in the three supported
languages — plus the structure of the OPEX C1 value chain (area of each cost center) and display decimals.
The statistical key figure each cost center is reported against is part of the gold view definition
(lakehouse/trino/gold)."""
from __future__ import annotations

ACCOUNTS = {
    "ACEROS": {"es": "Aceros de perforación (brocas)", "en": "Drilling steels (bits)",
                     "pt": "Aços de perfuração (brocas)"},
    "DIESEL": {"es": "Diésel", "en": "Diesel fuel", "pt": "Diesel"},
    "LABOR": {"es": "Mano de obra (horas hombre)", "en": "Labor (man-hours)", "pt": "Mão de obra (homem-hora)"},
    "MANTEN": {"es": "Mantención contratada", "en": "Contracted maintenance", "pt": "Manutenção contratada"},
    "DEPREC": {"es": "Depreciación", "en": "Depreciation", "pt": "Depreciação"},
    "EXPLOSIV": {"es": "Explosivos", "en": "Explosives", "pt": "Explosivos"},
    "ACCESOR": {"es": "Accesorios de voladura", "en": "Blasting accessories", "pt": "Acessórios de detonação"},
    "SERVIC": {"es": "Servicio de tronadura", "en": "Blasting service", "pt": "Serviço de detonação"},
    "ENERGIA": {"es": "Energía eléctrica", "en": "Electric power", "pt": "Energia elétrica"},
    "REPUEST": {"es": "Repuestos", "en": "Spare parts", "pt": "Peças de reposição"},
    "NEUMAT": {"es": "Neumáticos", "en": "Tyres", "pt": "Pneus"},
    "BOLAS": {"es": "Bolas de molienda", "en": "Grinding balls", "pt": "Bolas de moagem"},
    "REVEST": {"es": "Revestimientos de molinos", "en": "Mill liners", "pt": "Revestimentos de moinhos"},
    "REACTIVOS": {"es": "Reactivos (colector xantato)", "en": "Reagents (xanthate collector)",
                        "pt": "Reagentes (coletor xantato)"},
    "CAL": {"es": "Cal", "en": "Lime", "pt": "Cal"},
    "FLOCUL": {"es": "Floculante", "en": "Flocculant", "pt": "Floculante"},
    "AGUA": {"es": "Agua industrial", "en": "Industrial water", "pt": "Água industrial"},
    "ACIDO": {"es": "Ácido sulfúrico", "en": "Sulfuric acid", "pt": "Ácido sulfúrico"},
    "EXTRACT": {"es": "Extractante orgánico", "en": "Organic extractant", "pt": "Extratante orgânico"},
    "DILUY": {"es": "Diluyente", "en": "Diluent", "pt": "Diluente"},
    "ADITIVOS": {"es": "Aditivos de electrolito", "en": "Electrolyte additives", "pt": "Aditivos de eletrólito"},
    "ANODOS": {"es": "Ánodos de plomo", "en": "Lead anodes", "pt": "Ânodos de chumbo"},
    "TELAS": {"es": "Telas filtrantes", "en": "Filter cloths", "pt": "Telas filtrantes"},
    "ALMAC": {"es": "Almacenamiento de concentrado", "en": "Concentrate storage",
                    "pt": "Armazenagem de concentrado"},
}
STATISTICAL_KEY_FIGURES = {
    "METPER": {"es": "Metros perforados", "en": "Meters drilled", "pt": "Metros perfurados"},
    "TONTRO": {"es": "Toneladas tronadas", "en": "Tonnes blasted", "pt": "Toneladas detonadas"},
    "TONCAR": {"es": "Toneladas cargadas", "en": "Tonnes loaded", "pt": "Toneladas carregadas"},
    "TONMOV": {"es": "Toneladas transportadas", "en": "Tonnes hauled", "pt": "Toneladas transportadas"},
    "TONMOL": {"es": "Toneladas molidas", "en": "Tonnes milled", "pt": "Toneladas moídas"},
    "TONFLO": {"es": "Toneladas flotadas", "en": "Tonnes floated", "pt": "Toneladas flotadas"},
    "TONREL": {"es": "Toneladas de relave", "en": "Tailings tonnes", "pt": "Toneladas de rejeito"},
    "TONAPI": {"es": "Toneladas bajo riego", "en": "Tonnes under irrigation", "pt": "Toneladas sob irrigação"},
    "M3PLS": {"es": "m³ de PLS tratados", "en": "PLS treated (m³)", "pt": "m³ de PLS tratados"},
    "TONCAT": {"es": "Toneladas de cátodo", "en": "Cathode tonnes", "pt": "Toneladas de catodo"},
    "TONFIL": {"es": "Toneladas filtradas", "en": "Tonnes filtered", "pt": "Toneladas filtradas"},
    "TONEMB": {"es": "Toneladas embarcadas", "en": "Tonnes shipped", "pt": "Toneladas embarcadas"},
}
# Internal unit of measure → external symbol (language neutral).
UNITS = {"M": "m", "TO": "t", "M3": "m³", "WMT": "WMT", "PC": "PC", "L": "L", "KG": "kg", "HR": "h", "KWH": "kWh"}
AREAS = {
    "MINA": {"es": "Mina", "en": "Mine", "pt": "Mina"},
    "CONCENTRADORA": {"es": "Concentradora", "en": "Concentrator", "pt": "Concentrador"},
    "LIXIVIACION": {"es": "Lixiviación", "en": "Leaching", "pt": "Lixiviação"},
    "PUERTO": {"es": "Puerto", "en": "Port", "pt": "Porto"},
}
# Value-chain order of the OPEX C1: the order of the selector and of the matrix.
COST_CENTERS = {
    "MIN_PERF": {"es": "Perforación", "en": "Drilling", "pt": "Perfuração"},
    "MIN_TRON": {"es": "Tronadura", "en": "Blasting", "pt": "Detonação"},
    "MIN_CARG": {"es": "Carguío", "en": "Loading", "pt": "Carregamento"},
    "MIN_TRAN": {"es": "Transporte", "en": "Hauling", "pt": "Transporte"},
    "CON_MOLI": {"es": "Molienda", "en": "Grinding", "pt": "Moagem"},
    "CON_FLOT": {"es": "Flotación", "en": "Flotation", "pt": "Flotação"},
    "CON_RELA": {"es": "Relaves", "en": "Tailings", "pt": "Rejeitos"},
    "LIX_RIEG": {"es": "Riego de pilas", "en": "Heap irrigation", "pt": "Irrigação de pilhas"},
    "LIX_SX": {"es": "Extracción por solventes", "en": "Solvent extraction", "pt": "Extração por solventes"},
    "LIX_EW": {"es": "Electro-obtención", "en": "Electrowinning", "pt": "Eletro-obtenção"},
    "PTO_FILT": {"es": "Filtrado de concentrado", "en": "Concentrate filtering",
                       "pt": "Filtragem de concentrado"},
    "PTO_EMBA": {"es": "Embarque", "en": "Shipping", "pt": "Embarque"},
}
COST_CENTER_AREAS = {
    "MIN_PERF": "MINA", "MIN_TRON": "MINA", "MIN_CARG": "MINA", "MIN_TRAN": "MINA",
    "CON_MOLI": "CONCENTRADORA", "CON_FLOT": "CONCENTRADORA", "CON_RELA": "CONCENTRADORA",
    "LIX_RIEG": "LIXIVIACION", "LIX_SX": "LIXIVIACION", "LIX_EW": "LIXIVIACION",
    "PTO_FILT": "PUERTO", "PTO_EMBA": "PUERTO",
}
# Display decimals of the unit OPEX (USD per driver unit): 2 for meters and cathode tonnes, 4 otherwise.
UNIT_COST_DECIMALS = {"METPER": 2, "TONCAT": 2}
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


def symbol(unit: str | None) -> str:
    """External symbol of an internal unit; lines without quantity are amounts in USD."""
    return UNITS.get(unit or "", unit) if unit else "USD"
