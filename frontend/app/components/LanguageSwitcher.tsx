"use client";

import { DICTIONARIES, LANGUAGES, useI18n } from "../i18n";

export function LanguageSwitcher() {
  const { language, setLanguage, t } = useI18n();
  return (
    <div role="group" aria-label={t.header.language} className="inline-flex rounded-lg border border-slate-700 p-0.5">
      {LANGUAGES.map((code) => (
        <button
          key={code}
          type="button"
          onClick={() => setLanguage(code)}
          aria-pressed={language === code}
          aria-label={DICTIONARIES[code].languageName}
          title={DICTIONARIES[code].languageName}
          className={`rounded-md px-2.5 py-1 text-xs font-semibold transition-colors ${
            language === code ? "bg-sky-600 text-white" : "text-slate-400 hover:text-slate-100"
          }`}
        >
          {code.toUpperCase()}
        </button>
      ))}
    </div>
  );
}
