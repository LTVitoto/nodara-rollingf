// UI regression test against the live frontend + backend (real lakehouse data, mocked /api/ask):
// language selector (ES / EN / PT) with server-side persistence, the 12 cost centers of the OPEX C1 value
// chain grouped by area, continuous chart (6 actual months with their BUDG budget tick + 18 plan months) with
// keyboard tooltip, measure toggle (OPEX ↔ unit OPEX of the driver) and table view, KPI tiles against the
// budget, the expandable P x Q matrix (specific consumption per input, origin of the deviation, zero driver
// shown as not computable), the AI chat carrying language + engine + cost center, and the RCNTR scope of a log
// (domino effect: the SAG mill log also explains tailings).
// Runs in the Playwright image:  make ui-test
const { chromium } = require("playwright-core");

const BASE_URL = process.env.BASE_URL ?? "http://frontend:3000";
const RCNTR = "MIN_PERF";
const PORT = "PTO_EMBA";
const FLOTATION = "CON_FLOT";
const DOMINO = { rcntr: "CON_RELA", log: "BIT-MOLI-2026-10", scope: ["CON_MOLI", "CON_RELA", "PTO_FILT"] };
const VALUE_CHAIN = ["MIN_PERF", "MIN_TRON", "MIN_CARG", "MIN_TRAN", "CON_MOLI",
                     FLOTATION, "CON_RELA", "LIX_RIEG", "LIX_SX", "LIX_EW", "PTO_FILT", PORT];
const EXPECTED = {
  es: { lang: "es", name: "Español", h1: "Rolling Forecast de OPEX C1 · 18 meses", label: "Pregunta del Gerente de Finanzas", logs: "Bitácoras",
        tooltip: "oct 26", table: "Ver tabla", scope: "Alcance",
        meta: ["Cifras verificadas contra Trino", "Idioma de la respuesta", "Tiempo total", "Motor"] },
  en: { lang: "en", name: "English", h1: "C1 OPEX Rolling Forecast · 18 months", label: "Finance Manager question", logs: "Logs",
        tooltip: "Oct 26", table: "Show table", scope: "Scope",
        meta: ["Figures checked against Trino", "Answer language", "Total time", "Engine"] },
  pt: { lang: "pt-BR", name: "Português", h1: "Rolling Forecast de OPEX C1 · 18 meses", label: "Pergunta do Gerente Financeiro", logs: "Diários",
        tooltip: "out. de 26", table: "Ver tabela", scope: "Alcance",
        meta: ["Números conferidos com Trino", "Idioma da resposta", "Tempo total", "Motor"] },
};
const ENGINES = { nim: "NVIDIA NIM (Cloud)", ollama: "Ollama (Local)" };

function mockAnswer(body) {
  const nim = body.engine === "nim";
  const x = { es: "x", en: "x", pt: "x" };
  const driver = { stagr: "TONFLO", runit: "TO", symbol: "t", texts: x, decimals: 4, actual: 1, budget: 1, delta_pct: 0 };
  return {
    answer: "mock answer", language: String(body.language).toLowerCase(),
    language_check: { requested: "es", detected: "es", status: "ok" },
    figures_check: { checked: 3, grounded: 3, ungrounded: [] },
    engine: body.engine, model_used: nim ? "nim/openai/gpt-oss-20b" : "ollama/llama3.1:8b", attempts: [],
    trace_id: "t-1", trace_url: "http://localhost:3001/project/nodara-rollingf/traces/t-1",
    rcntr: body.rcntr, period: "2026-10",
    analysis: { rcntr: body.rcntr, rcntr_texts: x, area: "CONCENTRADORA", area_texts: x, currency: "USD", category: "RF18M",
                category_texts: x, budget_category: "BUDG", budget_texts: x, period: "2026-10", driver,
                opex: { actual: 1, budget: 1, variance: 0, variance_pct: 0 }, unit_cost: { actual: 1, budget: 1, delta_pct: 0 },
                effects: { price: 0, efficiency: 0, volume: 0, spending: null }, origins: [], lines: [], top_postings: [],
                forecast: { months: 0 } },
    retrieval_filter: { "Año": 2026, "Mes": 10, RCNTR: body.rcntr },
    sources: body.rcntr !== DOMINO.rcntr ? [] : [{
      doc_id: DOMINO.log, title: "x", author_role: "x", section: "Efecto aguas abajo", similarity: 0.8, excerpt: "x",
      source_uri: `s3://raw-docs/concentradora/${DOMINO.log}.md`,
      metadata: { "Año": 2026, "Mes": 10, RCNTR: DOMINO.scope[0], Alcance: DOMINO.scope } }],
    models: { chat: "mock", embeddings: "mock" }, timings_ms: { analysis_ms: 300, generate_ms: 4100 },
  };
}

async function expectText(locator, expected, what) {
  const actual = (await locator.innerText()).trim();
  if (actual.toLowerCase() !== expected.toLowerCase()) throw new Error(`${what}: expected "${expected}", got "${actual}"`);
}

async function expectLanguage(page, code) {
  const expected = EXPECTED[code];
  await page.waitForFunction((lang) => document.documentElement.lang === lang, expected.lang, { timeout: 10000 });
  await expectText(page.locator("h1"), expected.h1, `[${code}] h1`);
  await expectText(page.locator("label[for=question]"), expected.label, `[${code}] chat label`);
  await expectText(page.getByTestId("status-logs"), expected.logs, `[${code}] logs pill`);
  const pressed = await page.getByRole("button", { name: expected.name }).getAttribute("aria-pressed");
  if (pressed !== "true") throw new Error(`[${code}] language button not marked aria-pressed`);
  console.log(`  ✔ ${code.toUpperCase()}  <html lang="${expected.lang}">  ${expected.h1} · ${expected.label} · ${expected.logs}`);
}

async function expectFooter(page, code) {
  const footer = await page.getByTestId("answer-meta").last().innerText();
  const missing = EXPECTED[code].meta.filter((label) => !footer.includes(label));
  if (missing.length) throw new Error(`[${code}] footer misses ${JSON.stringify(missing)}: ${footer}`);
  return footer;
}

(async () => {
  const browser = await chromium.launch();
  try {
    const page = await (await browser.newContext({ viewport: { width: 1280, height: 900 } })).newPage();
    await page.goto(BASE_URL, { waitUntil: "networkidle" });
    await expectLanguage(page, "es"); // default for the Finance Manager in Chile
    for (const code of ["en", "pt", "es"]) {
      await page.getByRole("button", { name: EXPECTED[code].name }).click();
      await expectLanguage(page, code);
    }
    await page.getByRole("button", { name: EXPECTED.en.name }).click();
    await page.reload({ waitUntil: "networkidle" });
    await expectLanguage(page, "en");
    const html = await (await page.request.get(BASE_URL)).text();
    if (!html.includes('<html lang="en"')) throw new Error("language is not rendered on the server (cookie ignored)");
    console.log('  ✔ selection persisted across reload and rendered server-side (<html lang="en"> in the HTML, no flash)');
    await page.getByRole("button", { name: EXPECTED.es.name }).click();
    await expectLanguage(page, "es");

    // Cost center selector (value chain grouped by area, from the lakehouse) and continuous timeline (Trino).
    const select = page.getByTestId("cost-center-select");
    await page.waitForFunction((rcntr) => document.querySelector("[data-testid=cost-center-select]")?.value === rcntr, RCNTR, { timeout: 30000 });
    const options = await select.locator("option").evaluateAll((nodes) => nodes.map((node) => node.value));
    const groups = await select.locator("optgroup").count();
    if (JSON.stringify(options) !== JSON.stringify(VALUE_CHAIN) || groups !== 4) {
      throw new Error(`cost centers ${JSON.stringify(options)} in ${groups} groups`);
    }
    console.log(`  ✔ selector: ${options.length} cost centers of the OPEX C1 value chain in ${groups} areas, default ${RCNTR}`);
    await page.getByTestId("chart").waitFor({ timeout: 30000 });
    const actual = await page.getByTestId("bar-actual").count();
    const plan = await page.getByTestId("bar-plan").count();
    const ticks = await page.getByTestId("budget-marker").count();
    if (actual !== 6 || plan !== 18 || ticks !== 6) {
      throw new Error(`chart has ${actual} actual + ${plan} plan months and ${ticks} budget ticks (expected 6 + 18, 6 ticks)`);
    }
    console.log(`  ✔ chart: ${actual} actual months (ACDOCA) with ${ticks} budget ticks (BUDG) + ${plan} plan months (RF18M)`);

    // The UI must show exactly what Trino computed (live API values: the simulator may have posted more).
    const es = (value, digits = 0, signed = false) => new Intl.NumberFormat("es", {
      minimumFractionDigits: digits, maximumFractionDigits: digits, signDisplay: signed ? "exceptZero" : "auto" }).format(value);
    const sig = (value) => new Intl.NumberFormat("es", { maximumSignificantDigits: 4 }).format(value);
    const pct = (value) => `${es(value, 1, true)} %`;
    const timeline = async (rcntr) => (await page.request.get(`${BASE_URL}/api/opex/timeline?rcntr=${rcntr}`)).json();
    const live = await timeline(RCNTR);
    const decimals = live.driver.decimals;
    const current = live.periods.filter((m) => m.kind === "actual").at(-1);
    await page.getByTestId("bar-actual").nth(5).locator("rect").focus();
    const tooltip = await page.getByTestId("chart-tooltip").innerText();
    for (const expected of [EXPECTED.es.tooltip, `USD ${es(current.opex)}`, `USD ${es(current.budget.opex)}`,
                            pct(current.budget.delta_pct), es(current.unit_cost, decimals)]) {
      if (!tooltip.toLowerCase().includes(expected.toLowerCase())) {
        throw new Error(`keyboard tooltip of ${current.period} misses "${expected}" (Trino): ${tooltip}`);
      }
    }
    console.log(`  ✔ keyboard tooltip on the current month: ${tooltip.split("\n").slice(0, 7).join(" · ")}`);

    await page.getByRole("button", { name: `USD/${live.driver.symbol}` }).click();
    const chartText = await page.getByTestId("chart").textContent();
    const unit = es(current.unit_cost, decimals);
    if (!chartText.includes(unit)) throw new Error(`unit OPEX measure does not label ${unit}: ${chartText.slice(0, 200)}`);
    await page.getByRole("button", { name: "OPEX (USD)" }).click();
    await page.getByRole("button", { name: EXPECTED.es.table }).click();
    const rows = await page.getByTestId("chart-table").locator("tbody tr").count();
    if (rows !== 24) throw new Error(`table view has ${rows} rows (expected 24)`);
    await page.getByRole("button", { name: "Ver gráfico" }).click();
    const kpi = await page.getByTestId("kpi-unit").innerText();
    if (!kpi.includes(`${es(live.summary.unit_cost.actual, decimals)} USD/${live.driver.symbol}`) ||
        !kpi.includes(pct(live.summary.unit_cost.delta_pct))) {
      throw new Error(`unit OPEX tile: ${kpi}`);
    }
    console.log(`  ✔ measure toggle (USD/${live.driver.symbol} → ${unit}), table view (${rows} rows), KPI tile "${kpi.replace(/\n/g, " ")}"`);

    // P x Q matrix: expanding a cost center shows the specific consumption of every input (RACCT) and marks the
    // origin of the deviation; a zero driver is shown as not computable, never as an error.
    const matrix = await (await page.request.get(`${BASE_URL}/api/opex/matrix`)).json();
    const centers = Object.fromEntries(matrix.areas.flatMap((a) => a.cost_centers).map((c) => [c.rcntr, c]));
    await page.getByTestId(`matrix-toggle-${RCNTR}`).click();
    const perf = page.getByTestId(`matrix-lines-${RCNTR}`);
    const lines = await perf.getByTestId("pxq-line").count();
    const origin = centers[RCNTR].origin;
    const steel = centers[RCNTR].lines.find((l) => l.racct === origin.racct);
    const consumption = await perf.locator(`[data-racct=${origin.racct}]`).getByTestId("pxq-consumption").innerText();
    const originCell = await perf.getByTestId("origin-cell").innerText();
    if (lines !== centers[RCNTR].lines.length || !consumption.includes(`${sig(steel.actual_sc)} / ${sig(steel.budget_sc)}`) ||
        originCell !== es(origin.amount, 0, true) || origin.racct !== "ACEROS" || origin.effect !== "efficiency") {
      throw new Error(`matrix ${RCNTR}: ${lines} lines, consumption "${consumption}", origin ${JSON.stringify(origin)} cell "${originCell}"`);
    }
    console.log(`  ✔ matrix ${RCNTR}: ${lines} inputs (RACCT) · ${origin.racct} consumo específico ${consumption.replace(/\n/g, " ")} · origin Q ${originCell}`);
    await page.getByTestId(`matrix-toggle-${PORT}`).click();
    const port = page.getByTestId(`matrix-lines-${PORT}`);
    const labor = await port.locator("[data-racct=LABOR]").getByTestId("pxq-consumption").innerText();
    const portUnit = await page.getByTestId(`matrix-row-${PORT}`).getByTestId("matrix-unit-cost").innerText();
    if (!labor.includes("n/d (impulsor 0)") || !portUnit.includes("n/d (impulsor 0)") || centers[PORT].origin !== null) {
      throw new Error(`matrix ${PORT}: labor "${labor}", unit "${portUnit}", origin ${JSON.stringify(centers[PORT].origin)}`);
    }
    console.log(`  ✔ matrix ${PORT}: driver 0 → consumo específico y OPEX unitario "n/d (impulsor 0)", sin efecto desfavorable`);

    // Port selected: the unit OPEX tile says it cannot be computed (driver = 0) instead of dividing by zero.
    await select.selectOption(PORT);
    await page.waitForFunction(() => document.querySelector("[data-testid=kpi-driver]")?.textContent?.includes("TONEMB"),
                               null, { timeout: 30000 });
    const measures = await page.getByRole("group", { name: "Medida" }).getByRole("button").allInnerTexts();
    const portKpi = await page.getByTestId("kpi-unit").innerText();
    const portDriver = await page.getByTestId("kpi-driver").innerText();
    if (JSON.stringify(measures) !== JSON.stringify(["OPEX (USD)", "USD/WMT"]) || !portKpi.includes("no calculable: impulsor = 0") ||
        !portDriver.includes("0 WMT")) {
      throw new Error(`port: measures ${JSON.stringify(measures)}, tiles "${portKpi}" / "${portDriver}"`);
    }
    console.log(`  ✔ ${PORT}: measures ${measures.join(" / ")} · KPI "${portKpi.replace(/\n/g, " ")}" · "${portDriver.replace(/\n/g, " ")}"`);

    // "Analizar" in the matrix selects that cost center for the chart and the chat.
    await page.getByTestId(`matrix-row-${FLOTATION}`).getByRole("button", { name: /Analizar/ }).click();
    await page.waitForFunction((rcntr) => document.querySelector("[data-testid=cost-center-select]")?.value === rcntr, FLOTATION, { timeout: 10000 });
    console.log(`  ✔ matrix "Analizar" → selector ${FLOTATION}`);

    // Language + engine + cost center routing: every question carries all three.
    const sent = [];
    await page.route("**/api/ask", async (route) => {
      const body = JSON.parse(route.request().postData() ?? "{}");
      sent.push(body);
      await route.fulfill({ json: mockAnswer(body) });
    });
    for (const [code, engine] of [["es", "nim"], ["en", "ollama"], ["pt", "nim"]]) {
      await page.getByRole("button", { name: EXPECTED[code].name }).click();
      await page.getByRole("button", { name: ENGINES[engine] }).click();
      await page.locator("#question").fill(`routing check ${code}`);
      await page.locator("form button[type=submit]").click();
      await page.getByTestId("answer").nth(sent.length - 1).waitFor();
      const body = sent.at(-1) ?? {};
      if (body.language !== code.toUpperCase() || body.engine !== engine || body.question !== `routing check ${code}` ||
          body.rcntr !== FLOTATION) {
        throw new Error(`[${code}] /api/ask body ${JSON.stringify(body)} misses language ${code.toUpperCase()}, engine ${engine} or ${FLOTATION}`);
      }
      const footer = await expectFooter(page, code);
      if (!footer.includes(ENGINES[engine])) throw new Error(`[${code}] footer does not show the engine ${ENGINES[engine]}`);
      console.log(`  ✔ ${code.toUpperCase()}  POST /api/ask → ${JSON.stringify(body)}`);
    }

    // The footer of an answer already on screen follows the selector (no hardcoded metadata).
    for (const code of ["en", "es", "pt"]) {
      await page.getByRole("button", { name: EXPECTED[code].name }).click();
      await page.waitForFunction((lang) => document.documentElement.lang === lang, EXPECTED[code].lang);
      await expectFooter(page, code);
      console.log(`  ✔ ${code.toUpperCase()}  footer re-translated in place: ${EXPECTED[code].meta.slice(0, 3).join(" · ")}`);
    }

    // Domino effect: the log of another cost center shows the RCNTR scope that routed it to this question.
    await page.getByTestId("cost-center-select").selectOption(DOMINO.rcntr);
    await page.locator("#question").fill("domino check");
    await page.locator("form button[type=submit]").click();
    await page.getByTestId("answer").nth(sent.length - 1).waitFor();
    if (sent.at(-1)?.rcntr !== DOMINO.rcntr) throw new Error(`/api/ask body ${JSON.stringify(sent.at(-1))} misses ${DOMINO.rcntr}`);
    for (const code of ["pt", "en", "es"]) {
      await page.getByRole("button", { name: EXPECTED[code].name }).click();
      await page.waitForFunction((lang) => document.documentElement.lang === lang, EXPECTED[code].lang);
      await expectText(page.getByTestId("source-scope").last(), `${EXPECTED[code].scope} ${DOMINO.scope.join(" · ")}`,
                       `[${code}] log scope chip`);
      console.log(`  ✔ ${code.toUpperCase()}  ${DOMINO.rcntr} ← ${DOMINO.log}: "${EXPECTED[code].scope} ${DOMINO.scope.join(" · ")}"`);
    }
  } finally {
    await browser.close();
  }
})().catch((error) => {
  console.error(`  ✘ ${error.message}`);
  process.exit(1);
});
