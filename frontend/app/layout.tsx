import type { Metadata } from "next";
import { cookies } from "next/headers";

import { DICTIONARIES, LANGUAGE_COOKIE, parseLanguage } from "./dictionaries";
import { LanguageProvider } from "./i18n";
import "./globals.css";

async function preferredLanguage() {
  return parseLanguage((await cookies()).get(LANGUAGE_COOKIE)?.value);
}

export async function generateMetadata(): Promise<Metadata> {
  const t = DICTIONARIES[await preferredLanguage()];
  return { title: t.documentTitle, description: t.header.subtitle };
}

export default async function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  const language = await preferredLanguage();
  return (
    <html lang={DICTIONARIES[language].locale}>
      <body className="min-h-screen bg-slate-950 text-slate-100 antialiased">
        <LanguageProvider initialLanguage={language}>{children}</LanguageProvider>
      </body>
    </html>
  );
}
