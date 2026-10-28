// UI regression test against the live frontend + backend (real lakehouse data, mocked /api/ask):
// language selector (ES / EN / PT) with server-side persistence, cost center selector, continuous
// chart (3 actual + 18 plan months) with keyboard tooltip, measure toggle and table view, KPI tiles,
// and the AI chat carrying language + engine + cost center, with its footer translated in place.
// Runs in the Playwright image:  make ui-test
const { chromium } = require("playwright-core");

const BASE_URL = process.env.BASE_URL ?? "http://frontend:3000";
const RCNTR = "RCNTR_MINA_CAEX";
const EXPECTED = {
  es: { lang: "es", name: "Español", h1: "Rolling Forecast de OPEX · 18 meses", label: "Pregunta del Gerente de Finanzas", logs: "Bitácoras",
        tooltip: "oct 26", table: "Ver tabla",
        meta: ["Cifras verificadas contra Trino", "Idioma de la respuesta", "Tiempo total", "Motor"] },
  en: { lang: "en", name: "English", h1: "OPEX Rolling Forecast · 18 months", label: "Finance Manager question", logs: "Logs",
        tooltip: "Oct 26", table: "Show table",
        meta: ["Figures checked against Trino", "Answer language", "Total time", "Engine"] },
  pt: { lang: "pt-BR", name: "Português", h1: "Rolling Forecast de OPEX · 18 meses", label: "Pergunta do Gerente Financeiro", logs: "Diários",
        tooltip: "out. de 26", table: "Ver tabela",
        meta: ["Números conferidos com Trino", "Idioma da resposta", "Tempo total", "Motor"] },
};
const ENGINES = { nim: "NVIDIA NIM (Cloud)", ollama: "Ollama (Local)" };

function mockAnswer(body) {
  const nim = body.engine === "nim";
  const metric = { current: 1, previous: 1, baseline: 1, delta_previous: 0, delta_previous_pct: 0, delta_baseline: 0,
                   delta_baseline_pct: 0, share_pct: null };
  return {
    answer: "mock answer", language: String(body.language).toLowerCase(),
    language_check: { requested: "es", detected: "es", status: "ok" },
    figures_check: { checked: 3, grounded: 3, ungrounded: [] },
    engine: body.engine, model_used: nim ? "nim/openai/gpt-oss-20b" : "ollama/llama3.1:8b", attempts: [],
    trace_id: "t-1", trace_url: "http://localhost:3001/project/nodara-rollingf/traces/t-1",
    rcntr: body.rcntr, period: "2026-10",
    analysis: { rcntr: body.rcntr, rcntr_texts: { es: "x", en: "x", pt: "x" }, currency: "USD", category: "RF18M",
                category_texts: { es: "x", en: "x", pt: "x" }, period: "2026-10", previous_period: "2026-09",
                baseline: { months: 2, from: "2026-08", to: "2026-09" }, totals: { OPEX: metric }, accounts: [],
                top_postings: [], forecast: { months: 0 } },
    retrieval_filter: { "Año": 2026, "Mes": 10, RCNTR: body.rcntr }, sources: [],
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

    // Cost center selector and continuous timeline from the real lakehouse (Trino).
    const select = page.getByTestId("cost-center-select");
    await page.waitForFunction((rcntr) => document.querySelector("[data-testid=cost-center-select]")?.value === rcntr, RCNTR, { timeout: 30000 });
    await page.getByTestId("chart").waitFor({ timeout: 30000 });
    const actual = await page.getByTestId("bar-actual").count();
    const plan = await page.getByTestId("bar-plan").count();
    if (actual !== 3 || plan !== 18) throw new Error(`chart has ${actual} actual + ${plan} plan months (expected 3 + 18)`);
    console.log(`  ✔ selector ${await select.inputValue()} · chart: ${actual} actual months (ACDOCA) + ${plan} plan months (ACDOCP)`);

    // The UI must show exactly what Trino computed (live API values: the simulator may have posted more).
    const live = await (await page.request.get(`${BASE_URL}/api/opex/timeline?rcntr=${RCNTR}`)).json();
    const current = live.periods.filter((m) => m.kind === "actual").at(-1);
    const es = (value, digits = 0) =>
      new Intl.NumberFormat("es", { minimumFractionDigits: digits, maximumFractionDigits: digits }).format(value);
    await page.getByTestId("bar-actual").nth(2).locator("rect").focus();
    const tooltip = await page.getByTestId("chart-tooltip").innerText();
    if (!tooltip.toLowerCase().includes(EXPECTED.es.tooltip) || !tooltip.includes(`USD ${es(current.opex)}`) ||
        !tooltip.includes(es(current.usd_per_hour, 2))) {
      throw new Error(`keyboard tooltip of ${current.period} does not match Trino (${es(current.opex)}): ${tooltip}`);
    }
    console.log(`  ✔ keyboard tooltip on the current month: ${tooltip.split("\n").slice(0, 4).join(" · ")}`);

    await page.getByRole("button", { name: "USD/h" }).click();
    const chartText = await page.getByTestId("chart").textContent();
    const unit = es(current.usd_per_hour, 2);
    if (!chartText.includes(unit)) throw new Error(`USD/h measure does not label ${unit}: ${chartText.slice(0, 200)}`);
    await page.getByRole("button", { name: "OPEX (USD)" }).click();
    await page.getByRole("button", { name: EXPECTED.es.table }).click();
    const rows = await page.getByTestId("chart-table").locator("tbody tr").count();
    if (rows !== 21) throw new Error(`table view has ${rows} rows (expected 21)`);
    await page.getByRole("button", { name: "Ver gráfico" }).click();
    const kpi = await page.getByTestId("kpi-unit").innerText();
    if (!kpi.includes(`${es(live.summary.totals.USD_H.current, 2)} USD/h`)) throw new Error(`unit OPEX tile: ${kpi}`);
    console.log(`  ✔ measure toggle (USD/h → ${unit}), table view (${rows} rows), KPI tile "${kpi.replace(/\n/g, " ")}"`);

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
          body.rcntr !== RCNTR) {
        throw new Error(`[${code}] /api/ask body ${JSON.stringify(body)} misses language ${code.toUpperCase()}, engine ${engine} or ${RCNTR}`);
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
  } finally {
    await browser.close();
  }
})().catch((error) => {
  console.error(`  ✘ ${error.message}`);
  process.exit(1);
});
