import { Routes, Route, Navigate, useNavigate } from 'react-router-dom';
import { useState, useEffect } from 'react';
import axios from 'axios';
import Installer from './pages/Installer';

const Loading = () => (
  <div className="min-h-screen flex items-center justify-center">
    <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-blue-600"></div>
  </div>
);

const Dashboard = () => <div className="p-8 text-2xl">Dashboard (Coming Soon)</div>;
const Login = () => <div className="p-8 text-2xl">Login Page (Coming Soon)</div>;

function App() {
  const [status, setStatus] = useState<'loading' | 'installer' | 'setup' | 'login' | 'dashboard'>('loading');
  const navigate = useNavigate();

  useEffect(() => {
    checkSystemStatus();
  }, []);

  const checkSystemStatus = async () => {
    try {
      const res = await axios.get('/api/system/status');
      const { is_installer_mode, setup_completed, logged_in } = res.data;

      if (is_installer_mode) {
        setStatus('installer');
        navigate('/install');
      } else if (!setup_completed) {
        setStatus('setup');
        // navigate('/setup'); // Not implemented yet, use login for now
        navigate('/login');
      } else if (!logged_in) {
        setStatus('login');
        navigate('/login');
      } else {
        setStatus('dashboard');
        navigate('/');
      }
    } catch (error) {
      console.error("Failed to fetch system status:", error);
      // Retry after delay?
      // For now, just stay loading or show error
    }
  };

  if (status === 'loading') return <Loading />;

  return (
    <Routes>
      <Route path="/install" element={<Installer />} />
      <Route path="/login" element={<Login />} />
      <Route path="/" element={<Dashboard />} />
      <Route path="*" element={<Navigate to={status === 'installer' ? '/install' : '/'} replace />} />
    </Routes>
  );
}

export default App;