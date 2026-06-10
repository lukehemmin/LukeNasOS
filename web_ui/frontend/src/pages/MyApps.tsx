import { useState, useEffect, useCallback, useRef } from 'react';
import { useNavigate, Link } from 'react-router-dom';
import axios from 'axios';
import {
  ExternalLink, Play, Square, Trash2, RotateCw, Loader2, AlertCircle, Boxes, Store,
} from 'lucide-react';
import AppCard from '../components/AppCard';
import { useI18n } from '../i18n';

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
  const { t } = useI18n();
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
      setError(t('errApps'));
    }
  }, [handleAuthError, t]);

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
      if (!handleAuthError(err)) alert(t('errActionPrefix') + (err.response?.data?.message || err.message));
    } finally {
      setAppBusy(id, false);
    }
  };

  const uninstall = async (app: InstalledApp) => {
    if (!confirm(t('confirmUninstallFmt', { name: app.name }))) return;
    const deleteData = confirm(t('confirmDeleteData'));
    setAppBusy(app.id, true);
    try {
      await axios.delete(`/api/apps/${app.id}${deleteData ? '?delete_data=1' : ''}`);
      await fetchApps();
    } catch (err: any) {
      if (!handleAuthError(err)) alert(t('errDeletePrefix') + (err.response?.data?.message || err.message));
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
        running ? 'bg-green-500/15 text-green-300' : 'bg-white/10 text-slate-400'
      }`}>
        {running ? t('running') : state === 'stopped' ? t('stopped') : state}
      </span>
    );
  };

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h2 className="text-lg font-semibold text-white flex items-center gap-2">
          <Boxes size={20} className="text-slate-400" /> {t('myApps')}
        </h2>
        <Link to="/apps/store" className="flex items-center gap-1.5 text-sm bg-blue-500 text-white px-4 py-2 rounded-lg hover:bg-blue-400 transition-colors">
          <Store size={16} /> {t('navStore')}
        </Link>
      </div>

      {error && (
        <div className="p-4 rounded-xl bg-red-500/10 border border-red-500/20 text-red-300 flex items-center gap-2">
          <AlertCircle size={20} /> {error}
        </div>
      )}

      {!apps ? (
        <div className="text-center py-12 text-slate-500">
          <Loader2 className="animate-spin inline mr-2" /> {t('loading')}
        </div>
      ) : apps.length === 0 ? (
        <div className="rounded-2xl bg-white/[0.04] border border-dashed border-white/10 p-10 text-center text-slate-500">
          <Boxes size={40} className="mx-auto mb-3 text-slate-700" />
          <p className="mb-4">{t('noApps')}</p>
          <Link to="/apps/store" className="inline-flex items-center gap-1.5 text-sm bg-blue-500 text-white px-4 py-2 rounded-lg hover:bg-blue-400 transition-colors">
            <Store size={16} /> {t('browseStore')}
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
                    className="flex-1 flex items-center justify-center gap-1.5 text-sm bg-blue-500 text-white px-3 py-2 rounded-lg hover:bg-blue-400 transition-colors">
                    <ExternalLink size={15} /> {t('open')}
                  </button>
                )}
                {running ? (
                  <button onClick={() => action(app.id, 'stop')} disabled={isBusy} title={t('stop')}
                    className="flex items-center justify-center px-3 py-2 rounded-lg border border-white/15 text-slate-300 hover:bg-white/10 disabled:opacity-50 transition-colors">
                    {isBusy ? <Loader2 size={15} className="animate-spin" /> : <Square size={15} />}
                  </button>
                ) : (
                  <button onClick={() => action(app.id, 'start')} disabled={isBusy} title={t('start')}
                    className="flex-1 flex items-center justify-center gap-1.5 text-sm bg-green-500 text-white px-3 py-2 rounded-lg hover:bg-green-400 disabled:opacity-50 transition-colors">
                    {isBusy ? <Loader2 size={15} className="animate-spin" /> : <Play size={15} />} {t('start')}
                  </button>
                )}
                <button onClick={() => action(app.id, 'restart')} disabled={isBusy} title={t('restart')}
                  className="flex items-center justify-center px-3 py-2 rounded-lg border border-white/15 text-slate-300 hover:bg-white/10 disabled:opacity-50 transition-colors">
                  <RotateCw size={15} />
                </button>
                <button onClick={() => uninstall(app)} disabled={isBusy} title={t('deleteLabel')}
                  className="flex items-center justify-center px-3 py-2 rounded-lg border border-red-500/30 text-red-400 hover:bg-red-500/10 disabled:opacity-50 transition-colors">
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
