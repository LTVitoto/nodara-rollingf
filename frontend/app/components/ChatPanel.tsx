"use client";

// AI chat of the Finance Manager: every question carries the selected cost center, the UI language and
// the selected engine. Answers show the narrative, its metadata and the evidence (Trino + logs).
import { FormEvent, useState } from "react";

import { useI18n, type Engine } from "../i18n";
import type { AskResult } from "../types";
import { AnswerMeta } from "./AnswerMeta";
import { EngineSwitcher } from "./EngineSwitcher";
import { AnalysisTable, Sources } from "./Evidence";

type Turn = { id: number; question: string; rcntr: string; result?: AskResult; error?: string };

// Minimal, safe rendering of the LLM markdown: **bold** becomes <strong>, heading marks are dropped and
// everything else stays plain text (React escapes it; no HTML injection).
function RichText({ text }: { text: string }) {
  return (
    <>
      {text
        .replace(/^#{1,6}\s*/gm, "")
        .split("**")
        .map((part, i) => (i % 2 ? <strong key={i} className="font-semibold text-slate-50">{part}</strong> : part))}
    </>
  );
}

export function ChatPanel({ rcntr, engine, onEngineChange, nimAvailable }: {
  rcntr?: string;
  engine: Engine;
  onEngineChange: (engine: Engine) => void;
  nimAvailable: boolean;
}) {
  const { language, t } = useI18n();
  const [question, setQuestion] = useState("");
  const [turns, setTurns] = useState<Turn[]>([]);
  const [loading, setLoading] = useState(false);

  async function ask(event: FormEvent) {
    event.preventDefault();
    if (!rcntr) return;
    const id = Date.now();
    const asked = question.trim();
    setTurns((previous) => [...previous, { id, question: asked, rcntr }]);
    setQuestion("");
    setLoading(true);
    const update = (patch: Partial<Turn>) =>
      setTurns((previous) => previous.map((turn) => (turn.id === id ? { ...turn, ...patch } : turn)));
    try {
      // Engine + language routing: the backend answers with the selected engine, exactly in the UI language.
      const response = await fetch("/api/ask", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ question: asked, language: language.toUpperCase(), engine, rcntr }),
      });
      const body = await response.json().catch(() => ({ code: "backend_unavailable" }));
      if (!response.ok) {
        throw new Error(
          body.code === "backend_unavailable"
            ? t.errors.backendUnavailable
            : typeof body.detail === "string"
              ? body.detail
              : t.errors.invalidRequest,
        );
      }
      update({ result: body });
    } catch (err) {
      update({ error: err instanceof Error ? err.message : t.errors.backendUnavailable });
    } finally {
      setLoading(false);
    }
  }

  return (
    <section className="mt-6 rounded-xl border border-slate-800 bg-slate-900/60 p-5">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-sm font-semibold uppercase tracking-wide text-sky-400">{t.chat.title}</h2>
          <p className="mt-0.5 text-xs text-slate-400">{t.chat.subtitle}</p>
        </div>
        <EngineSwitcher engine={engine} onChange={onEngineChange} nimAvailable={nimAvailable} />
      </div>

      <div className="mt-4 space-y-5">
        {turns.length === 0 ? <p className="text-sm text-slate-500">{t.chat.empty}</p> : null}
        {turns.map((turn) => (
          <article key={turn.id} className="space-y-3">
            <div className="ml-auto max-w-2xl rounded-lg bg-sky-950/60 px-4 py-2.5 text-sm text-sky-50">
              <div className="text-[11px] uppercase tracking-wide text-sky-300">{t.chat.you} · {turn.rcntr}</div>
              {turn.question}
            </div>
            {turn.error ? (
              <div className="rounded-lg border border-amber-700 bg-amber-950/40 p-3 text-sm text-amber-200">{turn.error}</div>
            ) : turn.result ? (
              <div className="rounded-lg border border-slate-800 bg-slate-950/60 p-4">
                <div className="text-[11px] uppercase tracking-wide text-emerald-300">{t.chat.assistant}</div>
                <div data-testid="answer" className="mt-1 whitespace-pre-wrap text-sm leading-relaxed text-slate-100">
                  <RichText text={turn.result.answer} />
                </div>
                <AnswerMeta result={turn.result} />
                <div className="mt-4 grid gap-4 lg:grid-cols-3">
                  <div className="lg:col-span-2"><AnalysisTable analysis={turn.result.analysis} /></div>
                  <Sources sources={turn.result.sources} filter={turn.result.retrieval_filter} />
                </div>
              </div>
            ) : (
              <div className="text-sm text-slate-400">{t.chat.loading}</div>
            )}
          </article>
        ))}
      </div>

      <form onSubmit={ask} className="mt-5 border-t border-slate-800 pt-4">
        <label htmlFor="question" className="text-sm font-medium text-slate-300">{t.chat.label}</label>
        <textarea
          id="question"
          value={question}
          onChange={(e) => setQuestion(e.target.value)}
          placeholder={t.chat.placeholder}
          rows={2}
          className="mt-2 w-full rounded-lg border border-slate-700 bg-slate-950 p-3 text-sm outline-none placeholder:text-slate-600 focus:border-sky-500"
        />
        <div className="mt-3 flex flex-wrap items-center gap-2">
          {t.chat.suggestions.map((suggestion) => (
            <button
              key={suggestion}
              type="button"
              onClick={() => setQuestion(suggestion)}
              className="rounded-full border border-slate-700 px-3 py-1 text-xs text-slate-300 hover:border-sky-500"
            >
              {suggestion}
            </button>
          ))}
          <button
            type="submit"
            disabled={loading || !rcntr || question.trim().length < 3}
            className="ml-auto rounded-lg bg-sky-600 px-5 py-2 text-sm font-semibold hover:bg-sky-500 disabled:opacity-50"
          >
            {loading ? t.chat.loading : t.chat.submit}
          </button>
        </div>
      </form>
    </section>
  );
}
