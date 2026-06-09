import { useEffect, useState } from 'react';
import { NavLink, Outlet, useNavigate } from 'react-router-dom';
import axios from 'axios';
import { Server, LogOut, LayoutDashboard, Boxes, Store } from 'lucide-react';

// 인증된 영역 공통 셸: 상단 헤더(호스트명·버전·로그아웃) + 탭 내비.
// 각 페이지(Dashboard/MyApps/AppStore)는 본문만 렌더한다.
export default function Layout() {
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
    `flex items-center gap-2 px-4 py-2 rounded-lg text-sm font-medium transition-colors ${
      isActive ? 'bg-blue-600 text-white' : 'text-gray-600 hover:bg-gray-200'
    }`;

  return (
    <div className="min-h-screen bg-gray-100">
      <header className="bg-blue-600 text-white shadow-lg">
        <div className="max-w-5xl mx-auto px-4 py-4 flex items-center justify-between">
          <h1 className="text-xl font-bold flex items-center gap-2">
            <Server /> {info.hostname || 'LukeNasOS'}
          </h1>
          <div className="flex items-center gap-3">
            {info.version && (
              <span className="text-sm bg-blue-700 px-3 py-1 rounded-full font-mono">
                v{info.version}{info.active_slot ? ` · slot ${info.active_slot}` : ''}
              </span>
            )}
            <button onClick={logout} className="flex items-center gap-1 text-sm bg-blue-700 hover:bg-blue-800 px-3 py-1.5 rounded-lg">
              <LogOut size={16} /> 로그아웃
            </button>
          </div>
        </div>
      </header>

      <nav className="bg-white border-b shadow-sm">
        <div className="max-w-5xl mx-auto px-4 py-2 flex gap-2">
          <NavLink to="/" end className={tab}><LayoutDashboard size={16} /> 대시보드</NavLink>
          <NavLink to="/apps" end className={tab}><Boxes size={16} /> 앱</NavLink>
          <NavLink to="/apps/store" className={tab}><Store size={16} /> 앱스토어</NavLink>
        </div>
      </nav>

      <main className="max-w-5xl mx-auto p-4">
        <Outlet />
      </main>
    </div>
  );
}
