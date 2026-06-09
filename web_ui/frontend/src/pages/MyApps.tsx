import { useState, useEffect, useCallback, useRef } from 'react';
import { useNavigate, Link } from 'react-router-dom';
import axios from 'axios';
import {
  ExternalLink, Play, Square, Trash2, RotateCw, Loader2, AlertCircle, Boxes, Store,
} from 'lucide-react';
import AppCard from '../components/AppCard';

interface InstalledApp {
  id: string;
  name: string;
  icon?: string;
  color?: string;
  category?: string;
  web_ui_port?: number;
  web_ui_path?: string;
  state: 'running' | 'stopped' | 'unknown' | string;
}

export default function MyApps() {
  const navigate = useNavigate();
  const [apps, setApps] = useState<InstalledApp[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<Record<string, boolean>>({});
  const poll = useRef<any>(null);

  const handleAuthError = useCallback((err: any) => {
    if (err?.response?.status === 401) { navigate('/login'); return true; }
    return false;
  }, [navigate]);

  const fetchApps = useCallback(async () => {
    try {
      const res = await axios.get('/api/apps/installed');
      setApps(res.data.apps);
      setError(null);
    } catch (err: any) {
      if (handleAuthError(err)) return;
      setError('앱 목록을 불러오지 못했습니다.');
    }
  }, [handleAuthError]);

  useEffect(() => {
    fetchApps();
    poll.current = setInterval(fetchApps, 5000);
    return () => clearInterval(poll.current);
  }, [fetchApps]);

  const setAppBusy = (id: string, v: boolean) => setBusy(b => ({ ...b, [id]: v }));

  const action = async (id: string, verb: 'start' | 'stop' | 'restart') => {
    setAppBusy(id, true);
    try {
      await axios.post(`/api/apps/${id}/${verb}`);
      await fetchApps();
    } catch (err: any) {
      if (!handleAuthError(err)) alert('작업 실패: ' + (err.response?.data?.message || err.message));
    } finally {
      setAppBusy(id, false);
    }
  };

  const uninstall = async (app: InstalledApp) => {
    if (!confirm(`'${app.name}' 앱을 삭제하시겠습니까?`)) return;
    const deleteData = confirm(
      '앱 데이터(파일)도 영구 삭제할까요?\n\n확인 = 데이터까지 삭제\n취소 = 데이터는 보존(재설치 시 복원)'
    );
    setAppBusy(app.id, true);
    try {
      await axios.delete(`/api/apps/${app.id}${deleteData ? '?delete_data=1' : ''}`);
      await fetchApps();
    } catch (err: any) {
      if (!handleAuthError(err)) alert('삭제 실패: ' + (err.response?.data?.message || err.message));
    } finally {
      setAppBusy(app.id, false);
    }
  };

  const openApp = (app: InstalledApp) => {
    if (!app.web_ui_port) return;
    const url = `http://${window.location.hostname}:${app.web_ui_port}${app.web_ui_path || '/'}`;
    window.open(url, '_blank', 'noopener');
  };

  const StateBadge = ({ state }: { state: string }) => {
    const running = state === 'running';
    return (
      <span className={`text-xs px-2 py-0.5 rounded-full font-medium shrink-0 ${
        running ? 'bg-green-100 text-green-700' : 'bg-gray-100 text-gray-500'
      }`}>
        {running ? '실행 중' : state === 'stopped' ? '중지됨' : state}
      </span>
    );
  };

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h2 className="text-lg font-semibold flex items-center gap-2">
          <Boxes size={20} className="text-gray-400" /> 내 앱
        </h2>
        <Link to="/apps/store" className="flex items-center gap-1.5 text-sm bg-blue-600 text-white px-4 py-2 rounded-lg hover:bg-blue-700">
          <Store size={16} /> 앱스토어
        </Link>
      </div>

      {error && (
        <div className="p-4 bg-red-50 text-red-700 rounded-lg flex items-center gap-2">
          <AlertCircle size={20} /> {error}
        </div>
      )}

      {!apps ? (
        <div className="text-center py-12 text-gray-500">
          <Loader2 className="animate-spin inline mr-2" /> 불러오는 중...
        </div>
      ) : apps.length === 0 ? (
        <div className="bg-white rounded-xl shadow-lg p-10 text-center text-gray-500">
          <Boxes size={40} className="mx-auto mb-3 text-gray-300" />
          <p className="mb-4">설치된 앱이 없습니다.</p>
          <Link to="/apps/store" className="inline-flex items-center gap-1.5 text-sm bg-blue-600 text-white px-4 py-2 rounded-lg hover:bg-blue-700">
            <Store size={16} /> 앱스토어에서 둘러보기
          </Link>
        </div>
      ) : (
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
          {apps.map(app => {
            const running = app.state === 'running';
            const isBusy = !!busy[app.id];
            return (
              <AppCard
                key={app.id}
                icon={app.icon}
                color={app.color}
                title={app.name}
                subtitle={app.category}
                badge={<StateBadge state={app.state} />}
              >
                {running && app.web_ui_port && (
                  <button onClick={() => openApp(app)}
                    className="flex-1 flex items-center justify-center gap-1.5 text-sm bg-blue-600 text-white px-3 py-2 rounded-lg hover:bg-blue-700">
                    <ExternalLink size={15} /> 열기
                  </button>
                )}
                {running ? (
                  <button onClick={() => action(app.id, 'stop')} disabled={isBusy} title="중지"
                    className="flex items-center justify-center px-3 py-2 rounded-lg border text-gray-600 hover:bg-gray-100 disabled:opacity-50">
                    {isBusy ? <Loader2 size={15} className="animate-spin" /> : <Square size={15} />}
                  </button>
                ) : (
                  <button onClick={() => action(app.id, 'start')} disabled={isBusy} title="시작"
                    className="flex-1 flex items-center justify-center gap-1.5 text-sm bg-green-600 text-white px-3 py-2 rounded-lg hover:bg-green-700 disabled:opacity-50">
                    {isBusy ? <Loader2 size={15} className="animate-spin" /> : <Play size={15} />} 시작
                  </button>
                )}
                <button onClick={() => action(app.id, 'restart')} disabled={isBusy} title="재시작"
                  className="flex items-center justify-center px-3 py-2 rounded-lg border text-gray-600 hover:bg-gray-100 disabled:opacity-50">
                  <RotateCw size={15} />
                </button>
                <button onClick={() => uninstall(app)} disabled={isBusy} title="삭제"
                  className="flex items-center justify-center px-3 py-2 rounded-lg border border-red-200 text-red-600 hover:bg-red-50 disabled:opacity-50">
                  <Trash2 size={15} />
                </button>
              </AppCard>
            );
          })}
        </div>
      )}
    </div>
  );
}
