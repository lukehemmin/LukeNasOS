import { useState, useEffect } from 'react';
import axios from 'axios';
import { HardDrive, Server, Power, AlertCircle, CheckCircle2, Loader2 } from 'lucide-react';

interface Disk {
  name: string;
  model: string;
  size: string;
}

export default function Installer() {
  const [step, setStep] = useState(1);
  const [disks, setDisks] = useState<Disk[]>([]);
  const [selectedDisk, setSelectedDisk] = useState<string | null>(null);
  const [hostname, setHostname] = useState('lukenasos');
  const [progress, setProgress] = useState(0);
  const [statusMsg, setStatusMsg] = useState('');
  const [error, setError] = useState<string | null>(null);

  // Step 1: Check Installation Status
  useEffect(() => {
    const checkInstallStatus = async () => {
      try {
        const res = await axios.get('/api/install/status');
        if (res.data.status === 'installing') {
          setStep(3);
          setProgress(res.data.progress);
          setStatusMsg(res.data.message);
        }
      } catch (e) {
        console.error("Failed to check install status:", e);
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
        .catch(err => setError('Failed to load disks: ' + err.message));
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
    if (!confirm(`WARNING: ALL DATA ON ${selectedDisk} WILL BE ERASED.`)) return;
    
    try {
      const res = await axios.post('/api/install/start', { disk: selectedDisk, hostname });
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
      if (res.data.success) alert('Rebooting...');
      else alert('Failed: ' + res.data.message);
    } catch (e: any) {
      alert('Error: ' + e.message);
    }
  };

  return (
    <div className="min-h-screen bg-gray-100 flex items-center justify-center p-4">
      <div className="max-w-2xl w-full bg-white rounded-xl shadow-lg overflow-hidden">
        <div className="bg-blue-600 p-6 text-white text-center">
          <h1 className="text-2xl font-bold flex items-center justify-center gap-2">
            <Server /> LukeNasOS Installer
          </h1>
        </div>

        <div className="p-8">
          {error && (
            <div className="mb-4 p-4 bg-red-50 text-red-700 rounded-lg flex items-center gap-2">
              <AlertCircle size={20} /> {error}
            </div>
          )}

          {step === 1 && (
            <div className="text-center space-y-6">
              <h2 className="text-xl font-semibold">Welcome to LukeNasOS Setup</h2>
              <p className="text-gray-600">
                This wizard will guide you through the installation process.<br/>
                Note: Installing will erase all data on the target drive.
              </p>
              <button onClick={() => setStep(2)} className="px-6 py-3 bg-blue-600 text-white rounded-lg hover:bg-blue-700 font-medium">
                Start Installation
              </button>
            </div>
          )}

          {step === 2 && (
            <div className="space-y-6">
              <h2 className="text-xl font-semibold">Target Disk Selection</h2>
              
              <div className="space-y-2">
                {disks.length === 0 ? (
                  <div className="text-center py-8 text-gray-500"><Loader2 className="animate-spin inline mr-2"/> Scanning disks...</div>
                ) : (
                  disks.map(disk => (
                    <button
                      key={disk.name}
                      onClick={() => setSelectedDisk(disk.name)}
                      className={`w-full p-4 border rounded-lg flex items-center justify-between transition-colors ${
                        selectedDisk === disk.name ? 'border-blue-500 bg-blue-50' : 'hover:bg-gray-50'
                      }`}
                    >
                      <div className="flex items-center gap-3">
                        <HardDrive className="text-gray-500" />
                        <div className="text-left">
                          <div className="font-medium">{disk.name}</div>
                          <div className="text-sm text-gray-500">{disk.model}</div>
                        </div>
                      </div>
                      <div className="font-mono text-sm bg-gray-200 px-2 py-1 rounded">{disk.size}</div>
                    </button>
                  ))
                )}
              </div>

              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">Hostname</label>
                <input 
                  type="text" 
                  value={hostname} 
                  onChange={e => setHostname(e.target.value)}
                  className="w-full p-2 border rounded-lg"
                />
              </div>

              <div className="flex justify-between pt-4">
                <button onClick={() => setStep(1)} className="px-4 py-2 text-gray-600 hover:bg-gray-100 rounded-lg">Back</button>
                <button 
                  onClick={startInstall} 
                  disabled={!selectedDisk}
                  className="px-6 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed"
                >
                  Install System
                </button>
              </div>
            </div>
          )}

          {step === 3 && (
            <div className="text-center space-y-6 py-8">
              <Loader2 className="w-12 h-12 animate-spin text-blue-600 mx-auto" />
              <h2 className="text-xl font-semibold">Installing System...</h2>
              
              <div className="w-full bg-gray-200 rounded-full h-4 overflow-hidden">
                <div 
                  className="bg-blue-600 h-4 transition-all duration-500" 
                  style={{ width: `${progress}%` }}
                ></div>
              </div>
              
              <p className="text-gray-600 font-mono text-sm">{statusMsg}</p>
            </div>
          )}

          {step === 4 && (
            <div className="text-center space-y-6 py-8">
              <CheckCircle2 className="w-16 h-16 text-green-500 mx-auto" />
              <h2 className="text-2xl font-bold text-green-700">Installation Complete!</h2>
              <p className="text-gray-600">
                The system has been successfully installed.<br/>
                Please remove the installation media and reboot.
              </p>
              <button 
                onClick={reboot}
                className="px-8 py-3 bg-green-600 text-white rounded-lg hover:bg-green-700 font-bold flex items-center justify-center gap-2 mx-auto"
              >
                <Power size={20} /> Reboot Now
              </button>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
