import { Routes, Route, Navigate, useNavigate } from 'react-router-dom';
import { useState, useEffect, useCallback } from 'react';
import axios from 'axios';
import Installer from './pages/Installer';
import Setup from './pages/Setup';
import Login from './pages/Login';
import Layout from './components/Layout';
import Dashboard from './pages/Dashboard';
import MyApps from './pages/MyApps';
import AppStore from './pages/AppStore';
import Settings from './pages/Settings';
import { isLang, useI18n } from './i18n';

const Loading = () => (
  <div className="min-h-screen flex items-center justify-center">
    <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-blue-600"></div>
  </div>
);

function App() {
  const [status, setStatus] = useState<'loading' | 'installer' | 'setup' | 'login' | 'dashboard'>('loading');
  const navigate = useNavigate();
  const { setLang } = useI18n();

  // 시스템 상태로 첫 화면을 결정한다. 로그인/설정 성공 후 자식이 다시 호출(refresh)하면
  // 갱신된 상태에 맞춰 적절한 화면으로 이동한다 (단일 진실 공급원).
  const checkSystemStatus = useCallback(async () => {
    try {
      const res = await axios.get('/api/system/status');
      const { is_installer_mode, setup_completed, logged_in, language } = res.data;

      // 셋업 때 저장된 언어를 복원 (settings.json → 모든 운영 화면에 적용)
      if (isLang(language)) setLang(language);

      // useNavigate 의 navigate 는 경로가 바뀔 때마다 새 함수가 되어 이 콜백(=effect)이
      // 재실행된다. 매번 무조건 navigate 하면 탭 이동(/apps 등)이 대시보드로 덮어써지므로,
      // 현재 경로가 해당 상태에 맞지 않을 때만 이동한다.
      const path = window.location.pathname;
      if (is_installer_mode) {
        setStatus('installer');
        if (path !== '/install') navigate('/install');
      } else if (!setup_completed) {
        // 첫 부팅: 계정이 없으므로 최초 설정(setup) 화면으로
        setStatus('setup');
        if (path !== '/setup') navigate('/setup');
      } else if (!logged_in) {
        setStatus('login');
        if (path !== '/login') navigate('/login');
      } else {
        setStatus('dashboard');
        // 이미 인증 영역(대시보드/앱/앱스토어)에 있으면 현재 경로를 유지한다
        if (path === '/install' || path === '/setup' || path === '/login') navigate('/');
      }
    } catch (error) {
      console.error('Failed to fetch system status:', error);
    }
  }, [navigate, setLang]);

  useEffect(() => {
    checkSystemStatus();
  }, [checkSystemStatus]);

  if (status === 'loading') return <Loading />;

  return (
    <Routes>
      <Route path="/install" element={<Installer />} />
      <Route path="/setup" element={<Setup onDone={checkSystemStatus} />} />
      <Route path="/login" element={<Login onDone={checkSystemStatus} />} />
      {/* 인증된 영역: Layout 셸(헤더 + 탭 내비)이 페이지를 감싼다 */}
      <Route element={<Layout />}>
        <Route path="/" element={<Dashboard />} />
        <Route path="/apps" element={<MyApps />} />
        <Route path="/apps/store" element={<AppStore />} />
        <Route path="/settings" element={<Settings />} />
      </Route>
      <Route path="*" element={<Navigate to={status === 'installer' ? '/install' : '/'} replace />} />
    </Routes>
  );
}

export default App;
