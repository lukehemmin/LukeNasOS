import { useState, useEffect } from 'react';
import axios from 'axios';
import { motion, AnimatePresence } from 'framer-motion';
import {
  HardDrive, Server, Power, AlertCircle, AlertTriangle, CheckCircle2,
  Loader2, Check, ShieldCheck, Boxes, Globe, ArrowRight, ArrowLeft,
  Usb, RotateCw,
} from 'lucide-react';

// 설치 마법사는 영어 전용. 언어·시간대·NAS 이름은 설치 후 첫 부팅의 셋업 과정에서 설정한다.

interface Disk {
  name: string;
  model: string;
  size: string;
}

// 설치 단계 정의 (백엔드 progress % 구간과 매핑)
const PHASES = [
  { label: 'Partitioning disk', from: 0 },
  { label: 'Mounting filesystems', from: 30 },
  { label: 'Copying system files', from: 40 },
  { label: 'Configuring system', from: 75 },
  { label: 'Preparing recovery slot', from: 80 },
  { label: 'Optimizing boot image', from: 85 },
  { label: 'Installing bootloader', from: 90 },
  { label: 'Finishing up', from: 99 },
];

const STEPS = ['Start', 'Disk', 'Install', 'Done'];

function StepIndicator({ current }: { current: number }) {
  return (
    <div className="px-8 pt-6">
      <div className="flex items-center">
        {STEPS.map((label, i) => {
          const n = i + 1;
          const done = current > n;
          const active = current === n;
          return (
            <div key={label} className={`flex items-center ${i < STEPS.length - 1 ? 'flex-1' : ''}`}>
              <div className="flex flex-col items-center">
                <div
                  className={`w-8 h-8 rounded-full flex items-center justify-center text-sm font-semibold transition-colors ${
                    done ? 'bg-blue-600 text-white'
                    : active ? 'bg-blue-600 text-white ring-4 ring-blue-100'
                    : 'bg-gray-200 text-gray-500'
                  }`}
                >
                  {done ? <Check size={16} /> : n}
                </div>
                <span className={`mt-1.5 text-xs whitespace-nowrap ${active ? 'text-blue-700 font-semibold' : 'text-gray-400'}`}>
                  {label}
                </span>
              </div>
              {i < STEPS.length - 1 && (
                <div className={`flex-1 h-0.5 mx-2 mb-5 rounded ${done ? 'bg-blue-600' : 'bg-gray-200'}`} />
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}

// 단계 전환 공통 애니메이션
const stepAnim = {
  initial: { opacity: 0, x: 24 },
  animate: { opacity: 1, x: 0 },
  exit: { opacity: 0, x: -24 },
  transition: { duration: 0.25 },
};

export default function Installer() {
  const [step, setStep] = useState(1);
  const [disks, setDisks] = useState<Disk[]>([]);
  const [selectedDisk, setSelectedDisk] = useState<string | null>(null);
  const [progress, setProgress] = useState(0);
  const [statusMsg, setStatusMsg] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [rebooting, setRebooting] = useState(false);

  // Step 1: Check Installation Status
  useEffect(() => {
    const checkInstallStatus = async () => {
      try {
        const res = await axios.get('/api/install/status');
        // 새로고침 후에도 진행/완료/실패 상태를 백엔드에서 복원한다.
        if (res.data.status === 'installing') {
          setStep(3);
          setProgress(res.data.progress);
          setStatusMsg(res.data.message);
        } else if (res.data.status === 'success') {
          // 설치 완료 화면 유지 (새로고침해도 welcome 으로 되돌아가지 않음)
          setProgress(res.data.progress);
          setStatusMsg(res.data.message);
          setStep(4);
        } else if (res.data.status === 'error') {
          // 실패는 에러를 표시한 채 디스크 선택 단계로 (재시도 가능)
          setError(res.data.message);
          setStep(2);
        }
      } catch (e) {
        console.error('Failed to check install status:', e);
      }
    };

    if (step === 1) {
      checkInstallStatus();
    }
  }, [step]);

  // Step 2: Fetch Disks
  useEffect(() => {
    if (step === 2) {
      axios.get('/api/disks')
        .then(res => setDisks(res.data))
        .catch(err => setError('Failed to load disk list: ' + err.message));
    }
  }, [step]);

  // Step 3: Monitor Progress
  useEffect(() => {
    let interval: any;
    if (step === 3) {
      interval = setInterval(async () => {
        try {
          const res = await axios.get('/api/install/status');
          setProgress(res.data.progress);
          setStatusMsg(res.data.message);
          if (res.data.status === 'success') {
            setStep(4);
            clearInterval(interval);
          } else if (res.data.status === 'error') {
            setError(res.data.message);
            setStep(2);
            clearInterval(interval);
          }
        } catch (e) {
          console.error(e);
        }
      }, 1000);
    }
    return () => clearInterval(interval);
  }, [step]);

  const startInstall = async () => {
    if (!selectedDisk) return;
    setConfirmOpen(false);
    setError(null);
    try {
      const res = await axios.post('/api/install/start', { disk: selectedDisk });
      if (res.data.success) {
        setStep(3);
      } else {
        setError(res.data.message);
      }
    } catch (err: any) {
      setError(err.response?.data?.message || err.message);
    }
  };

  const reboot = async () => {
    try {
      const res = await axios.post('/api/install/reboot');
      if (res.data.success) setRebooting(true);
      else setError('Reboot failed: ' + res.data.message);
    } catch (e: any) {
      setError('Reboot failed: ' + e.message);
    }
  };

  const selected = disks.find(d => d.name === selectedDisk);

  return (
    <div className="min-h-screen bg-gradient-to-br from-slate-100 via-blue-50 to-slate-200 flex items-center justify-center p-4">
      <div className="max-w-2xl w-full">
        <div className="bg-white rounded-2xl shadow-xl ring-1 ring-black/5 overflow-hidden">
          <div className="bg-gradient-to-r from-blue-600 to-indigo-600 px-8 py-6 text-white">
            <h1 className="text-2xl font-bold flex items-center gap-3">
              <span className="bg-white/15 rounded-xl p-2"><Server size={24} /></span>
              Install LukeNasOS
            </h1>
            <p className="text-blue-100 text-sm mt-1 ml-[52px]">Personal NAS operating system setup wizard</p>
          </div>

          <StepIndicator current={step} />

          <div className="p-8 pt-6">
            {error && (
              <div className="mb-5 p-4 bg-red-50 border border-red-100 text-red-700 rounded-xl flex items-start gap-2 text-sm">
                <AlertCircle size={18} className="mt-0.5 shrink-0" /> <span>{error}</span>
              </div>
            )}

            <AnimatePresence mode="wait">
              {step === 1 && (
                <motion.div key="welcome" {...stepAnim} className="space-y-6">
                  <div className="text-center space-y-2">
                    <h2 className="text-xl font-bold text-gray-900">Welcome to LukeNasOS</h2>
                    <p className="text-gray-500 text-sm">
                      Installation takes just a few minutes. All you need is a disk to install to.
                    </p>
                  </div>

                  <div className="grid gap-3">
                    {[
                      { icon: ShieldCheck, title: 'A/B slots + automatic rollback', desc: 'If an update fails, the system automatically recovers to the previous version.' },
                      { icon: Boxes, title: 'Docker-based App Store', desc: 'Install and manage apps (containers) with a single click.' },
                      { icon: Globe, title: 'Manage from anywhere via web', desc: 'After installation, everything works right from your browser.' },
                    ].map(({ icon: Icon, title, desc }) => (
                      <div key={title} className="flex items-start gap-3 p-4 rounded-xl bg-slate-50 border border-slate-100">
                        <span className="bg-blue-100 text-blue-600 rounded-lg p-2 shrink-0"><Icon size={20} /></span>
                        <div>
                          <div className="font-semibold text-gray-800 text-sm">{title}</div>
                          <div className="text-gray-500 text-sm">{desc}</div>
                        </div>
                      </div>
                    ))}
                  </div>

                  <div className="p-4 rounded-xl bg-amber-50 border border-amber-100 text-amber-800 text-sm flex items-start gap-2">
                    <AlertTriangle size={18} className="mt-0.5 shrink-0" />
                    <span>Installing will erase <b>ALL data</b> on the selected disk.</span>
                  </div>

                  <button
                    onClick={() => setStep(2)}
                    className="w-full px-6 py-3.5 bg-blue-600 text-white rounded-xl hover:bg-blue-700 font-semibold flex items-center justify-center gap-2 transition-colors"
                  >
                    Start Installation <ArrowRight size={18} />
                  </button>
                </motion.div>
              )}

              {step === 2 && (
                <motion.div key="disk" {...stepAnim} className="space-y-6">
                  <div>
                    <h2 className="text-xl font-bold text-gray-900">Select Installation Disk</h2>
                    <p className="text-gray-500 text-sm mt-1">LukeNasOS will be installed on this disk. The entire disk will be erased.</p>
                  </div>

                  <div className="space-y-2">
                    {disks.length === 0 ? (
                      <div className="text-center py-10 text-gray-400 text-sm">
                        <Loader2 className="animate-spin inline mr-2" size={18} /> Scanning for disks...
                      </div>
                    ) : (
                      disks.map(disk => {
                        const isSel = selectedDisk === disk.name;
                        return (
                          <button
                            key={disk.name}
                            onClick={() => setSelectedDisk(disk.name)}
                            className={`w-full p-4 rounded-xl flex items-center justify-between transition-all border ${
                              isSel
                                ? 'border-blue-500 bg-blue-50/60 ring-2 ring-blue-100'
                                : 'border-gray-200 hover:border-gray-300 hover:bg-slate-50'
                            }`}
                          >
                            <div className="flex items-center gap-3">
                              <span className={`rounded-lg p-2 ${isSel ? 'bg-blue-100 text-blue-600' : 'bg-gray-100 text-gray-500'}`}>
                                <HardDrive size={20} />
                              </span>
                              <div className="text-left">
                                <div className="font-semibold text-gray-800 font-mono text-sm">{disk.name}</div>
                                <div className="text-sm text-gray-500">{disk.model || 'Unknown model'}</div>
                              </div>
                            </div>
                            <div className="flex items-center gap-3">
                              <span className="font-mono text-xs bg-gray-100 text-gray-600 px-2.5 py-1 rounded-lg">{disk.size}</span>
                              <span className={`w-5 h-5 rounded-full border-2 flex items-center justify-center ${
                                isSel ? 'border-blue-600 bg-blue-600' : 'border-gray-300'
                              }`}>
                                {isSel && <Check size={12} className="text-white" />}
                              </span>
                            </div>
                          </button>
                        );
                      })
                    )}
                  </div>

                  <div className="flex justify-between pt-2">
                    <button
                      onClick={() => setStep(1)}
                      className="px-4 py-2.5 text-gray-500 hover:bg-gray-100 rounded-xl flex items-center gap-1.5 text-sm font-medium transition-colors"
                    >
                      <ArrowLeft size={16} /> Back
                    </button>
                    <button
                      onClick={() => setConfirmOpen(true)}
                      disabled={!selectedDisk}
                      className="px-6 py-2.5 bg-blue-600 text-white rounded-xl hover:bg-blue-700 disabled:opacity-40 disabled:cursor-not-allowed font-semibold text-sm flex items-center gap-2 transition-colors"
                    >
                      Install System <ArrowRight size={16} />
                    </button>
                  </div>
                </motion.div>
              )}

              {step === 3 && (
                <motion.div key="progress" {...stepAnim} className="space-y-6 py-2">
                  <div className="text-center">
                    <h2 className="text-xl font-bold text-gray-900">Installing the system</h2>
                    <p className="text-gray-500 text-sm mt-1">Do not power off until the installation is complete.</p>
                  </div>

                  <div>
                    <div className="flex justify-between items-end mb-2">
                      <span className="text-3xl font-bold text-blue-600 tabular-nums">{progress}%</span>
                      <span className="text-xs text-gray-400 font-mono truncate max-w-[60%]">{statusMsg}</span>
                    </div>
                    <div className="w-full bg-gray-100 rounded-full h-3 overflow-hidden">
                      <motion.div
                        className="bg-gradient-to-r from-blue-500 to-indigo-500 h-3 rounded-full"
                        animate={{ width: `${progress}%` }}
                        transition={{ duration: 0.5, ease: 'easeOut' }}
                      />
                    </div>
                  </div>

                  <div className="rounded-xl border border-gray-100 bg-slate-50 p-4 space-y-2.5">
                    {PHASES.map((phase, i) => {
                      const next = PHASES[i + 1];
                      const done = progress >= (next ? next.from : 100);
                      const active = !done && progress >= phase.from;
                      return (
                        <div key={phase.label} className="flex items-center gap-2.5 text-sm">
                          {done ? (
                            <CheckCircle2 size={16} className="text-green-500 shrink-0" />
                          ) : active ? (
                            <Loader2 size={16} className="text-blue-500 animate-spin shrink-0" />
                          ) : (
                            <span className="w-4 h-4 rounded-full border-2 border-gray-200 shrink-0" />
                          )}
                          <span className={active ? 'text-gray-800 font-medium' : 'text-gray-400'}>
                            {phase.label}
                          </span>
                        </div>
                      );
                    })}
                  </div>
                </motion.div>
              )}

              {step === 4 && (
                <motion.div key="done" {...stepAnim} className="space-y-6 py-2 text-center">
                  <motion.div
                    initial={{ scale: 0 }}
                    animate={{ scale: 1 }}
                    transition={{ type: 'spring', stiffness: 260, damping: 18, delay: 0.1 }}
                    className="mx-auto w-20 h-20 rounded-full bg-green-100 flex items-center justify-center"
                  >
                    <CheckCircle2 className="w-11 h-11 text-green-600" />
                  </motion.div>

                  <div>
                    <h2 className="text-2xl font-bold text-gray-900">Installation complete!</h2>
                    <p className="text-gray-500 text-sm mt-1">Just one last step to go.</p>
                  </div>

                  <div className="rounded-xl border border-gray-100 bg-slate-50 p-5 text-left space-y-3">
                    {[
                      { icon: Usb, text: 'Remove the installation media (USB/ISO).' },
                      { icon: RotateCw, text: 'Reboot the system using the button below.' },
                      { icon: Globe, text: 'After rebooting, open the same address to run the initial setup.' },
                    ].map(({ icon: Icon, text }, i) => (
                      <div key={i} className="flex items-center gap-3 text-sm text-gray-700">
                        <span className="bg-white border border-gray-200 rounded-lg p-1.5 text-blue-600 shrink-0"><Icon size={16} /></span>
                        <span><b className="text-gray-400 mr-1.5">{i + 1}.</b>{text}</span>
                      </div>
                    ))}
                  </div>

                  {rebooting ? (
                    <div className="flex items-center justify-center gap-2 text-blue-600 font-semibold py-3">
                      <Loader2 className="animate-spin" size={20} /> Rebooting... please reconnect shortly.
                    </div>
                  ) : (
                    <button
                      onClick={reboot}
                      className="px-8 py-3.5 bg-green-600 text-white rounded-xl hover:bg-green-700 font-semibold flex items-center justify-center gap-2 mx-auto transition-colors"
                    >
                      <Power size={18} /> Reboot Now
                    </button>
                  )}
                </motion.div>
              )}
            </AnimatePresence>
          </div>
        </div>

        <p className="text-center text-xs text-gray-400 mt-4">
          LukeNasOS · A/B updates · Automatic rollback · Web-based management
        </p>
      </div>

      {/* 설치 확인 모달 (브라우저 confirm 대체) */}
      <AnimatePresence>
        {confirmOpen && selected && (
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            className="fixed inset-0 bg-black/40 backdrop-blur-sm flex items-center justify-center p-4 z-50"
            onClick={() => setConfirmOpen(false)}
          >
            <motion.div
              initial={{ scale: 0.95, opacity: 0 }}
              animate={{ scale: 1, opacity: 1 }}
              exit={{ scale: 0.95, opacity: 0 }}
              transition={{ duration: 0.15 }}
              className="bg-white rounded-2xl shadow-2xl max-w-md w-full p-6 space-y-5"
              onClick={e => e.stopPropagation()}
            >
              <div className="flex items-center gap-3">
                <span className="bg-red-100 text-red-600 rounded-xl p-2.5 shrink-0"><AlertTriangle size={22} /></span>
                <h3 className="text-lg font-bold text-gray-900">Install now?</h3>
              </div>

              <div className="rounded-xl bg-slate-50 border border-slate-100 p-4 text-sm space-y-1.5">
                <div className="flex justify-between"><span className="text-gray-500">Target disk</span><span className="font-mono font-semibold">{selected.name}</span></div>
                <div className="flex justify-between"><span className="text-gray-500">Model</span><span className="font-medium text-right">{selected.model || '-'}</span></div>
                <div className="flex justify-between"><span className="text-gray-500">Size</span><span className="font-mono">{selected.size}</span></div>
              </div>

              <div className="p-3.5 rounded-xl bg-red-50 border border-red-100 text-red-700 text-sm">
                All data on this disk will be <b>permanently erased</b>. This cannot be undone.
              </div>

              <div className="flex gap-3">
                <button
                  onClick={() => setConfirmOpen(false)}
                  className="flex-1 px-4 py-2.5 rounded-xl border border-gray-200 text-gray-600 hover:bg-gray-50 font-medium text-sm transition-colors"
                >
                  Cancel
                </button>
                <button
                  onClick={startInstall}
                  className="flex-1 px-4 py-2.5 rounded-xl bg-red-600 text-white hover:bg-red-700 font-semibold text-sm transition-colors"
                >
                  Erase disk and install
                </button>
              </div>
            </motion.div>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}
