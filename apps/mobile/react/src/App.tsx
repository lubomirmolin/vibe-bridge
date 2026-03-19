/**
 * @license
 * SPDX-License-Identifier: Apache-2.0
 */

import React, { useState, useEffect, useRef } from 'react';
import { motion, AnimatePresence, useMotionValue, useSpring, useTransform } from 'motion/react';
import { 
  TerminalWindow, ShieldWarning, ShieldCheck, Pulse, Gear, 
  GitBranch, FolderSimple, WarningCircle, CheckCircle, 
  Clock, ArrowRight, CaretLeft, Play, Square, 
  ArrowsClockwise, DownloadSimple, UploadSimple, Eye, LockKey, LockKeyOpen,
  DeviceMobile, Monitor, QrCode, Key, X
} from '@phosphor-icons/react';

// --- Types & Mock Data ---

type ViewState = 'PAIRING' | 'HOME' | 'THREAD_LIST' | 'THREAD_DETAIL' | 'APPROVALS' | 'APPROVAL_DETAIL' | 'SETTINGS';

interface AppState {
  view: ViewState;
  isPaired: boolean;
  connectionStatus: 'CONNECTED' | 'DISCONNECTED' | 'CONNECTING';
  accessMode: 'READ_ONLY' | 'APPROVALS' | 'FULL_CONTROL';
  activeThreadId: string | null;
  activeApprovalId: string | null;
}

const MOCK_THREADS = [
  { id: 'th_1a2b3c', title: 'Refactor Auth Module', status: 'ACTIVE', repo: 'core-api', branch: 'feat/new-auth', path: '/src/auth', lastActive: 'Just now' },
  { id: 'th_9f8e7d', title: 'Fix memory leak in worker', status: 'IDLE', repo: 'data-pipeline', branch: 'bugfix/mem-leak', path: '/workers/process.ts', lastActive: '2m ago' },
  { id: 'th_4x5y6z', title: 'Update dependencies', status: 'ERROR', repo: 'frontend-app', branch: 'chore/deps', path: '/package.json', lastActive: '15m ago' },
];

const MOCK_EVENTS = [
  { id: 'ev_1', type: 'command', time: '10:42:01', content: 'npm run test:watch' },
  { id: 'ev_2', type: 'output', time: '10:42:05', content: 'PASS src/auth/jwt.test.ts (2.1s)' },
  { id: 'ev_3', type: 'agent', time: '10:42:10', content: 'Tests passed. Proceeding to commit changes.' },
  { id: 'ev_4', type: 'git', time: '10:42:12', content: 'git add src/auth/jwt.ts src/auth/jwt.test.ts' },
  { id: 'ev_5', type: 'approval_req', time: '10:42:15', content: 'Requires approval to execute: git commit -m "feat: update JWT validation"' },
];

const MOCK_APPROVALS = [
  { id: 'app_1', action: 'Execute Command', status: 'PENDING', reason: 'Destructive action detected', threadId: 'th_1a2b3c', repo: 'core-api', branch: 'feat/new-auth', payload: 'git push origin --force' },
  { id: 'app_2', action: 'Write File', status: 'PENDING', reason: 'Modifying sensitive configuration', threadId: 'th_9f8e7d', repo: 'data-pipeline', branch: 'bugfix/mem-leak', payload: '/config/production.json\n+ "max_memory": "4G"' },
];

// --- UI Components ---

const MagneticButton = ({ children, onClick, className = '', variant = 'primary' }: any) => {
  const ref = useRef<HTMLButtonElement>(null);
  const x = useMotionValue(0);
  const y = useMotionValue(0);
  
  const springX = useSpring(x, { stiffness: 150, damping: 15, mass: 0.1 });
  const springY = useSpring(y, { stiffness: 150, damping: 15, mass: 0.1 });

  const handleMouseMove = (e: React.MouseEvent) => {
    if (!ref.current) return;
    const rect = ref.current.getBoundingClientRect();
    const centerX = rect.left + rect.width / 2;
    const centerY = rect.top + rect.height / 2;
    x.set((e.clientX - centerX) * 0.2);
    y.set((e.clientY - centerY) * 0.2);
  };

  const handleMouseLeave = () => {
    x.set(0);
    y.set(0);
  };

  const base = "relative flex items-center justify-center gap-2 px-6 py-4 text-sm font-medium tracking-tight rounded-full transition-colors duration-300";
  const variants = {
    primary: "bg-zinc-100 text-zinc-950 hover:bg-white",
    secondary: "liquid-glass text-zinc-200 hover:bg-white/10",
    danger: "bg-rose-500/10 text-rose-500 border border-rose-500/20 hover:bg-rose-500/20",
  };

  return (
    <motion.button
      ref={ref}
      onMouseMove={handleMouseMove}
      onMouseLeave={handleMouseLeave}
      onClick={onClick}
      style={{ x: springX, y: springY }}
      whileTap={{ scale: 0.98 }}
      className={`${base} ${variants[variant as keyof typeof variants]} ${className}`}
    >
      {children}
    </motion.button>
  );
};

const Badge = ({ children, variant = 'default' }: { children: React.ReactNode, variant?: 'default' | 'active' | 'warning' | 'danger' }) => {
  const variants = {
    default: 'border-zinc-800 text-zinc-400',
    active: 'border-emerald-500/30 text-emerald-400 bg-emerald-500/10',
    warning: 'border-amber-500/30 text-amber-400 bg-amber-500/10',
    danger: 'border-rose-500/30 text-rose-400 bg-rose-500/10',
  };
  return (
    <span className={`text-[10px] font-mono tracking-wider px-2.5 py-1 rounded-full border ${variants[variant]}`}>
      {children}
    </span>
  );
};

// --- Screens ---

const AnimatedBridgeBackground = () => {
  const mouseX = useMotionValue(0);
  const mouseY = useMotionValue(0);

  const springConfig = { damping: 25, stiffness: 150 };
  const parallaxX = useSpring(mouseX, springConfig);
  const parallaxY = useSpring(mouseY, springConfig);

  const bgX = useTransform(parallaxX, v => v * 0.3);
  const bgY = useTransform(parallaxY, v => v * 0.3);
  
  const midX = useTransform(parallaxX, v => v * 1.0);
  const midY = useTransform(parallaxY, v => v * 1.0);
  
  const fgX = useTransform(parallaxX, v => v * 2.5);
  const fgY = useTransform(parallaxY, v => v * 2.5);

  useEffect(() => {
    const handleMouseMove = (e: MouseEvent) => {
      const x = (e.clientX / window.innerWidth - 0.5) * 2;
      const y = (e.clientY / window.innerHeight - 0.5) * 2;
      mouseX.set(x * 40);
      mouseY.set(y * 40);
    };

    const handleDeviceOrientation = (e: DeviceOrientationEvent) => {
      if (e.gamma !== null && e.beta !== null) {
        const x = Math.max(-1, Math.min(1, e.gamma / 45));
        const y = Math.max(-1, Math.min(1, (e.beta - 45) / 45));
        mouseX.set(x * 40);
        mouseY.set(y * 40);
      }
    };

    window.addEventListener('mousemove', handleMouseMove);
    window.addEventListener('deviceorientation', handleDeviceOrientation);

    return () => {
      window.removeEventListener('mousemove', handleMouseMove);
      window.removeEventListener('deviceorientation', handleDeviceOrientation);
    };
  }, [mouseX, mouseY]);

  const getCableY = (x: number) => {
    if (x < 300) {
      const t = (x + 200) / 500;
      return Math.pow(1 - t, 2) * 600 + 2 * (1 - t) * t * 650 + Math.pow(t, 2) * 200;
    } else if (x <= 700) {
      const t = (x - 300) / 400;
      return Math.pow(1 - t, 2) * 200 + 2 * (1 - t) * t * 900 + Math.pow(t, 2) * 200;
    } else {
      const t = (x - 700) / 500;
      return Math.pow(1 - t, 2) * 200 + 2 * (1 - t) * t * 650 + Math.pow(t, 2) * 600;
    }
  };

  return (
    <div className="absolute inset-0 overflow-hidden pointer-events-none z-0 flex items-center justify-center">
      {/* Gradient masks to blend edges */}
      <div className="absolute inset-0 bg-gradient-to-b from-[#09090b] via-transparent to-[#09090b] z-20" />
      <div className="absolute inset-0 bg-gradient-to-r from-[#09090b] via-transparent to-[#09090b] z-20" />
      
      {/* Background Layer (Stars/Distant City Lights) */}
      <motion.div 
        className="absolute inset-[-10%] w-[120%] h-[120%] z-0"
        style={{ x: bgX, y: bgY }}
      >
        {[...Array(50)].map((_, i) => (
          <div 
            key={`star-${i}`}
            className="absolute rounded-full bg-white"
            style={{
              left: `${Math.random() * 100}%`,
              top: `${Math.random() * 100}%`,
              width: Math.random() * 2 + 1 + 'px',
              height: Math.random() * 2 + 1 + 'px',
              opacity: Math.random() * 0.3 + 0.1,
            }}
          />
        ))}
      </motion.div>

      {/* Midground Layer (The Bridge) */}
      <motion.svg 
        className="absolute w-[110%] h-[110%] left-[-5%] top-[-5%] opacity-[0.4] z-10" 
        viewBox="0 0 1000 1000" 
        preserveAspectRatio="xMidYMid slice"
        style={{ x: midX, y: midY }}
      >
        <g transform="rotate(-5 500 500) translate(0, 50)">
          
          {/* Towers */}
          {[300, 700].map((tx, towerIdx) => (
            <g key={`tower-${towerIdx}`} stroke="rgba(255, 255, 255, 0.3)" strokeWidth="2" fill="none">
              {/* Legs */}
              <line x1={tx - 20} y1={100} x2={tx - 35} y2={700} />
              <line x1={tx + 20} y1={100} x2={tx + 35} y2={700} />
              
              {/* Top caps */}
              <line x1={tx - 25} y1={100} x2={tx + 25} y2={100} strokeWidth="4" stroke="rgba(255, 255, 255, 0.5)" />
              <line x1={tx - 22} y1={115} x2={tx + 22} y2={115} strokeWidth="2" />
              <line x1={tx - 18} y1={130} x2={tx + 18} y2={130} strokeWidth="1" />
              
              {/* Cross bracing */}
              {[200, 300, 400, 500, 620].map((cy, i) => {
                const widthAtY = 20 + ((cy - 100) / 600) * 15;
                const nextCy = cy + 100;
                const nextWidth = 20 + ((nextCy - 100) / 600) * 15;
                
                return (
                  <g key={`brace-${i}`}>
                    <line x1={tx - widthAtY} y1={cy} x2={tx + widthAtY} y2={cy} strokeWidth="3" stroke="rgba(255, 255, 255, 0.4)" />
                    <line x1={tx - widthAtY} y1={cy + 10} x2={tx + widthAtY} y2={cy + 10} strokeWidth="1" />
                    
                    {i < 4 && (
                      <>
                        <line x1={tx - widthAtY} y1={cy} x2={tx + nextWidth} y2={nextCy} strokeWidth="1" opacity="0.5" />
                        <line x1={tx + widthAtY} y1={cy} x2={tx - nextWidth} y2={nextCy} strokeWidth="1" opacity="0.5" />
                      </>
                    )}
                  </g>
                );
              })}
            </g>
          ))}

          {/* Main deck */}
          <motion.path
            d="M -200,600 L 1200,600"
            fill="none"
            stroke="rgba(255, 255, 255, 0.8)"
            strokeWidth="4"
            strokeDasharray="15 10"
            initial={{ strokeDashoffset: 200 }}
            animate={{ strokeDashoffset: 0 }}
            transition={{ duration: 10, repeat: Infinity, ease: "linear" }}
          />
          <motion.path
            d="M -200,610 L 1200,610"
            fill="none"
            stroke="rgba(255, 255, 255, 0.3)"
            strokeWidth="3"
          />
          <motion.path
            d="M -200,620 L 1200,620"
            fill="none"
            stroke="rgba(255, 255, 255, 0.5)"
            strokeWidth="1"
            strokeDasharray="5 5"
            initial={{ strokeDashoffset: 0 }}
            animate={{ strokeDashoffset: 200 }}
            transition={{ duration: 15, repeat: Infinity, ease: "linear" }}
          />

          {/* Data streams on deck */}
          {[...Array(3)].map((_, i) => (
            <motion.path
              key={`stream-${i}`}
              d={`M -200,${585 + i * 5} L 1200,${585 + i * 5}`}
              fill="none"
              stroke="white"
              strokeWidth="1.5"
              strokeDasharray="2 40"
              initial={{ strokeDashoffset: i % 2 === 0 ? 200 : 0 }}
              animate={{ strokeDashoffset: i % 2 === 0 ? 0 : 200 }}
              transition={{ duration: 3 + i * 1.5, repeat: Infinity, ease: "linear" }}
            />
          ))}

          {/* Main Suspension Cable */}
          <motion.path
            d="M -200,600 Q 50,650 300,200 Q 500,900 700,200 Q 950,650 1200,600"
            fill="none"
            stroke="rgba(255, 255, 255, 0.9)"
            strokeWidth="3"
            strokeDasharray="8 8"
            initial={{ strokeDashoffset: 200 }}
            animate={{ strokeDashoffset: 0 }}
            transition={{ duration: 15, repeat: Infinity, ease: "linear" }}
          />
          
          {/* Secondary suspension cable (glow/shadow) */}
          <path
            d="M -200,600 Q 50,650 300,200 Q 500,900 700,200 Q 950,650 1200,600"
            fill="none"
            stroke="rgba(255, 255, 255, 0.15)"
            strokeWidth="8"
          />

          {/* Vertical suspender ropes connecting cable to deck */}
          {[...Array(45)].map((_, i) => {
            const x = i * 30 - 150;
            // Skip drawing suspenders inside the towers
            if (Math.abs(x - 300) < 35 || Math.abs(x - 700) < 35) return null;
            
            const y = getCableY(x);
            if (y > 600) return null;

            return (
              <motion.line
                key={`strut-${i}`}
                x1={x}
                y1={y}
                x2={x}
                y2={600}
                fill="none"
                stroke="rgba(255, 255, 255, 0.5)"
                strokeWidth="1"
                strokeDasharray="2 4"
                initial={{ opacity: 0.2, strokeDashoffset: 0 }}
                animate={{ opacity: [0.2, 0.8, 0.2], strokeDashoffset: 20 }}
                transition={{ 
                  duration: 2 + (i % 4), 
                  repeat: Infinity, 
                  delay: i * 0.05, 
                  ease: "linear" 
                }}
              />
            );
          })}
        </g>
      </motion.svg>

      {/* Foreground Layer (Floating Data Particles) */}
      <motion.div 
        className="absolute inset-[-10%] w-[120%] h-[120%] z-30 pointer-events-none"
        style={{ x: fgX, y: fgY }}
      >
        {[...Array(15)].map((_, i) => (
          <motion.div 
            key={`fg-particle-${i}`}
            className="absolute rounded-full bg-white/40 blur-[1px]"
            style={{
              left: `${Math.random() * 100}%`,
              top: `${Math.random() * 100}%`,
              width: Math.random() * 4 + 2 + 'px',
              height: Math.random() * 4 + 2 + 'px',
            }}
            animate={{
              y: [0, -20, 0],
              opacity: [0.2, 0.6, 0.2],
            }}
            transition={{
              duration: Math.random() * 3 + 3,
              repeat: Infinity,
              ease: "easeInOut",
              delay: Math.random() * 2,
            }}
          />
        ))}
      </motion.div>
    </div>
  );
};

const PairingScreen = ({ onPair }: { onPair: () => void }) => {
  const [step, setStep] = useState<'WELCOME' | 'SCAN' | 'CONFIRM'>('WELCOME');

  return (
    <div className="flex flex-col h-full p-8 relative overflow-hidden">
      <AnimatedBridgeBackground />
      {/* Ambient Background */}
      <motion.div 
        animate={{ rotate: 360 }} 
        transition={{ duration: 100, repeat: Infinity, ease: "linear" }}
        className="absolute -top-[50%] -right-[50%] w-[200%] h-[200%] opacity-20 pointer-events-none"
        style={{ background: 'radial-gradient(circle at center, rgba(16,185,129,0.15) 0%, transparent 50%)' }}
      />

      <div className="flex-1 flex flex-col justify-end pb-8 z-10">
        <AnimatePresence mode="wait">
          {step === 'WELCOME' && (
            <motion.div key="welcome" initial={{ opacity: 0, y: 40 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -40 }} className="space-y-12">
              <div className="space-y-4">
                <h1 className="font-sans text-5xl font-medium tracking-tighter text-zinc-100 leading-tight">
                  Codex<br/><span className="text-zinc-500">Bridge</span>
                </h1>
                <p className="text-zinc-400 text-sm max-w-[250px] leading-relaxed">
                  Secure operator console for remote monitoring and control.
                </p>
              </div>
              <MagneticButton onClick={() => setStep('SCAN')} className="w-full">
                Initialize Pairing <ArrowRight weight="bold" />
              </MagneticButton>
            </motion.div>
          )}

          {step === 'SCAN' && (
            <motion.div key="scan" initial={{ opacity: 0, scale: 0.95 }} animate={{ opacity: 1, scale: 1 }} exit={{ opacity: 0, scale: 1.05 }} className="space-y-12 flex flex-col items-center">
              <div className="text-center space-y-2 w-full">
                <h2 className="font-sans text-2xl font-medium tracking-tight">Scan QR Code</h2>
                <p className="text-zinc-500 text-sm">Display code on desktop bridge app</p>
              </div>
              
              <div className="relative w-64 h-64 rounded-3xl liquid-glass flex items-center justify-center overflow-hidden cursor-pointer group" onClick={() => setStep('CONFIRM')}>
                <QrCode size={48} weight="thin" className="text-zinc-700 group-hover:text-emerald-500 transition-colors duration-500" />
                <motion.div 
                  animate={{ y: ['-100%', '100%'] }}
                  transition={{ duration: 2, repeat: Infinity, ease: "linear" }}
                  className="absolute left-0 right-0 h-0.5 bg-emerald-500/50 shadow-[0_0_20px_rgba(16,185,129,0.8)]"
                />
              </div>

              <MagneticButton variant="secondary" onClick={() => setStep('WELCOME')} className="w-full">
                Cancel
              </MagneticButton>
            </motion.div>
          )}

          {step === 'CONFIRM' && (
            <motion.div key="confirm" initial={{ opacity: 0, y: 40 }} animate={{ opacity: 1, y: 0 }} className="space-y-8">
               <div className="space-y-2">
                <h2 className="font-sans text-3xl font-medium tracking-tight text-zinc-100">Verify Identity</h2>
                <p className="text-zinc-400 text-sm">Confirm desktop fingerprint before connecting.</p>
              </div>

              <div className="liquid-glass rounded-3xl p-6 space-y-4 font-mono text-sm">
                <div className="flex justify-between items-center border-b border-white/5 pb-4">
                  <span className="text-zinc-500">Host</span>
                  <span className="text-zinc-200">MAC-STUDIO-M2</span>
                </div>
                <div className="flex justify-between items-center border-b border-white/5 pb-4">
                  <span className="text-zinc-500">User</span>
                  <span className="text-zinc-200">dev_admin</span>
                </div>
                <div className="flex justify-between items-center">
                  <span className="text-zinc-500">Fingerprint</span>
                  <span className="text-emerald-400">a7:8b:9c...</span>
                </div>
              </div>

              <div className="flex flex-col gap-3">
                <MagneticButton variant="primary" onClick={onPair} className="w-full">
                  Trust & Connect
                </MagneticButton>
                <MagneticButton variant="secondary" onClick={() => setStep('SCAN')} className="w-full">
                  Reject
                </MagneticButton>
              </div>
            </motion.div>
          )}
        </AnimatePresence>
      </div>
    </div>
  );
};

const HomeScreen = ({ navigate, state }: { navigate: (v: ViewState) => void, state: AppState }) => {
  return (
    <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} className="flex flex-col h-full p-6 space-y-8 overflow-y-auto no-scrollbar">
      <div className="pt-8 space-y-6">
        <div className="flex items-center gap-3">
          <motion.div 
            animate={{ scale: [1, 1.2, 1], opacity: [0.5, 1, 0.5] }}
            transition={{ duration: 2, repeat: Infinity }}
            className="w-2 h-2 rounded-full bg-emerald-500 shadow-[0_0_10px_rgba(16,185,129,0.5)]" 
          />
          <span className="text-emerald-500 text-xs font-mono tracking-widest uppercase">Connected</span>
        </div>
        <div>
          <h1 className="font-sans text-4xl font-medium tracking-tighter text-zinc-100">MAC-STUDIO-M2</h1>
          <div className="flex gap-4 text-xs text-zinc-500 font-mono mt-2">
            <span>ID: bridge_77x9</span>
            <span>•</span>
            <span>Uptime: 4h 12m</span>
          </div>
        </div>
      </div>

      <div className="grid grid-cols-1 gap-4 mt-4">
        <motion.div 
          whileHover={{ scale: 0.98 }}
          onClick={() => navigate('THREAD_LIST')} 
          className="liquid-glass rounded-[2rem] p-6 cursor-pointer group"
        >
          <div className="flex justify-between items-start mb-8">
            <div className="p-3 rounded-2xl bg-zinc-800/50 text-zinc-300 group-hover:bg-zinc-100 group-hover:text-zinc-900 transition-colors">
              <Pulse size={24} weight="duotone" />
            </div>
            <ArrowRight size={20} className="text-zinc-600 group-hover:text-zinc-300 transition-colors" />
          </div>
          <h3 className="font-sans text-xl font-medium tracking-tight mb-1">Active Threads</h3>
          <p className="text-zinc-500 text-sm">Monitor & steer 3 sessions</p>
        </motion.div>

        <motion.div 
          whileHover={{ scale: 0.98 }}
          onClick={() => navigate('APPROVALS')} 
          className="liquid-glass rounded-[2rem] p-6 cursor-pointer group relative overflow-hidden"
        >
          <div className="absolute top-0 right-0 w-32 h-32 bg-amber-500/10 rounded-full blur-3xl -mr-10 -mt-10" />
          <div className="flex justify-between items-start mb-8 relative z-10">
            <div className="p-3 rounded-2xl bg-amber-500/10 text-amber-500 group-hover:bg-amber-500 group-hover:text-amber-950 transition-colors">
              <ShieldWarning size={24} weight="duotone" />
            </div>
            <Badge variant="warning">2 PENDING</Badge>
          </div>
          <h3 className="font-sans text-xl font-medium tracking-tight mb-1 relative z-10">Approvals Queue</h3>
          <p className="text-zinc-500 text-sm relative z-10">Actions require review</p>
        </motion.div>

        <motion.div 
          whileHover={{ scale: 0.98 }}
          onClick={() => navigate('SETTINGS')} 
          className="liquid-glass rounded-[2rem] p-6 cursor-pointer group"
        >
           <div className="flex justify-between items-start mb-8">
            <div className="p-3 rounded-2xl bg-zinc-800/50 text-zinc-300 group-hover:bg-zinc-100 group-hover:text-zinc-900 transition-colors">
              <Gear size={24} weight="duotone" />
            </div>
          </div>
          <h3 className="font-sans text-xl font-medium tracking-tight mb-1">Security Settings</h3>
          <p className="text-zinc-500 text-sm">Mode: {state.accessMode.replace('_', ' ')}</p>
        </motion.div>
      </div>
    </motion.div>
  );
};

const ThreadListScreen = ({ navigate, setThread }: { navigate: (v: ViewState) => void, setThread: (id: string) => void }) => {
  return (
    <div className="flex flex-col h-full">
      <div className="px-6 py-4 flex items-center gap-4 sticky top-0 z-10 bg-[#09090b]/80 backdrop-blur-md">
        <button onClick={() => navigate('HOME')} className="p-2 -ml-2 rounded-full hover:bg-white/5 text-zinc-400 hover:text-zinc-100 transition-colors">
          <CaretLeft size={20} weight="bold" />
        </button>
        <h2 className="font-sans text-lg font-medium tracking-tight flex-1">Threads</h2>
      </div>

      <div className="p-6 pt-2 overflow-y-auto no-scrollbar">
        <div className="space-y-4">
          {MOCK_THREADS.map((thread, i) => (
            <motion.div 
              initial={{ opacity: 0, y: 20 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ delay: i * 0.1 }}
              key={thread.id} 
              onClick={() => { setThread(thread.id); navigate('THREAD_DETAIL'); }}
              className="liquid-glass rounded-[1.5rem] p-5 cursor-pointer hover:bg-white/10 transition-colors group"
            >
              <div className="flex justify-between items-start mb-4">
                <h3 className="font-medium text-zinc-100 group-hover:text-emerald-400 transition-colors tracking-tight">{thread.title}</h3>
                <Badge variant={thread.status === 'ACTIVE' ? 'active' : thread.status === 'ERROR' ? 'danger' : 'default'}>
                  {thread.status}
                </Badge>
              </div>
              
              <div className="space-y-2 text-xs font-mono text-zinc-500">
                <div className="flex items-center gap-2"><FolderSimple size={14} /> {thread.repo}</div>
                <div className="flex items-center gap-2"><GitBranch size={14} /> {thread.branch}</div>
                <div className="flex items-center gap-2"><TerminalWindow size={14} /> {thread.path}</div>
              </div>
              
              <div className="mt-5 pt-4 border-t border-white/5 flex justify-between items-center text-[10px] text-zinc-600 font-mono">
                <span>{thread.id}</span>
                <span>{thread.lastActive}</span>
              </div>
            </motion.div>
          ))}
        </div>
      </div>
    </div>
  );
};

const ThreadDetailScreen = ({ navigate, threadId }: { navigate: (v: ViewState) => void, threadId: string | null }) => {
  const thread = MOCK_THREADS.find(t => t.id === threadId) || MOCK_THREADS[0];
  const feedRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (feedRef.current) {
      feedRef.current.scrollTop = feedRef.current.scrollHeight;
    }
  }, []);

  return (
    <div className="flex flex-col h-full">
      {/* Header */}
      <div className="px-4 py-3 border-b border-white/5 bg-[#09090b]/80 backdrop-blur-md z-10">
        <div className="flex items-center gap-3 mb-4">
          <button onClick={() => navigate('THREAD_LIST')} className="p-2 -ml-2 rounded-full hover:bg-white/5 text-zinc-400 hover:text-zinc-100 transition-colors">
            <CaretLeft size={20} weight="bold" />
          </button>
          <div className="flex-1 overflow-hidden">
            <h2 className="font-sans text-sm font-medium tracking-tight truncate">{thread.title}</h2>
            <div className="text-[10px] text-zinc-500 font-mono mt-0.5 flex gap-2">
              <span>{thread.repo}</span>/<span>{thread.branch}</span>
            </div>
          </div>
          <Badge variant="active">ACTIVE</Badge>
        </div>
        
        {/* Git Quick Actions */}
        <div className="flex gap-2">
          <button className="flex-1 py-2 rounded-xl liquid-glass text-xs font-medium text-zinc-400 hover:text-zinc-100 hover:bg-white/10 flex items-center justify-center gap-1.5 transition-colors">
            <DownloadSimple size={14} /> Pull
          </button>
          <button className="flex-1 py-2 rounded-xl liquid-glass text-xs font-medium text-zinc-400 hover:text-zinc-100 hover:bg-white/10 flex items-center justify-center gap-1.5 transition-colors">
            <UploadSimple size={14} /> Push
          </button>
          <button className="flex-1 py-2 rounded-xl liquid-glass text-xs font-medium text-zinc-400 hover:text-zinc-100 hover:bg-white/10 flex items-center justify-center gap-1.5 transition-colors">
            <ArrowsClockwise size={14} /> Sync
          </button>
        </div>
      </div>

      {/* Timeline Feed */}
      <div className="flex-1 overflow-y-auto p-4 space-y-6 font-mono text-xs no-scrollbar" ref={feedRef}>
        {MOCK_EVENTS.map((ev, i) => (
          <motion.div 
            initial={{ opacity: 0, x: -10 }}
            animate={{ opacity: 1, x: 0 }}
            transition={{ delay: i * 0.1 }}
            key={ev.id} 
            className="flex gap-4"
          >
            <div className="text-zinc-600 shrink-0 mt-1">{ev.time}</div>
            <div className="flex-1 space-y-2">
              <div className="flex items-center gap-2 text-zinc-500 text-[10px] uppercase tracking-wider">
                {ev.type === 'command' && <TerminalWindow size={12} />}
                {ev.type === 'output' && <Pulse size={12} />}
                {ev.type === 'agent' && <Monitor size={12} />}
                {ev.type === 'git' && <GitBranch size={12} />}
                {ev.type === 'approval_req' && <ShieldWarning size={12} className="text-amber-500" />}
                <span>{ev.type}</span>
              </div>
              <div className={`p-3 rounded-xl ${ev.type === 'approval_req' ? 'bg-amber-500/10 text-amber-500 border border-amber-500/20' : ev.type === 'command' ? 'bg-zinc-900 text-zinc-300 border border-white/5' : 'text-zinc-400'}`}>
                {ev.content}
              </div>
            </div>
          </motion.div>
        ))}
        <div className="flex gap-4 opacity-50">
           <div className="text-zinc-600 shrink-0 mt-1">--:--:--</div>
           <div className="flex-1 p-3 rounded-xl border border-dashed border-zinc-800 text-zinc-500 flex items-center gap-2">
             <motion.div animate={{ opacity: [0.3, 1, 0.3] }} transition={{ duration: 1.5, repeat: Infinity }} className="w-1.5 h-1.5 rounded-full bg-zinc-500" />
             Awaiting agent output...
           </div>
        </div>
      </div>

      {/* Controls */}
      <div className="p-4 border-t border-white/5 bg-[#09090b]/80 backdrop-blur-md">
        <div className="flex gap-2 mb-3">
          <button className="flex-1 bg-zinc-100 text-zinc-950 rounded-xl py-3 text-sm font-medium flex items-center justify-center gap-2 hover:bg-white transition-colors">
            <Play size={16} weight="fill" /> Start Turn
          </button>
          <button className="px-5 rounded-xl border border-rose-500/30 text-rose-500 hover:bg-rose-500/10 flex items-center justify-center transition-colors">
            <Square size={16} weight="fill" />
          </button>
        </div>
        <div className="relative">
          <input 
            type="text" 
            placeholder="Steer active turn..." 
            className="w-full bg-zinc-900 border border-white/10 rounded-xl px-4 py-3 text-sm font-sans focus:outline-none focus:border-emerald-500/50 placeholder:text-zinc-600 pr-12 transition-colors"
          />
          <button className="absolute right-2 top-1/2 -translate-y-1/2 w-8 h-8 flex items-center justify-center rounded-lg text-zinc-400 hover:text-zinc-100 hover:bg-white/10 transition-colors">
            <ArrowRight size={16} weight="bold" />
          </button>
        </div>
      </div>
    </div>
  );
};

const ApprovalsScreen = ({ navigate, setApproval }: { navigate: (v: ViewState) => void, setApproval: (id: string) => void }) => {
  return (
    <div className="flex flex-col h-full">
      <div className="px-6 py-4 flex items-center gap-4 sticky top-0 z-10 bg-[#09090b]/80 backdrop-blur-md">
        <button onClick={() => navigate('HOME')} className="p-2 -ml-2 rounded-full hover:bg-white/5 text-zinc-400 hover:text-zinc-100 transition-colors">
          <CaretLeft size={20} weight="bold" />
        </button>
        <h2 className="font-sans text-lg font-medium tracking-tight flex-1">Approvals</h2>
      </div>

      <div className="p-6 pt-2 space-y-4 overflow-y-auto no-scrollbar">
        <div className="bg-amber-500/10 border border-amber-500/20 rounded-2xl p-4 flex items-start gap-3 text-amber-500 text-sm mb-6">
          <WarningCircle size={20} className="shrink-0 mt-0.5" weight="duotone" />
          <p className="leading-relaxed">Access mode requires explicit approval for destructive actions and file writes outside workspace.</p>
        </div>

        {MOCK_APPROVALS.map((app, i) => (
          <motion.div 
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: i * 0.1 }}
            key={app.id}
            onClick={() => { setApproval(app.id); navigate('APPROVAL_DETAIL'); }}
            className="liquid-glass rounded-[1.5rem] p-5 cursor-pointer hover:border-amber-500/50 transition-colors relative overflow-hidden group"
          >
            <div className="absolute top-0 left-0 w-1 h-full bg-amber-500" />
            <div className="pl-2">
              <div className="flex justify-between items-start mb-2">
                <h3 className="font-medium text-zinc-100 tracking-tight">{app.action}</h3>
                <span className="text-[10px] text-zinc-500 font-mono">{app.id}</span>
              </div>
              <p className="text-amber-500/80 text-xs mb-4">{app.reason}</p>
              
              <div className="bg-zinc-900/50 rounded-xl p-3 border border-white/5 text-xs font-mono text-zinc-400 truncate mb-4">
                {app.payload.split('\n')[0]}...
              </div>

              <div className="flex justify-between items-center text-xs text-zinc-500">
                <span className="flex items-center gap-1.5"><FolderSimple size={14}/> {app.repo}</span>
                <span className="flex items-center gap-1 text-zinc-300 group-hover:text-amber-400 transition-colors font-medium">Review <ArrowRight size={14}/></span>
              </div>
            </div>
          </motion.div>
        ))}
      </div>
    </div>
  );
};

const ApprovalDetailScreen = ({ navigate, approvalId }: { navigate: (v: ViewState) => void, approvalId: string | null }) => {
  const app = MOCK_APPROVALS.find(a => a.id === approvalId) || MOCK_APPROVALS[0];

  return (
    <div className="flex flex-col h-full">
      <div className="px-4 py-3 border-b border-white/5 flex items-center gap-3 bg-[#09090b]/80 backdrop-blur-md z-10">
        <button onClick={() => navigate('APPROVALS')} className="p-2 -ml-2 rounded-full hover:bg-white/5 text-zinc-400 hover:text-zinc-100 transition-colors">
          <CaretLeft size={20} weight="bold" />
        </button>
        <h2 className="font-sans text-sm font-medium tracking-tight flex-1 truncate">Review Action</h2>
      </div>

      <div className="flex-1 overflow-y-auto p-6 space-y-8 no-scrollbar">
        <div>
          <h3 className="text-2xl font-medium text-zinc-100 tracking-tight mb-2">{app.action}</h3>
          <p className="text-amber-500 text-sm">{app.reason}</p>
        </div>

        <div className="grid grid-cols-2 gap-6 text-sm border-y border-white/5 py-6">
          <div>
            <span className="text-zinc-500 block mb-1 text-xs uppercase tracking-wider">Repository</span>
            <span className="text-zinc-200 font-mono">{app.repo}</span>
          </div>
          <div>
            <span className="text-zinc-500 block mb-1 text-xs uppercase tracking-wider">Branch</span>
            <span className="text-zinc-200 font-mono">{app.branch}</span>
          </div>
          <div className="col-span-2">
            <span className="text-zinc-500 block mb-1 text-xs uppercase tracking-wider">Related Thread</span>
            <span className="text-zinc-300 underline decoration-white/20 underline-offset-4 cursor-pointer hover:text-white transition-colors">{app.threadId}</span>
          </div>
        </div>

        <div>
          <span className="text-zinc-500 block mb-3 text-xs uppercase tracking-wider">Payload / Diff</span>
          <div className="bg-zinc-900 rounded-2xl border border-white/5 p-4 font-mono text-xs overflow-x-auto">
            <pre className="text-zinc-300 leading-relaxed">
              {app.payload.split('\n').map((line, i) => (
                <div key={i} className={line.startsWith('+') ? 'text-emerald-400' : line.startsWith('-') ? 'text-rose-400' : ''}>
                  {line}
                </div>
              ))}
            </pre>
          </div>
        </div>
      </div>

      <div className="p-4 border-t border-white/5 bg-[#09090b]/80 backdrop-blur-md flex gap-3">
        <button 
          onClick={() => navigate('APPROVALS')}
          className="flex-1 py-4 rounded-2xl border border-rose-500/30 text-rose-500 hover:bg-rose-500/10 text-sm font-medium transition-colors"
        >
          Reject
        </button>
        <button 
          onClick={() => navigate('APPROVALS')}
          className="flex-1 py-4 rounded-2xl bg-emerald-500 text-emerald-950 hover:bg-emerald-400 text-sm font-medium transition-colors"
        >
          Approve
        </button>
      </div>
    </div>
  );
};

const SettingsScreen = ({ navigate, state }: { navigate: (v: ViewState) => void, state: AppState }) => {
  return (
    <div className="flex flex-col h-full">
      <div className="px-6 py-4 flex items-center gap-4 sticky top-0 z-10 bg-[#09090b]/80 backdrop-blur-md">
        <button onClick={() => navigate('HOME')} className="p-2 -ml-2 rounded-full hover:bg-white/5 text-zinc-400 hover:text-zinc-100 transition-colors">
          <CaretLeft size={20} weight="bold" />
        </button>
        <h2 className="font-sans text-lg font-medium tracking-tight flex-1">Settings</h2>
      </div>

      <div className="p-6 space-y-10 overflow-y-auto no-scrollbar">
        {/* Identity */}
        <section className="space-y-4">
          <h3 className="text-xs text-zinc-500 uppercase tracking-wider">Identity</h3>
          <div className="liquid-glass rounded-2xl p-5 space-y-4 text-sm">
            <div className="flex justify-between items-center">
              <span className="text-zinc-500">Paired Host</span>
              <span className="text-zinc-200 font-mono">MAC-STUDIO-M2</span>
            </div>
            <div className="flex justify-between items-center">
              <span className="text-zinc-500">Bridge ID</span>
              <span className="text-zinc-200 font-mono">br_99x21a</span>
            </div>
            <div className="flex justify-between items-center">
              <span className="text-zinc-500">Status</span>
              <span className="text-emerald-400 font-medium">Connected</span>
            </div>
          </div>
        </section>

        {/* Access Mode */}
        <section className="space-y-4">
          <h3 className="text-xs text-zinc-500 uppercase tracking-wider">Access Mode</h3>
          <div className="space-y-3">
            {[
              { id: 'READ_ONLY', label: 'Read-Only', desc: 'Monitor only. No actions permitted.', icon: Eye },
              { id: 'APPROVALS', label: 'Control w/ Approvals', desc: 'Require review for git push, file writes, etc.', icon: ShieldCheck },
              { id: 'FULL_CONTROL', label: 'Full Control', desc: 'Unrestricted access. High risk.', icon: LockKeyOpen }
            ].map(mode => (
              <div 
                key={mode.id}
                className={`p-5 rounded-2xl cursor-pointer flex gap-4 transition-all duration-300 ${state.accessMode === mode.id ? 'bg-white/10 border border-white/20' : 'liquid-glass hover:bg-white/5'}`}
              >
                <mode.icon size={24} weight={state.accessMode === mode.id ? "fill" : "regular"} className={state.accessMode === mode.id ? 'text-zinc-100' : 'text-zinc-500'} />
                <div>
                  <div className={`font-medium mb-1 ${state.accessMode === mode.id ? 'text-zinc-100' : 'text-zinc-300'}`}>{mode.label}</div>
                  <div className="text-xs text-zinc-500 leading-relaxed">{mode.desc}</div>
                </div>
              </div>
            ))}
          </div>
        </section>

        {/* Danger Zone */}
        <section className="space-y-4 pt-4">
          <button 
            onClick={() => navigate('PAIRING')}
            className="w-full py-4 rounded-2xl border border-rose-500/30 text-rose-500 hover:bg-rose-500/10 transition-colors font-medium text-sm flex justify-center items-center gap-2"
          >
            <X size={18} weight="bold" /> Unpair Device
          </button>
          <p className="text-xs text-zinc-600 text-center">This will revoke all cryptographic trust.</p>
        </section>
      </div>
    </div>
  );
};


// --- Main App Shell ---

export default function App() {
  const [state, setState] = useState<AppState>({
    view: 'PAIRING',
    isPaired: false,
    connectionStatus: 'DISCONNECTED',
    accessMode: 'APPROVALS',
    activeThreadId: null,
    activeApprovalId: null,
  });

  const navigate = (view: ViewState) => setState(s => ({ ...s, view }));
  const setThread = (id: string) => setState(s => ({ ...s, activeThreadId: id }));
  const setApproval = (id: string) => setState(s => ({ ...s, activeApprovalId: id }));

  const handlePair = () => {
    setState(s => ({ ...s, isPaired: true, connectionStatus: 'CONNECTED', view: 'HOME' }));
  };

  // Mobile constraint wrapper
  return (
    <div className="min-h-[100dvh] bg-[#09090b] flex items-center justify-center p-0 sm:p-6">
      <div className="w-full h-[100dvh] sm:h-[850px] sm:max-w-[400px] bg-[#09090b] sm:border border-white/10 sm:rounded-[2.5rem] relative overflow-hidden sm:shadow-[0_0_80px_-20px_rgba(0,0,0,1)] flex flex-col">
        
        {/* Global Header / Status Bar */}
        {state.view !== 'PAIRING' && (
          <div className="h-10 px-6 flex items-center justify-between text-[10px] font-mono text-zinc-500 select-none z-50 pt-2">
            <div className="flex items-center gap-2">
              <div className={`w-1.5 h-1.5 rounded-full ${state.connectionStatus === 'CONNECTED' ? 'bg-emerald-500 shadow-[0_0_5px_rgba(16,185,129,0.8)]' : 'bg-rose-500'}`} />
              <span>{state.connectionStatus}</span>
            </div>
            <div className="opacity-50 tracking-widest">CODEX_BRIDGE</div>
          </div>
        )}

        {/* View Container */}
        <div className="flex-1 overflow-hidden relative">
          <AnimatePresence mode="wait">
            <motion.div
              key={state.view}
              initial={{ opacity: 0, filter: 'blur(10px)', scale: 0.98 }}
              animate={{ opacity: 1, filter: 'blur(0px)', scale: 1 }}
              exit={{ opacity: 0, filter: 'blur(10px)', scale: 1.02 }}
              transition={{ duration: 0.4, ease: [0.16, 1, 0.3, 1] }}
              className="absolute inset-0"
            >
              {state.view === 'PAIRING' && <PairingScreen onPair={handlePair} />}
              {state.view === 'HOME' && <HomeScreen navigate={navigate} state={state} />}
              {state.view === 'THREAD_LIST' && <ThreadListScreen navigate={navigate} setThread={setThread} />}
              {state.view === 'THREAD_DETAIL' && <ThreadDetailScreen navigate={navigate} threadId={state.activeThreadId} />}
              {state.view === 'APPROVALS' && <ApprovalsScreen navigate={navigate} setApproval={setApproval} />}
              {state.view === 'APPROVAL_DETAIL' && <ApprovalDetailScreen navigate={navigate} approvalId={state.activeApprovalId} />}
              {state.view === 'SETTINGS' && <SettingsScreen navigate={navigate} state={state} />}
            </motion.div>
          </AnimatePresence>
        </div>
      </div>
    </div>
  );
}
