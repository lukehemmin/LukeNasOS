import { useState, useEffect, useCallback, useRef } from 'react';
import { useNavigate } from 'react-router-dom';
import axios from 'axios';
import {
  Cpu, MemoryStick, HardDrive, Database, Power, Upload,
  Loader2, AlertCircle, RefreshCw,
} from 'lucide-react';

interface SystemStatus {
  system: string;
  release: string;
  hostname: string;
  version: string;
  active_slot: string;
  cpu_percent: number;
  memory_percent: number;
  disk_percent: number;
  disk_free: string;
  disk_total: string;
  data_free: string;
  data_total: string;
}

interface UpdateStatus {
  active_slot: string;
  inactive_slot: string;
  status: 'idle' | 'installing' | 'success' | 'error';
  message: string;
  progress: number;
}

// 사용률 막대 (색상은 임계치에 따라)
function UsageBar({ label, percent, icon }: { label: string; percent: number; icon: React.ReactNode }) {
  const color = percent >= 90 ? 'bg-red-500' : percent >= 70 ? 'bg-yellow-500' : 'bg-blue-600';
  return (
    <div>
      <div className="flex items-center justify-between text-sm mb-1">
        <span className="flex items-center gap-2 text-gray-600">{icon} {label}</span>
        <span className="font-mono">{percent.toFixed(0)}%</span>
      </div>
      <div className="w-full bg-gray-200 rounded-full h-2.5 overflow-hidden">
        <div className={`${color} h-2.5 transition-all duration-500`} style={{ width: `${percent}%` }} />
      </div>
    </div>
  );
}

export default function Dashboard() {
  const navigate = useNavigate();
  const [stats, setStats] = useState<SystemStatus | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [file, setFile] = useState<File | null>(null);
  const [update, setUpdate] = useState<UpdateStatus | null>(null);
  const [uploading, setUploading] = useState(false);
  const updatePoll = useRef<any>(null);

  // 401 이면 로그인으로 (가드와 정합)
  const handleAuthError = useCallback((err: any) => {
    if (err?.response?.status === 401) {
      navigate('/login');
      return true;
    }
    return false;
  }, [navigate]);

  const fetchStatus = useCallback(async () => {
    try {
      const res = await axios.get('/api/status');
      setStats(res.data);
      setError(null);
    } catch (err: any) {
      if (handleAuthError(err)) return;
      setError('시스템 상태를 불러오지 못했습니다.');
    }
  }, [handleAuthError]);

  // 시스템 상태 폴링 (5초)
  useEffect(() => {
    fetchStatus();
    const id = setInterval(fetchStatus, 5000);
    return () => clearInterval(id);
  }, [fetchStatus]);

  // 업데이트 진행 폴링 (설치 중에만)
  const pollUpdate = useCallback(() => {
    if (updatePoll.current) clearInterval(updatePoll.current);
    updatePoll.current = setInterval(async () => {
      try {
        const res = await axios.get('/api/update/status');
        const u: UpdateStatus = res.data;
        setUpdate(u);
        if (u.status === 'success' || u.status === 'error') {
          clearInterval(updatePoll.current);
          setUploading(false);
        }
      } catch (err: any) {
        if (handleAuthError(err)) return;
        clearInterval(updatePoll.current);
        setUploading(false);
      }
    }, 1000);
  }, [handleAuthError]);

  useEffect(() => () => { if (updatePoll.current) clearInterval(updatePoll.current); }, []);

  const startUpdate = async () => {
    if (!file) return;
    setError(null);
    setUploading(true);
    setUpdate({ active_slot: '', inactive_slot: '', status: 'installing', message: '업로드 중...', progress: 0 });
    try {
      const form = new FormData();
      form.append('update_file', file);
      await axios.post('/api/upload_update', form, { headers: { 'Content-Type': 'multipart/form-data' } });
      pollUpdate();
    } catch (err: any) {
      if (handleAuthError(err)) return;
      setUploading(false);
      setUpdate(null);
      setError(err.response?.data?.message || '업데이트 시작에 실패했습니다.');
    }
  };

  const reboot = async () => {
    if (!confirm('시스템을 재부팅하시겠습니까?')) return;
    try {
      await axios.post('/api/system/reboot');
      alert('재부팅 중입니다...');
    } catch (err: any) {
      if (handleAuthError(err)) return;
      alert('재부팅 실패: ' + (err.response?.data?.message || err.message));
    }
  };

  return (
    <div className="space-y-6">
        {error && (
          <div className="p-4 bg-red-50 text-red-700 rounded-lg flex items-center gap-2">
            <AlertCircle size={20} /> {error}
          </div>
        )}

        {/* 시스템 정보 */}
        <div className="bg-white rounded-xl shadow-lg p-6">
          <h2 className="text-lg font-semibold mb-4 flex items-center gap-2">
            <RefreshCw size={18} className="text-gray-400" /> 시스템 상태
          </h2>
          {!stats ? (
            <div className="text-center py-8 text-gray-500">
              <Loader2 className="animate-spin inline mr-2" /> 불러오는 중...
            </div>
          ) : (
            <div className="space-y-4">
              <UsageBar label="CPU" percent={stats.cpu_percent} icon={<Cpu size={16} />} />
              <UsageBar label="메모리" percent={stats.memory_percent} icon={<MemoryStick size={16} />} />
              <UsageBar label="시스템 디스크" percent={stats.disk_percent} icon={<HardDrive size={16} />} />
              <div className="grid grid-cols-2 gap-4 pt-2 text-sm">
                <div className="flex items-center gap-2 text-gray-600">
                  <HardDrive size={16} /> 시스템: {stats.disk_free} / {stats.disk_total} 여유
                </div>
                <div className="flex items-center gap-2 text-gray-600">
                  <Database size={16} /> 데이터: {stats.data_free} / {stats.data_total} 여유
                </div>
              </div>
            </div>
          )}
        </div>

        {/* 업데이트 */}
        <div className="bg-white rounded-xl shadow-lg p-6">
          <h2 className="text-lg font-semibold mb-4 flex items-center gap-2">
            <Upload size={18} className="text-gray-400" /> 시스템 업데이트
          </h2>

          {update && update.status !== 'idle' ? (
            <div className="space-y-3">
              {update.status === 'installing' && (
                <>
                  <div className="w-full bg-gray-200 rounded-full h-4 overflow-hidden">
                    <div className="bg-blue-600 h-4 transition-all duration-500" style={{ width: `${update.progress}%` }} />
                  </div>
                  <p className="text-gray-600 font-mono text-sm flex items-center gap-2">
                    <Loader2 className="animate-spin" size={16} /> {update.message}
                  </p>
                </>
              )}
              {update.status === 'success' && (
                <div className="p-4 bg-green-50 text-green-700 rounded-lg">
                  {update.message} 재부팅 후 새 버전으로 부팅됩니다.
                </div>
              )}
              {update.status === 'error' && (
                <div className="p-4 bg-red-50 text-red-700 rounded-lg flex items-center gap-2">
                  <AlertCircle size={20} /> {update.message}
                </div>
              )}
            </div>
          ) : (
            <div className="flex flex-col sm:flex-row sm:items-center gap-3">
              <input
                type="file"
                accept=".raucb"
                onChange={e => setFile(e.target.files?.[0] || null)}
                className="flex-1 text-sm text-gray-600 file:mr-3 file:py-2 file:px-4 file:rounded-lg file:border-0 file:bg-blue-50 file:text-blue-700 hover:file:bg-blue-100"
              />
              <button
                onClick={startUpdate}
                disabled={!file || uploading}
                className="px-6 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed flex items-center justify-center gap-2"
              >
                {uploading && <Loader2 className="animate-spin" size={16} />} 업데이트 설치
              </button>
            </div>
          )}
          <p className="text-xs text-gray-400 mt-3">
            서명된 <code>.raucb</code> 번들을 업로드하면 비활성 슬롯({update?.inactive_slot || 'B'})에 설치됩니다.
          </p>
        </div>

        {/* 전원 */}
        <div className="bg-white rounded-xl shadow-lg p-6 flex items-center justify-between">
          <span className="text-gray-600">시스템 재부팅</span>
          <button onClick={reboot} className="px-6 py-2 bg-red-600 text-white rounded-lg hover:bg-red-700 font-medium flex items-center gap-2">
            <Power size={18} /> 재부팅
          </button>
        </div>
    </div>
  );
}
