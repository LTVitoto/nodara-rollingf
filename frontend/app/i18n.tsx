"use client";

// Lightweight global i18n state (React Context). The server renders the language stored in the
// cookie (see layout.tsx), so there is no flash of the default language after hydration.
import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";

import { DICTIONARIES, LANGUAGE_COOKIE, type Dictionary, type Language } from "./dictionaries";

export { DICTIONARIES, LANGUAGES, type Engine, type Language } from "./dictionaries";

type I18n = { language: Language; setLanguage: (language: Language) => void; t: Dictionary };

const I18nContext = createContext<I18n | null>(null);

export function LanguageProvider({ initialLanguage, children }: { initialLanguage: Language; children: ReactNode }) {
  const [language, setLanguageState] = useState<Language>(initialLanguage);

  useEffect(() => {
    document.documentElement.lang = DICTIONARIES[language].locale;
    document.title = DICTIONARIES[language].documentTitle;
  }, [language]);

  const setLanguage = useCallback((next: Language) => {
    setLanguageState(next);
    document.cookie = `${LANGUAGE_COOKIE}=${next}; path=/; max-age=31536000; samesite=lax`;
  }, []);

  const value = useMemo(() => ({ language, setLanguage, t: DICTIONARIES[language] }), [language, setLanguage]);
  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>;
}

export function useI18n(): I18n {
  const context = useContext(I18nContext);
  if (!context) throw new Error("useI18n must be used inside <LanguageProvider>");
  return context;
}
