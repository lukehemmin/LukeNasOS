import { useState, useEffect, useCallback } from 'react';
import { useNavigate, Link } from 'react-router-dom';
import axios from 'axios';
import {
  Cpu, MemoryStick, HardDrive, Database, Store, Boxes, AlertCircle, Loader2,
} from 'lucide-react';
import { AppIcon } from '../components/AppCard';
import { useI18n } from '../i18n';

// 위젯 홈: 시스템 지표 위젯 + 설치된 앱 런처.
// 업데이트·재부팅 같은 관리 작업은 설정(/settings)으로 분리되었다.

interface SystemStatus {
  cpu_percent: number;
  memory_percent: number;
  disk_percent: number;
  disk_free: string;
  disk_total: string;
  data_free: string;
  data_total: string;
}

interface InstalledApp {
  id: string;
  name: string;
  icon?: string;
  color?: string;
  web_ui_port?: number;
  web_ui_path?: string;
  state: 'running' | 'stopped' | 'unknown' | string;
}

// 지표 위젯: 큰 퍼센트 숫자 + 임계치 색상 막대
function StatWidget({ icon, label, percent, detail }: {
  icon: React.ReactNode; label: string; percent: number; detail?: string;
}) {
  const color = percent >= 90 ? 'bg-red-400' : percent >= 70 ? 'bg-amber-400' : 'bg-blue-400';
  return (
    <div className="rounded-2xl bg-white/[0.06] border border-white/10 backdrop-blur p-5">
      <div className="flex items-center gap-2 text-sm text-slate-400">{icon} {label}</div>
      <div className="mt-2 text-3xl font-semibold text-white tabular-nums">
        {percent.toFixed(0)}<span className="text-base font-normal text-slate-400">%</span>
      </div>
      <div className="mt-3 h-1.5 rounded-full bg-white/10 overflow-hidden">
        <div className={`${color} h-full transition-all duration-500`} style={{ width: `${percent}%` }} />
      </div>
      {detail && <p className="mt-2.5 text-xs text-slate-500">{detail}</p>}
    </div>
  );
}

export default function Dashboard() {
  const { t } = useI18n();
  const navigate = useNavigate();
  const [stats, setStats] = useState<SystemStatus | null>(null);
  const [apps, setApps] = useState<InstalledApp[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  const handleAuthError = useCallback((err: any) => {
    if (err?.response?.status === 401) { navigate('/login'); return true; }
    return false;
  }, [navigate]);

  const fetchAll = useCallback(async () => {
    try {
      const [s, a] = await Promise.all([
        axios.get('/api/status'),
        axios.get('/api/apps/installed').catch(() => null), // 앱 목록 실패는 지표 표시를 막지 않는다
      ]);
      setStats(s.data);
      if (a) setApps(a.data.apps);
      setError(null);
    } catch (err: any) {
      if (handleAuthError(err)) return;
      setError(t('errStatus'));
    }
  }, [handleAuthError, t]);

  // 시스템 상태 + 앱 상태 폴링 (5초)
  useEffect(() => {
    fetchAll();
    const id = setInterval(fetchAll, 5000);
    return () => clearInterval(id);
  }, [fetchAll]);

  // 실행 중이면 앱 웹 UI 를 새 탭으로, 아니면 관리 페이지(내 앱)로
  const openApp = (app: InstalledApp) => {
    if (app.state === 'running' && app.web_ui_port) {
      const url = `http://${window.location.hostname}:${app.web_ui_port}${app.web_ui_path || '/'}`;
      window.open(url, '_blank', 'noopener');
    } else {
      navigate('/apps');
    }
  };

  return (
    <div className="space-y-8">
      {error && (
        <div className="p-4 rounded-xl bg-red-500/10 border border-red-500/20 text-red-300 flex items-center gap-2">
          <AlertCircle size={20} /> {error}
        </div>
      )}

      {!stats ? (
        <div className="text-center py-16 text-slate-500">
          <Loader2 className="animate-spin inline mr-2" /> {t('loading')}
        </div>
      ) : (
        <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
          <StatWidget icon={<Cpu size={15} />} label="CPU" percent={stats.cpu_percent} />
          <StatWidget icon={<MemoryStick size={15} />} label={t('memory')} percent={stats.memory_percent} />
          <StatWidget icon={<HardDrive size={15} />} label={t('sysDisk')} percent={stats.disk_percent}
            detail={`${stats.disk_free} / ${stats.disk_total}`} />
          <div className="rounded-2xl bg-white/[0.06] border border-white/10 backdrop-blur p-5">
            <div className="flex items-center gap-2 text-sm text-slate-400"><Database size={15} /> {t('dataDisk')}</div>
            <div className="mt-2 text-3xl font-semibold text-white tabular-nums">{stats.data_free}</div>
            <p className="mt-2.5 text-xs text-slate-500">/ {stats.data_total}</p>
          </div>
        </div>
      )}

      <section>
        <h2 className="font-semibold text-white flex items-center gap-2 mb-4">
          <Boxes size={18} className="text-slate-400" /> {t('myApps')}
        </h2>

        {apps && apps.length === 0 ? (
          <div className="rounded-2xl bg-white/[0.04] border border-dashed border-white/10 p-10 text-center text-slate-500">
            <Boxes size={36} className="mx-auto mb-3 text-slate-700" />
            <p className="mb-4">{t('noApps')}</p>
            <Link to="/apps/store"
              className="inline-flex items-center gap-1.5 text-sm bg-blue-500 text-white px-4 py-2 rounded-full hover:bg-blue-400 transition-colors">
              <Store size={15} /> {t('browseStore')}
            </Link>
          </div>
        ) : (
          <div className="grid grid-cols-3 sm:grid-cols-4 md:grid-cols-6 gap-3">
            {(apps || []).map(app => (
              <button key={app.id} onClick={() => openApp(app)} title={app.name}
                className="rounded-2xl bg-white/[0.06] border border-white/10 backdrop-blur p-4 flex flex-col items-center gap-2.5 hover:bg-white/[0.12] transition-colors">
                <div className="relative">
                  <AppIcon name={app.icon} color={app.color} size={24} />
                  <span className={`absolute -right-0.5 -bottom-0.5 h-2.5 w-2.5 rounded-full ring-2 ring-slate-950 ${
                    app.state === 'running' ? 'bg-green-400' : 'bg-slate-600'
                  }`} />
                </div>
                <span className="text-xs text-slate-300 truncate w-full text-center">{app.name}</span>
              </button>
            ))}
            <Link to="/apps/store"
              className="rounded-2xl border border-dashed border-white/15 p-4 flex flex-col items-center justify-center gap-2.5 text-slate-500 hover:text-white hover:bg-white/[0.06] transition-colors">
              <Store size={24} />
              <span className="text-xs">{t('navStore')}</span>
            </Link>
          </div>
        )}
      </section>
    </div>
  );
}
