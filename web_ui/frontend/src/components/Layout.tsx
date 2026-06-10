import { useEffect, useState } from 'react';
import { NavLink, Outlet, useNavigate } from 'react-router-dom';
import axios from 'axios';
import { Server, LogOut, LayoutDashboard, Boxes, Store, Settings } from 'lucide-react';
import { useI18n } from '../i18n';

// 인증된 영역 공통 셸 — CasaOS 풍 다크 위젯 홈.
// 설치/셋업 마법사(밝은 카드 UI)와 달리 운영 화면(대시보드·앱·스토어·설정)은
// 어두운 배경 위 글래스 카드로 렌더된다. 각 페이지는 본문만 렌더한다.
export default function Layout() {
  const { t } = useI18n();
  const navigate = useNavigate();
  const [info, setInfo] = useState<{ hostname?: string; version?: string; active_slot?: string }>({});

  useEffect(() => {
    axios.get('/api/status')
      .then(r => setInfo(r.data))
      .catch(err => { if (err?.response?.status === 401) navigate('/login'); });
  }, [navigate]);

  const logout = async () => {
    try { await axios.get('/logout'); } catch { /* 무시: 어차피 로그인 화면으로 */ }
    navigate('/login');
  };

  const tab = ({ isActive }: { isActive: boolean }) =>
    `flex items-center gap-2 px-4 py-2 rounded-full text-sm font-medium transition-colors ${
      isActive ? 'bg-white/15 text-white' : 'text-slate-400 hover:text-white hover:bg-white/10'
    }`;

  const iconBtn = ({ isActive }: { isActive: boolean }) =>
    `p-2 rounded-full transition-colors ${
      isActive ? 'bg-white/15 text-white' : 'text-slate-400 hover:text-white hover:bg-white/10'
    }`;

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100">
      {/* 상단 푸른 광원 — 단색 다크 배경의 밋밋함을 줄이는 장식 */}
      <div className="pointer-events-none fixed inset-x-0 top-0 h-96 bg-[radial-gradient(ellipse_at_top,rgba(59,130,246,0.22),transparent_65%)]" />

      <div className="relative max-w-5xl mx-auto px-4">
        <header className="pt-8 pb-5 flex items-center justify-between">
          <h1 className="text-xl font-bold flex items-center gap-2.5">
            <span className="bg-blue-500/20 text-blue-300 rounded-xl p-2"><Server size={20} /></span>
            {info.hostname || 'LukeNasOS'}
          </h1>
          <div className="flex items-center gap-2">
            {info.version && (
              <span className="hidden sm:inline text-xs bg-white/10 text-slate-300 px-3 py-1.5 rounded-full font-mono">
                v{info.version}{info.active_slot ? ` · ${info.active_slot}` : ''}
              </span>
            )}
            <NavLink to="/settings" title={t('navSettings')} className={iconBtn}>
              <Settings size={18} />
            </NavLink>
            <button onClick={logout} title={t('logout')}
              className="p-2 rounded-full text-slate-400 hover:text-white hover:bg-white/10 transition-colors">
              <LogOut size={18} />
            </button>
          </div>
        </header>

        <nav className="pb-6 flex gap-1.5">
          <NavLink to="/" end className={tab}><LayoutDashboard size={16} /> {t('navDashboard')}</NavLink>
          <NavLink to="/apps" end className={tab}><Boxes size={16} /> {t('navApps')}</NavLink>
          <NavLink to="/apps/store" className={tab}><Store size={16} /> {t('navStore')}</NavLink>
        </nav>

        <main className="pb-16">
          <Outlet />
        </main>
      </div>
    </div>
  );
}
