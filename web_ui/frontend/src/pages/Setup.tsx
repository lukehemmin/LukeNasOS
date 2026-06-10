import { useState, useEffect } from 'react';
import axios from 'axios';
import {
  Server, AlertCircle, Loader2, User, Lock, HardDrive,
  Languages, Clock, Check, ArrowRight, ArrowLeft,
} from 'lucide-react';
import { LANGUAGES, LOCALE, useI18n } from '../i18n';

interface SetupProps {
  onDone: () => Promise<void> | void;
}

// Intl.supportedValuesOf 미지원 브라우저용 주요 시간대 폴백
const TZ_FALLBACK = [
  'UTC',
  'America/New_York', 'America/Chicago', 'America/Denver', 'America/Los_Angeles',
  'America/Sao_Paulo', 'Europe/London', 'Europe/Paris', 'Europe/Berlin',
  'Europe/Madrid', 'Europe/Moscow', 'Africa/Cairo', 'Asia/Dubai', 'Asia/Kolkata',
  'Asia/Bangkok', 'Asia/Shanghai', 'Asia/Hong_Kong', 'Asia/Singapore',
  'Asia/Seoul', 'Asia/Tokyo', 'Australia/Sydney', 'Pacific/Auckland',
];

function getTimezones(): string[] {
  try {
    const list = (Intl as any).supportedValuesOf?.('timeZone');
    if (Array.isArray(list) && list.length > 0) return list;
  } catch { /* fall through */ }
  return TZ_FALLBACK;
}

function guessTimezone(): string {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
  } catch {
    return 'UTC';
  }
}

const TIMEZONES = getTimezones();

// 최초 셋업 마법사: 1) 언어·시간대 → 2) 관리자 계정·NAS 이름.
// 언어는 선택 즉시 전체 UI 에 반영되고, 완료 시 백엔드 settings.json 에 저장되어
// 이후 모든 부팅·로그인·대시보드에서 그대로 유지된다.
export default function Setup({ onDone }: SetupProps) {
  const { lang, setLang, t } = useI18n();
  const [step, setStep] = useState<1 | 2>(1);
  const [timezone, setTimezone] = useState(guessTimezone());
  const [now, setNow] = useState(() => new Date());
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [hostname, setHostname] = useState('lukenasos');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  // 시간대 미리보기용 시계 (1단계에서만 갱신)
  useEffect(() => {
    if (step !== 1) return;
    const interval = setInterval(() => setNow(new Date()), 1000);
    return () => clearInterval(interval);
  }, [step]);

  const tzPreview = (() => {
    try {
      return new Intl.DateTimeFormat(LOCALE[lang], {
        dateStyle: 'medium', timeStyle: 'medium', timeZone: timezone,
      }).format(now);
    } catch {
      return now.toUTCString();
    }
  })();

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);

    if (!username || !password) {
      setError(t('errRequired'));
      return;
    }
    if (password !== confirm) {
      setError(t('errPwMismatch'));
      return;
    }

    setBusy(true);
    try {
      // 성공 시 백엔드가 세션도 설정(자동 로그인) → onDone() 이 대시보드로 보냄
      await axios.post('/setup', { username, password, hostname, language: lang, timezone });
      await onDone();
    } catch (err: any) {
      setError(err.response?.data?.message || err.message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="min-h-screen bg-gray-100 flex items-center justify-center p-4">
      <div className="max-w-md w-full bg-white rounded-xl shadow-lg overflow-hidden">
        <div className="bg-blue-600 p-6 text-white text-center">
          <h1 className="text-2xl font-bold flex items-center justify-center gap-2">
            <Server /> {t('setupTitle')}
          </h1>
        </div>

        {step === 1 ? (
          <div className="p-8 space-y-5">
            <div>
              <h2 className="font-semibold text-gray-900">{t('localeTitle')}</h2>
              <p className="text-gray-500 text-sm mt-1">{t('localeSubtitle')}</p>
            </div>

            <div>
              <label className="flex items-center gap-1.5 text-sm font-medium text-gray-700 mb-2">
                <Languages size={16} className="text-gray-400" /> {t('languageLabel')}
              </label>
              <div className="grid grid-cols-2 gap-2">
                {LANGUAGES.map(({ code, label }) => {
                  const isSel = lang === code;
                  return (
                    <button
                      key={code}
                      type="button"
                      onClick={() => setLang(code)}
                      className={`px-3 py-2.5 rounded-lg border text-sm font-medium flex items-center justify-between transition-all ${
                        isSel
                          ? 'border-blue-500 bg-blue-50/60 text-blue-700 ring-2 ring-blue-100'
                          : 'border-gray-200 text-gray-700 hover:border-gray-300 hover:bg-gray-50'
                      }`}
                    >
                      <span>{label}</span>
                      {isSel && <Check size={15} className="text-blue-600 shrink-0" />}
                    </button>
                  );
                })}
              </div>
            </div>

            <div>
              <label className="flex items-center gap-1.5 text-sm font-medium text-gray-700 mb-2">
                <Clock size={16} className="text-gray-400" /> {t('timezoneLabel')}
              </label>
              <select
                value={timezone}
                onChange={e => setTimezone(e.target.value)}
                className="w-full px-3 py-2.5 rounded-lg border border-gray-200 text-sm bg-white outline-none focus:border-blue-400 focus:ring-2 focus:ring-blue-100"
              >
                {!TIMEZONES.includes(timezone) && <option value={timezone}>{timezone}</option>}
                {TIMEZONES.map(tz => (
                  <option key={tz} value={tz}>{tz.replace(/_/g, ' ')}</option>
                ))}
              </select>
              <div className="mt-2 text-xs text-gray-400 flex items-center gap-1.5">
                <span>{t('currentTime')}:</span>
                <span className="font-mono text-gray-500 tabular-nums">{tzPreview}</span>
              </div>
            </div>

            <button
              type="button"
              onClick={() => setStep(2)}
              className="w-full px-6 py-3 bg-blue-600 text-white rounded-lg hover:bg-blue-700 font-medium flex items-center justify-center gap-2"
            >
              {t('nextBtn')} <ArrowRight size={18} />
            </button>
          </div>
        ) : (
          <form className="p-8 space-y-5" onSubmit={submit}>
            <p className="text-gray-600 text-sm text-center">{t('accountIntro')}</p>

            {error && (
              <div className="p-4 bg-red-50 text-red-700 rounded-lg flex items-center gap-2">
                <AlertCircle size={20} /> {error}
              </div>
            )}

            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">{t('adminId')}</label>
              <div className="flex items-center gap-2 border rounded-lg px-3">
                <User size={18} className="text-gray-400" />
                <input
                  type="text"
                  value={username}
                  onChange={e => setUsername(e.target.value)}
                  placeholder="admin"
                  className="w-full p-2 outline-none"
                  autoFocus
                />
              </div>
            </div>

            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">{t('passwordLabel')}</label>
              <div className="flex items-center gap-2 border rounded-lg px-3">
                <Lock size={18} className="text-gray-400" />
                <input
                  type="password"
                  value={password}
                  onChange={e => setPassword(e.target.value)}
                  className="w-full p-2 outline-none"
                />
              </div>
            </div>

            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">{t('passwordConfirm')}</label>
              <div className="flex items-center gap-2 border rounded-lg px-3">
                <Lock size={18} className="text-gray-400" />
                <input
                  type="password"
                  value={confirm}
                  onChange={e => setConfirm(e.target.value)}
                  className="w-full p-2 outline-none"
                />
              </div>
            </div>

            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">{t('hostnameLabel')}</label>
              <div className="flex items-center gap-2 border rounded-lg px-3">
                <HardDrive size={18} className="text-gray-400" />
                <input
                  type="text"
                  value={hostname}
                  onChange={e => setHostname(e.target.value)}
                  className="w-full p-2 outline-none"
                />
              </div>
            </div>

            <div className="flex gap-3">
              <button
                type="button"
                onClick={() => setStep(1)}
                className="px-4 py-3 rounded-lg border border-gray-200 text-gray-600 hover:bg-gray-50 font-medium flex items-center gap-1.5"
              >
                <ArrowLeft size={16} /> {t('backBtn')}
              </button>
              <button
                type="submit"
                disabled={busy}
                className="flex-1 px-6 py-3 bg-blue-600 text-white rounded-lg hover:bg-blue-700 font-medium disabled:opacity-50 disabled:cursor-not-allowed flex items-center justify-center gap-2"
              >
                {busy && <Loader2 className="animate-spin" size={18} />}
                {t('finishBtn')}
              </button>
            </div>
          </form>
        )}
      </div>
    </div>
  );
}
