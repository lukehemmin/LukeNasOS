import { useState, useEffect, useCallback, useRef } from 'react';
import { useNavigate } from 'react-router-dom';
import axios from 'axios';
import {
  Languages, Clock, HardDrive, Lock, Upload, Power, Info,
  Loader2, AlertCircle, Check, SlidersHorizontal, KeyRound,
} from 'lucide-react';
import { LANGUAGES, isLang, useI18n, type MsgKey } from '../i18n';
import { TIMEZONES } from '../tz';

// 설정 페이지: 일반(호스트명·언어·시간대) / 계정(비밀번호) / 시스템(업데이트·재부팅) / 정보.
// 업데이트·재부팅 UI 는 대시보드에서 이곳으로 이동했다 (대시보드는 모니터링+앱 런처 전용).

interface UpdateStatus {
  active_slot: string;
  inactive_slot: string;
  status: 'idle' | 'installing' | 'success' | 'error';
  message: string;
  progress: number;
}

// key 로 주면 렌더 시점에 번역 → 언어를 바꿔 저장해도 배너가 새 언어로 표시된다.
// 서버가 보낸 동적 메시지는 text 로 그대로 노출.
type Feedback = { ok: boolean; key?: MsgKey; text?: string } | null;

const card = 'rounded-2xl bg-white/[0.06] border border-white/10 backdrop-blur p-6';
const sectionTitle = 'font-semibold text-white flex items-center gap-2 mb-5';
const labelCls = 'flex items-center gap-1.5 text-sm font-medium text-slate-300 mb-2';
const inputCls = 'w-full px-3 py-2.5 rounded-lg bg-white/[0.07] border border-white/10 text-sm text-white outline-none focus:border-blue-400/60 focus:ring-2 focus:ring-blue-500/20 placeholder:text-slate-500';
const selectCls = `${inputCls} [&>option]:bg-slate-900`;
const primaryBtn = 'px-5 py-2.5 bg-blue-500 text-white rounded-lg hover:bg-blue-400 disabled:opacity-50 disabled:cursor-not-allowed text-sm font-medium flex items-center justify-center gap-2 transition-colors';

function FeedbackBanner({ fb }: { fb: Feedback }) {
  const { t } = useI18n();
  if (!fb) return null;
  return (
    <div className={`p-3 rounded-lg text-sm flex items-center gap-2 ${
      fb.ok ? 'bg-green-500/10 border border-green-500/20 text-green-300'
            : 'bg-red-500/10 border border-red-500/20 text-red-300'
    }`}>
      {fb.ok ? <Check size={16} /> : <AlertCircle size={16} />} {fb.key ? t(fb.key) : fb.text}
    </div>
  );
}

export default function Settings() {
  const { t, setLang } = useI18n();
  const navigate = useNavigate();

  const handleAuthError = useCallback((err: any) => {
    if (err?.response?.status === 401) { navigate('/login'); return true; }
    return false;
  }, [navigate]);

  // ── 일반 ───────────────────────────────────────────────
  const [hostname, setHostname] = useState('');
  const [language, setLanguage] = useState('en');
  const [timezone, setTimezone] = useState('UTC');
  const [savingGeneral, setSavingGeneral] = useState(false);
  const [generalFb, setGeneralFb] = useState<Feedback>(null);

  // ── 계정 ───────────────────────────────────────────────
  const [curPw, setCurPw] = useState('');
  const [newPw, setNewPw] = useState('');
  const [confirmPw, setConfirmPw] = useState('');
  const [savingPw, setSavingPw] = useState(false);
  const [pwFb, setPwFb] = useState<Feedback>(null);

  // ── 시스템(업데이트) / 정보 ────────────────────────────
  const [file, setFile] = useState<File | null>(null);
  const [update, setUpdate] = useState<UpdateStatus | null>(null);
  const [uploading, setUploading] = useState(false);
  const [updateErr, setUpdateErr] = useState<string | null>(null);
  const [about, setAbout] = useState<{ version?: string; active_slot?: string }>({});
  const updatePoll = useRef<any>(null);

  useEffect(() => {
    (async () => {
      try {
        const [s, st] = await Promise.all([axios.get('/api/settings'), axios.get('/api/status')]);
        setHostname(s.data.hostname || '');
        setLanguage(s.data.language || 'en');
        if (s.data.timezone) setTimezone(s.data.timezone);
        setAbout(st.data);
      } catch (err: any) {
        handleAuthError(err);
      }
    })();
  }, [handleAuthError]);

  const saveGeneral = async (e: React.FormEvent) => {
    e.preventDefault();
    setGeneralFb(null);
    setSavingGeneral(true);
    try {
      await axios.post('/api/settings', { hostname, language, timezone });
      if (isLang(language)) setLang(language); // 저장 즉시 UI 언어 반영
      setGeneralFb({ ok: true, key: 'savedMsg' });
    } catch (err: any) {
      if (handleAuthError(err)) return;
      const msg = err.response?.data?.message;
      setGeneralFb(msg ? { ok: false, text: msg } : { ok: false, key: 'errSave' });
    } finally {
      setSavingGeneral(false);
    }
  };

  const changePassword = async (e: React.FormEvent) => {
    e.preventDefault();
    setPwFb(null);
    if (newPw !== confirmPw) {
      setPwFb({ ok: false, key: 'errPwMismatch' });
      return;
    }
    setSavingPw(true);
    try {
      await axios.post('/api/account/password', { current_password: curPw, new_password: newPw });
      setCurPw(''); setNewPw(''); setConfirmPw('');
      setPwFb({ ok: true, key: 'pwChangedMsg' });
    } catch (err: any) {
      if (handleAuthError(err)) return;
      const msg = err.response?.data?.message;
      setPwFb(msg ? { ok: false, text: msg } : { ok: false, key: 'errPwChange' });
    } finally {
      setSavingPw(false);
    }
  };

  // 업데이트 진행 폴링 (설치 중에만)
  const pollUpdate = useCallback(() => {
    if (updatePoll.current) clearInterval(updatePoll.current);
    updatePoll.current = setInterval(async () => {
      try {
        const res = await axios.get('/api/update/status');
        const u: UpdateStatus = res.data;
        setUpdate(u);
        if (u.status === 'success' || u.status === 'error') {
          clearInterval(updatePoll.current);
          setUploading(false);
        }
      } catch (err: any) {
        if (handleAuthError(err)) return;
        clearInterval(updatePoll.current);
        setUploading(false);
      }
    }, 1000);
  }, [handleAuthError]);

  useEffect(() => () => { if (updatePoll.current) clearInterval(updatePoll.current); }, []);

  const startUpdate = async () => {
    if (!file) return;
    setUpdateErr(null);
    setUploading(true);
    setUpdate({ active_slot: '', inactive_slot: '', status: 'installing', message: t('uploadingMsg'), progress: 0 });
    try {
      const form = new FormData();
      form.append('update_file', file);
      await axios.post('/api/upload_update', form, { headers: { 'Content-Type': 'multipart/form-data' } });
      pollUpdate();
    } catch (err: any) {
      if (handleAuthError(err)) return;
      setUploading(false);
      setUpdate(null);
      setUpdateErr(err.response?.data?.message || t('errUpdateStart'));
    }
  };

  const reboot = async () => {
    if (!confirm(t('confirmReboot'))) return;
    try {
      await axios.post('/api/system/reboot');
      alert(t('rebootingMsg'));
    } catch (err: any) {
      if (handleAuthError(err)) return;
      alert(t('errRebootPrefix') + (err.response?.data?.message || err.message));
    }
  };

  return (
    <div className="space-y-6 max-w-3xl">
      {/* 일반 */}
      <form className={card} onSubmit={saveGeneral}>
        <h2 className={sectionTitle}>
          <SlidersHorizontal size={18} className="text-slate-400" /> {t('generalSection')}
        </h2>
        <div className="space-y-5">
          <div>
            <label className={labelCls}><HardDrive size={15} className="text-slate-500" /> {t('hostnameLabel')}</label>
            <input type="text" value={hostname} onChange={e => setHostname(e.target.value)} className={inputCls} />
          </div>
          <div className="grid sm:grid-cols-2 gap-5">
            <div>
              <label className={labelCls}><Languages size={15} className="text-slate-500" /> {t('languageLabel')}</label>
              <select value={language} onChange={e => setLanguage(e.target.value)} className={selectCls}>
                {LANGUAGES.map(({ code, label }) => <option key={code} value={code}>{label}</option>)}
              </select>
            </div>
            <div>
              <label className={labelCls}><Clock size={15} className="text-slate-500" /> {t('timezoneLabel')}</label>
              <select value={timezone} onChange={e => setTimezone(e.target.value)} className={selectCls}>
                {!TIMEZONES.includes(timezone) && <option value={timezone}>{timezone}</option>}
                {TIMEZONES.map(tz => <option key={tz} value={tz}>{tz.replace(/_/g, ' ')}</option>)}
              </select>
            </div>
          </div>
          <FeedbackBanner fb={generalFb} />
          <button type="submit" disabled={savingGeneral} className={primaryBtn}>
            {savingGeneral && <Loader2 className="animate-spin" size={15} />} {t('saveBtn')}
          </button>
        </div>
      </form>

      {/* 계정 */}
      <form className={card} onSubmit={changePassword}>
        <h2 className={sectionTitle}>
          <KeyRound size={18} className="text-slate-400" /> {t('accountSection')}
        </h2>
        <div className="space-y-5">
          <div>
            <label className={labelCls}><Lock size={15} className="text-slate-500" /> {t('currentPw')}</label>
            <input type="password" value={curPw} onChange={e => setCurPw(e.target.value)} className={inputCls} />
          </div>
          <div className="grid sm:grid-cols-2 gap-5">
            <div>
              <label className={labelCls}><Lock size={15} className="text-slate-500" /> {t('newPw')}</label>
              <input type="password" value={newPw} onChange={e => setNewPw(e.target.value)} className={inputCls} />
            </div>
            <div>
              <label className={labelCls}><Lock size={15} className="text-slate-500" /> {t('passwordConfirm')}</label>
              <input type="password" value={confirmPw} onChange={e => setConfirmPw(e.target.value)} className={inputCls} />
            </div>
          </div>
          <FeedbackBanner fb={pwFb} />
          <button type="submit" disabled={savingPw || !curPw || !newPw} className={primaryBtn}>
            {savingPw && <Loader2 className="animate-spin" size={15} />} {t('changePwBtn')}
          </button>
        </div>
      </form>

      {/* 시스템: 업데이트 + 재부팅 */}
      <div className={card}>
        <h2 className={sectionTitle}>
          <Upload size={18} className="text-slate-400" /> {t('sysUpdate')}
        </h2>

        {updateErr && (
          <div className="mb-4 p-3 rounded-lg bg-red-500/10 border border-red-500/20 text-red-300 text-sm flex items-center gap-2">
            <AlertCircle size={16} /> {updateErr}
          </div>
        )}

        {update && update.status !== 'idle' ? (
          <div className="space-y-3">
            {update.status === 'installing' && (
              <>
                <div className="w-full bg-white/10 rounded-full h-3 overflow-hidden">
                  <div className="bg-blue-400 h-full transition-all duration-500" style={{ width: `${update.progress}%` }} />
                </div>
                <p className="text-slate-400 font-mono text-sm flex items-center gap-2">
                  <Loader2 className="animate-spin" size={15} /> {update.message}
                </p>
              </>
            )}
            {update.status === 'success' && (
              <div className="p-4 rounded-lg bg-green-500/10 border border-green-500/20 text-green-300 text-sm">
                {update.message} {t('updateSuccessNote')}
              </div>
            )}
            {update.status === 'error' && (
              <div className="p-4 rounded-lg bg-red-500/10 border border-red-500/20 text-red-300 text-sm flex items-center gap-2">
                <AlertCircle size={18} /> {update.message}
              </div>
            )}
          </div>
        ) : (
          <div className="flex flex-col sm:flex-row sm:items-center gap-3">
            <input
              type="file"
              accept=".raucb"
              onChange={e => setFile(e.target.files?.[0] || null)}
              className="flex-1 text-sm text-slate-400 file:mr-3 file:py-2 file:px-4 file:rounded-lg file:border-0 file:bg-blue-500/15 file:text-blue-300 hover:file:bg-blue-500/25 file:cursor-pointer"
            />
            <button onClick={startUpdate} disabled={!file || uploading} className={primaryBtn}>
              {uploading && <Loader2 className="animate-spin" size={15} />} {t('installUpdateBtn')}
            </button>
          </div>
        )}
        <p className="text-xs text-slate-500 mt-4">
          {t('updateHintFmt', { slot: update?.inactive_slot || 'B' })}
        </p>

        <div className="mt-6 pt-5 border-t border-white/10 flex items-center justify-between">
          <span className="text-sm text-slate-300">{t('rebootRow')}</span>
          <button onClick={reboot}
            className="px-5 py-2.5 bg-red-500/90 text-white rounded-lg hover:bg-red-500 text-sm font-medium flex items-center gap-2 transition-colors">
            <Power size={16} /> {t('rebootBtn')}
          </button>
        </div>
      </div>

      {/* 정보 */}
      <div className={card}>
        <h2 className={sectionTitle}>
          <Info size={18} className="text-slate-400" /> {t('aboutSection')}
        </h2>
        <dl className="text-sm divide-y divide-white/[0.07]">
          <div className="flex items-center justify-between py-2.5">
            <dt className="text-slate-400">{t('versionLabel')}</dt>
            <dd className="font-mono text-slate-200">{about.version || '—'}</dd>
          </div>
          <div className="flex items-center justify-between py-2.5">
            <dt className="text-slate-400">{t('activeSlotLabel')}</dt>
            <dd className="font-mono text-slate-200">{about.active_slot || '—'}</dd>
          </div>
        </dl>
      </div>
    </div>
  );
}
