import { useState } from 'react';
import axios from 'axios';
import { Server, AlertCircle, Loader2, User, Lock } from 'lucide-react';
import { useI18n } from '../i18n';

interface LoginProps {
  onDone: () => Promise<void> | void;
}

export default function Login({ onDone }: LoginProps) {
  const { t } = useI18n();
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    if (!username || !password) {
      setError(t('errLoginRequired'));
      return;
    }
    setBusy(true);
    try {
      await axios.post('/login', { username, password });
      await onDone(); // 상태 갱신 → 대시보드로 이동
    } catch (err: any) {
      setError(err.response?.data?.message || t('errLoginFailed'));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="min-h-screen bg-gray-100 flex items-center justify-center p-4">
      <div className="max-w-md w-full bg-white rounded-xl shadow-lg overflow-hidden">
        <div className="bg-blue-600 p-6 text-white text-center">
          <h1 className="text-2xl font-bold flex items-center justify-center gap-2">
            <Server /> {t('loginTitle')}
          </h1>
        </div>

        <form className="p-8 space-y-5" onSubmit={submit}>
          {error && (
            <div className="p-4 bg-red-50 text-red-700 rounded-lg flex items-center gap-2">
              <AlertCircle size={20} /> {error}
            </div>
          )}

          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">{t('loginId')}</label>
            <div className="flex items-center gap-2 border rounded-lg px-3">
              <User size={18} className="text-gray-400" />
              <input
                type="text"
                value={username}
                onChange={e => setUsername(e.target.value)}
                className="w-full p-2 outline-none"
                autoFocus
              />
            </div>
          </div>

          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">{t('passwordLabel')}</label>
            <div className="flex items-center gap-2 border rounded-lg px-3">
              <Lock size={18} className="text-gray-400" />
              <input
                type="password"
                value={password}
                onChange={e => setPassword(e.target.value)}
                className="w-full p-2 outline-none"
              />
            </div>
          </div>

          <button
            type="submit"
            disabled={busy}
            className="w-full px-6 py-3 bg-blue-600 text-white rounded-lg hover:bg-blue-700 font-medium disabled:opacity-50 disabled:cursor-not-allowed flex items-center justify-center gap-2"
          >
            {busy && <Loader2 className="animate-spin" size={18} />}
            {t('loginBtn')}
          </button>
        </form>
      </div>
    </div>
  );
}
