"use client";

import { useI18n, type Engine } from "../i18n";

export function EngineSwitcher({ engine, onChange, nimAvailable }: {
  engine: Engine;
  onChange: (engine: Engine) => void;
  nimAvailable: boolean;
}) {
  const { t } = useI18n();
  const options: { value: Engine; label: string; disabled: boolean }[] = [
    { value: "nim", label: t.engine.nim, disabled: !nimAvailable },
    { value: "ollama", label: t.engine.ollama, disabled: false },
  ];
  return (
    <div className="flex items-center gap-2 text-xs">
      <span id="engine-label" className="text-slate-400">{t.engine.label}</span>
      <div role="group" aria-labelledby="engine-label" className="inline-flex rounded-lg border border-slate-700 p-0.5">
        {options.map((option) => (
          <button
            key={option.value}
            type="button"
            onClick={() => onChange(option.value)}
            disabled={option.disabled}
            aria-pressed={engine === option.value}
            title={option.disabled ? t.engine.nimUnavailable : option.label}
            className={`rounded-md px-2.5 py-1 font-semibold transition-colors disabled:cursor-not-allowed disabled:opacity-40 ${
              engine === option.value ? "bg-emerald-600 text-white" : "text-slate-400 hover:text-slate-100"
            }`}
          >
            {option.label}
          </button>
        ))}
      </div>
    </div>
  );
}
