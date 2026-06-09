import { useState, useEffect, useCallback, useRef } from 'react';
import { useNavigate } from 'react-router-dom';
import axios from 'axios';
import {
  Store, Loader2, AlertCircle, CheckCircle2, X, Download, HardDrive,
} from 'lucide-react';
import AppCard, { AppIcon } from '../components/AppCard';

interface Variable { key: string; label: string; default: any; type: 'port' | 'number' | 'string'; }
interface CatalogApp {
  id: string;
  name: string;
  tagline?: string;
  category?: string;
  icon?: string;
  color?: string;
  variables?: Variable[];
}
interface InstallStatus {
  status: 'idle' | 'pulling' | 'starting' | 'success' | 'error';
  message: string;
  progress: number;
  app_id: string | null;
}

export default function AppStore() {
  const navigate = useNavigate();
  const [catalog, setCatalog] = useState<CatalogApp[] | null>(null);
  const [installedIds, setInstalledIds] = useState<Set<string>>(new Set());
  const [error, setError] = useState<string | null>(null);
  const [dataFree, setDataFree] = useState<string | null>(null);

  // 설치 모달 상태
  const [modalApp, setModalApp] = useState<CatalogApp | null>(null);
  const [form, setForm] = useState<Record<string, any>>({});
  const [install, setInstall] = useState<InstallStatus | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const poll = useRef<any>(null);

  const handleAuthError = useCallback((err: any) => {
    if (err?.response?.status === 401) { navigate('/login'); return true; }
    return false;
  }, [navigate]);

  const load = useCallback(async () => {
    try {
      const [cat, inst, sys] = await Promise.all([
        axios.get('/api/apps/catalog'),
        axios.get('/api/apps/installed'),
        axios.get('/api/status').catch(() => null),
      ]);
      setCatalog(cat.data.apps);
      setInstalledIds(new Set((inst.data.apps as any[]).map(a => a.id)));
      if (sys) setDataFree(`${sys.data.data_free} / ${sys.data.data_total}`);
      setError(null);
    } catch (err: any) {
      if (handleAuthError(err)) return;
      setError('앱스토어를 불러오지 못했습니다.');
    }
  }, [handleAuthError]);

  useEffect(() => { load(); }, [load]);
  useEffect(() => () => { if (poll.current) clearInterval(poll.current); }, []);

  const openModal = (app: CatalogApp) => {
    const init: Record<string, any> = {};
    (app.variables || []).forEach(v => { init[v.key] = v.default; });
    setForm(init);
    setInstall(null);
    setModalApp(app);
  };

  const closeModal = () => {
    if (poll.current) clearInterval(poll.current);
    setModalApp(null);
    setInstall(null);
    setSubmitting(false);
  };

  const pollStatus = useCallback(() => {
    if (poll.current) clearInterval(poll.current);
    poll.current = setInterval(async () => {
      try {
        const res = await axios.get('/api/apps/install/status');
        const st: InstallStatus = res.data;
        setInstall(st);
        if (st.status === 'success' || st.status === 'error') {
          clearInterval(poll.current);
          setSubmitting(false);
          if (st.status === 'success') {
            setInstalledIds(prev => new Set(prev).add(st.app_id || ''));
            setTimeout(() => { navigate('/apps'); }, 1200);
          }
        }
      } catch (err: any) {
        if (handleAuthError(err)) return;
        clearInterval(poll.current);
        setSubmitting(false);
      }
    }, 1000);
  }, [handleAuthError, navigate]);

  const submitInstall = async () => {
    if (!modalApp) return;
    setSubmitting(true);
    setInstall({ status: 'pulling', message: '설치 준비 중...', progress: 0, app_id: modalApp.id });
    try {
      await axios.post('/api/apps/install', { app_id: modalApp.id, config: form });
      pollStatus();
    } catch (err: any) {
      if (handleAuthError(err)) return;
      setSubmitting(false);
      setInstall({ status: 'error', message: err.response?.data?.message || '설치 시작 실패', progress: 0, app_id: modalApp.id });
    }
  };

  const installing = install && (install.status === 'pulling' || install.status === 'starting');

  return (
    <div className="space-y-6">
      <h2 className="text-lg font-semibold flex items-center gap-2">
        <Store size={20} className="text-gray-400" /> 앱스토어
      </h2>

      {error && (
        <div className="p-4 bg-red-50 text-red-700 rounded-lg flex items-center gap-2">
          <AlertCircle size={20} /> {error}
        </div>
      )}

      {!catalog ? (
        <div className="text-center py-12 text-gray-500">
          <Loader2 className="animate-spin inline mr-2" /> 불러오는 중...
        </div>
      ) : (
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
          {catalog.map(app => {
            const isInstalled = installedIds.has(app.id);
            return (
              <AppCard key={app.id} icon={app.icon} color={app.color} title={app.name} subtitle={app.tagline}>
                {isInstalled ? (
                  <button disabled
                    className="flex-1 flex items-center justify-center gap-1.5 text-sm bg-gray-100 text-gray-400 px-3 py-2 rounded-lg cursor-default">
                    <CheckCircle2 size={15} /> 설치됨
                  </button>
                ) : (
                  <button onClick={() => openModal(app)}
                    className="flex-1 flex items-center justify-center gap-1.5 text-sm bg-blue-600 text-white px-3 py-2 rounded-lg hover:bg-blue-700">
                    <Download size={15} /> 설치
                  </button>
                )}
              </AppCard>
            );
          })}
        </div>
      )}

      {/* 설치 모달 */}
      {modalApp && (
        <div className="fixed inset-0 bg-black/40 flex items-center justify-center p-4 z-50" onClick={closeModal}>
          <div className="bg-white rounded-xl shadow-2xl w-full max-w-md max-h-[90vh] overflow-y-auto" onClick={e => e.stopPropagation()}>
            <div className="p-5 border-b flex items-center justify-between">
              <div className="flex items-center gap-3">
                <AppIcon name={modalApp.icon} color={modalApp.color} size={22} />
                <div>
                  <h3 className="font-semibold">{modalApp.name} 설치</h3>
                  {modalApp.tagline && <p className="text-xs text-gray-500">{modalApp.tagline}</p>}
                </div>
              </div>
              <button onClick={closeModal} className="text-gray-400 hover:text-gray-600"><X size={20} /></button>
            </div>

            <div className="p-5 space-y-4">
              {install && install.status !== 'idle' ? (
                <div className="space-y-3">
                  {installing && (
                    <>
                      <div className="w-full bg-gray-200 rounded-full h-4 overflow-hidden">
                        <div className="bg-blue-600 h-4 transition-all duration-500" style={{ width: `${install.progress}%` }} />
                      </div>
                      <p className="text-gray-600 font-mono text-sm flex items-center gap-2">
                        <Loader2 className="animate-spin" size={16} /> {install.message}
                      </p>
                    </>
                  )}
                  {install.status === 'success' && (
                    <div className="p-4 bg-green-50 text-green-700 rounded-lg flex items-center gap-2">
                      <CheckCircle2 size={20} /> {install.message} 내 앱으로 이동합니다...
                    </div>
                  )}
                  {install.status === 'error' && (
                    <div className="p-4 bg-red-50 text-red-700 rounded-lg flex items-center gap-2">
                      <AlertCircle size={20} /> {install.message}
                    </div>
                  )}
                </div>
              ) : (
                <>
                  {dataFree && (
                    <div className="text-xs text-gray-500 flex items-center gap-1.5 bg-gray-50 rounded-lg p-2">
                      <HardDrive size={14} /> 데이터 여유 공간: {dataFree}
                    </div>
                  )}
                  {(modalApp.variables || []).map(v => (
                    <div key={v.key}>
                      <label className="block text-sm font-medium text-gray-700 mb-1">{v.label}</label>
                      <input
                        type={v.type === 'string' ? 'text' : 'number'}
                        value={form[v.key] ?? ''}
                        onChange={e => setForm(f => ({
                          ...f,
                          [v.key]: v.type === 'string' ? e.target.value : Number(e.target.value),
                        }))}
                        className="w-full p-2 border rounded-lg outline-none focus:border-blue-500"
                      />
                    </div>
                  ))}
                  <p className="text-xs text-gray-400">
                    웹 포트는 다른 앱·시스템과 겹치지 않아야 합니다(80·443·22 등은 사용 불가).
                  </p>
                </>
              )}
            </div>

            {!(install && install.status !== 'idle') && (
              <div className="p-5 border-t flex justify-end gap-2">
                <button onClick={closeModal} className="px-4 py-2 rounded-lg border text-gray-600 hover:bg-gray-50">취소</button>
                <button onClick={submitInstall} disabled={submitting}
                  className="px-5 py-2 rounded-lg bg-blue-600 text-white hover:bg-blue-700 disabled:opacity-50 flex items-center gap-2">
                  {submitting && <Loader2 className="animate-spin" size={16} />} 설치
                </button>
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
