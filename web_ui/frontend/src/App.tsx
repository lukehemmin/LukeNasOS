import { Routes, Route, Navigate, useNavigate } from 'react-router-dom';
import { useState, useEffect, useCallback } from 'react';
import axios from 'axios';
import Installer from './pages/Installer';
import Setup from './pages/Setup';
import Login from './pages/Login';
import Dashboard from './pages/Dashboard';

const Loading = () => (
  <div className="min-h-screen flex items-center justify-center">
    <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-blue-600"></div>
  </div>
);

function App() {
  const [status, setStatus] = useState<'loading' | 'installer' | 'setup' | 'login' | 'dashboard'>('loading');
  const navigate = useNavigate();

  // 시스템 상태로 첫 화면을 결정한다. 로그인/설정 성공 후 자식이 다시 호출(refresh)하면
  // 갱신된 상태에 맞춰 적절한 화면으로 이동한다 (단일 진실 공급원).
  const checkSystemStatus = useCallback(async () => {
    try {
      const res = await axios.get('/api/system/status');
      const { is_installer_mode, setup_completed, logged_in } = res.data;

      if (is_installer_mode) {
        setStatus('installer');
        navigate('/install');
      } else if (!setup_completed) {
        // 첫 부팅: 계정이 없으므로 최초 설정(setup) 화면으로
        setStatus('setup');
        navigate('/setup');
      } else if (!logged_in) {
        setStatus('login');
        navigate('/login');
      } else {
        setStatus('dashboard');
        navigate('/');
      }
    } catch (error) {
      console.error('Failed to fetch system status:', error);
    }
  }, [navigate]);

  useEffect(() => {
    checkSystemStatus();
  }, [checkSystemStatus]);

  if (status === 'loading') return <Loading />;

  return (
    <Routes>
      <Route path="/install" element={<Installer />} />
      <Route path="/setup" element={<Setup onDone={checkSystemStatus} />} />
      <Route path="/login" element={<Login onDone={checkSystemStatus} />} />
      <Route path="/" element={<Dashboard />} />
      <Route path="*" element={<Navigate to={status === 'installer' ? '/install' : '/'} replace />} />
    </Routes>
  );
}

export default App;
