import { useState } from 'react';
import axios from 'axios';
import { Server, AlertCircle, Loader2, User, Lock, HardDrive } from 'lucide-react';

interface SetupProps {
  onDone: () => Promise<void> | void;
}

export default function Setup({ onDone }: SetupProps) {
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [hostname, setHostname] = useState('lukenas');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);

    if (!username || !password) {
      setError('관리자 ID와 비밀번호는 필수입니다.');
      return;
    }
    if (password !== confirm) {
      setError('비밀번호가 일치하지 않습니다.');
      return;
    }

    setBusy(true);
    try {
      // 성공 시 백엔드가 세션도 설정(자동 로그인) → onDone() 이 대시보드로 보냄
      await axios.post('/setup', { username, password, hostname });
      await onDone();
    } catch (err: any) {
      setError(err.response?.data?.message || err.message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="min-h-screen bg-gray-100 flex items-center justify-center p-4">
      <div className="max-w-md w-full bg-white rounded-xl shadow-lg overflow-hidden">
        <div className="bg-blue-600 p-6 text-white text-center">
          <h1 className="text-2xl font-bold flex items-center justify-center gap-2">
            <Server /> LukeNasOS 초기 설정
          </h1>
        </div>

        <form className="p-8 space-y-5" onSubmit={submit}>
          <p className="text-gray-600 text-sm text-center">
            관리자 계정을 만들어 시스템을 시작하세요.
          </p>

          {error && (
            <div className="p-4 bg-red-50 text-red-700 rounded-lg flex items-center gap-2">
              <AlertCircle size={20} /> {error}
            </div>
          )}

          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">관리자 ID</label>
            <div className="flex items-center gap-2 border rounded-lg px-3">
              <User size={18} className="text-gray-400" />
              <input
                type="text"
                value={username}
                onChange={e => setUsername(e.target.value)}
                placeholder="admin"
                className="w-full p-2 outline-none"
                autoFocus
              />
            </div>
          </div>

          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">비밀번호</label>
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

          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">비밀번호 확인</label>
            <div className="flex items-center gap-2 border rounded-lg px-3">
              <Lock size={18} className="text-gray-400" />
              <input
                type="password"
                value={confirm}
                onChange={e => setConfirm(e.target.value)}
                className="w-full p-2 outline-none"
              />
            </div>
          </div>

          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">NAS 이름 (Hostname)</label>
            <div className="flex items-center gap-2 border rounded-lg px-3">
              <HardDrive size={18} className="text-gray-400" />
              <input
                type="text"
                value={hostname}
                onChange={e => setHostname(e.target.value)}
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
            설정 완료 및 시작
          </button>
        </form>
      </div>
    </div>
  );
}
