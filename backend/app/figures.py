"""Figures guard: the LLM explains, Trino calculates. Every number in an answer must come from the
context the model received (Trino results, logs, question). Quoting a context figure rounded, in
either number format (1.980.000 / 1,980,000 · 550,65 / 550.65) or with a scale word (millones,
millions, milhões, mil, M, k) is accepted, also with space-like thousands separators (4 207 000);
any other number is reported as not grounded."""
from __future__ import annotations

import re
from decimal import Decimal, InvalidOperation

SPACES = " \u00a0\u202f\u2009"  # space, no-break, narrow no-break and thin space used as group separators
NUMBER = re.compile(
    rf"(?<![\w])(\d{{1,3}}(?:[{SPACES}]\d{{3}})+(?:[.,]\d+)?(?!\d)|\d+(?:[.,]\d+)*)"
    r"(?:\s?(millones|millón|millon|millions?|milhões|milhão|mil|thousand|MM|M|k))?(?![\w])")
SCALES = {"millones": 6, "millón": 6, "millon": 6, "million": 6, "millions": 6, "milhões": 6, "milhão": 6,
          "mm": 6, "m": 6, "mil": 3, "thousand": 3, "k": 3}
SMALL_INTEGER = 31           # list numbering, days, counts ("3 camiones", "18 meses"); never a %
YEARS = range(2000, 2101)


def _readings(token: str) -> list[tuple[Decimal, int]]:
    """Possible (value, decimals) of a number written with '.' or ',' as decimal or group separator."""
    token = token.translate({ord(c): None for c in SPACES})

    def read(group: str | None, mark: str | None) -> list[tuple[Decimal, int]]:
        text = token.replace(group, "") if group else token
        decimals = len(text.rsplit(mark, 1)[1]) if mark and mark in text else 0
        try:
            return [(Decimal(text.replace(mark, ".") if mark else text), decimals)]
        except InvalidOperation:
            return []

    dots, commas = token.count("."), token.count(",")
    if not dots and not commas:
        return read(None, None)
    if dots and commas:  # the last separator is the decimal mark
        mark = "." if token.rfind(".") > token.rfind(",") else ","
        return read("," if mark == "." else ".", mark)
    separator = "." if dots else ","
    groups = token.split(separator)
    if len(groups) > 2:  # 1.980.000 / 1,980,000
        return read(separator, None) if all(len(g) == 3 for g in groups[1:]) else []
    readings = read(None, separator)
    if len(groups[1]) == 3:  # 1.980 is ambiguous: 1980 or 1.98
        readings += read(separator, None)
    return readings


def _values(text: str) -> list[Decimal]:
    return [value for match in NUMBER.finditer(text) for value, _ in _readings(match.group(1))]


def check(answer: str, context: str) -> dict:
    """{checked, grounded, ungrounded: [numbers as written]} for the numbers quoted in the answer."""
    known = {abs(v) for v in _values(context)}
    checked, ungrounded = 0, []
    for match in NUMBER.finditer(answer):
        token, scale_word = match.group(1), match.group(2)
        readings = _readings(token)
        if not readings:
            continue
        checked += 1
        percentage = answer[match.end():].lstrip().startswith("%")
        if (not scale_word and not percentage and token.isdigit()
                and (int(token) <= SMALL_INTEGER or int(token) in YEARS)):
            continue
        exponent = SCALES.get(scale_word.lower(), 0) if scale_word else 0
        if not any(abs(c - value.scaleb(exponent)) <= Decimal(5).scaleb(exponent - decimals - 1)
                   for value, decimals in readings for c in known):
            ungrounded.append(match.group(0))
    return {"checked": checked, "grounded": checked - len(ungrounded), "ungrounded": ungrounded}
