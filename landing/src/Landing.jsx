import { useState, useEffect, useRef, useCallback } from 'react'
import {
  Menu, Search, TrendingUp, ChevronLeft, ChevronRight, X,
  LayoutDashboard, User, Receipt, Wallet, Trophy, Flame,
  Settings, HelpCircle, Crown, LogIn,
} from 'lucide-react'

// ─── Mock data ────────────────────────────────────────────────────────────────

const CREATORS = [
  {
    rank: 1,
    username: 'JordanKicks',
    category: 'Athlete',
    scoreDelta: '+2,340',
    platforms: [['YouTube', '+50'], ['TikTok', '+24'], ['Twitch', '+7']],
    gradientFrom: 'hsl(258 70% 28%)',
    gradientTo: 'hsl(258 50% 10%)',
    accentColor: '#9B8FFF',
  },
  {
    rank: 2,
    username: 'CreatorKing',
    category: 'Influencer',
    scoreDelta: '+1,890',
    platforms: [['YouTube', '+32'], ['Instagram', '+18'], ['TikTok', '+11']],
    gradientFrom: 'hsl(174 55% 22%)',
    gradientTo: 'hsl(174 40% 8%)',
    accentColor: '#03DAC6',
  },
  {
    rank: 3,
    username: 'BeatMaster',
    category: 'Artist',
    scoreDelta: '+1,650',
    platforms: [['YouTube', '+45'], ['Spotify', '+12'], ['TikTok', '+8']],
    gradientFrom: 'hsl(340 60% 28%)',
    gradientTo: 'hsl(340 45% 8%)',
    accentColor: '#FF6B81',
  },
  {
    rank: 4,
    username: 'DrNovak',
    category: 'Scientist',
    scoreDelta: '+1,200',
    platforms: [['YouTube', '+28'], ['X', '+15'], ['LinkedIn', '+9']],
    gradientFrom: 'hsl(210 60% 25%)',
    gradientTo: 'hsl(210 45% 8%)',
    accentColor: '#60A5FA',
  },
  {
    rank: 5,
    username: 'ExecElena',
    category: 'Professional',
    scoreDelta: '+980',
    platforms: [['LinkedIn', '+30'], ['YouTube', '+15'], ['X', '+6']],
    gradientFrom: 'hsl(30 65% 25%)',
    gradientTo: 'hsl(30 45% 8%)',
    accentColor: '#FBB040',
  },
]

const NEWS = [
  { text: 'JordanKicks breaks 1M followers', time: '2m ago' },
  { text: 'New weekly score record set by CreatorKing', time: '14m ago' },
  { text: 'BeatMaster drops surprise album — fans react', time: '1h ago' },
]

const TABS = [
  { label: 'Trending' },
  { label: 'Athletes' },
  { label: 'Influencers' },
  { label: 'Artists' },
  { label: 'Scientists' },
  { label: 'Professionals' },
  { label: 'Explore All', href: '/markets' },
]

const ORDINALS = ['1st', '2nd', '3rd', '4th', '5th']

// ─── Sub-components ───────────────────────────────────────────────────────────

function AvatarCircle({ name, size = 36, accent }) {
  return (
    <div style={{
      width: size, height: size, borderRadius: '50%', flexShrink: 0,
      background: `linear-gradient(135deg, ${accent ?? '#6C63FF'}, #03DAC6)`,
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      fontSize: size * 0.4, fontWeight: 800, color: 'white', userSelect: 'none',
    }}>
      {name[0].toUpperCase()}
    </div>
  )
}

function RankCard({ creator, isActive, onClick }) {
  return (
    <button
      onClick={onClick}
      style={{
        display: 'flex', alignItems: 'center', gap: 10,
        borderRadius: 12, padding: '10px 12px',
        backgroundColor: isActive ? '#16213E' : '#1A1A2E',
        border: `1px solid ${isActive ? '#6C63FF' : '#2A2A3E'}`,
        cursor: 'pointer', textAlign: 'left',
        transition: 'background-color 0.2s, border-color 0.2s',
        boxShadow: isActive ? '0 0 0 1px rgba(108,99,255,0.25)' : 'none',
      }}
    >
      <span style={{ fontSize: 11, fontWeight: 700, color: '#8B8FA8', minWidth: 26 }}>
        {ORDINALS[creator.rank - 1]}
      </span>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 13, fontWeight: 600, color: 'white', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
          {creator.username}
        </div>
        <div style={{ fontSize: 11, color: '#8B8FA8', marginTop: 1 }}>{creator.category}</div>
      </div>
      <AvatarCircle name={creator.username} size={34} accent={creator.accentColor} />
    </button>
  )
}

function NewsPanel() {
  return (
    <div style={{
      backgroundColor: '#1A1A2E', border: '1px solid #2A2A3E',
      borderRadius: 12, padding: '14px 16px',
    }}>
      <a
        href="/explore"
        style={{
          display: 'inline-flex', alignItems: 'center', gap: 5,
          backgroundColor: '#FF4757', borderRadius: 999, padding: '4px 12px',
          fontSize: 11, fontWeight: 700, color: 'white', marginBottom: 14,
          letterSpacing: '0.02em', textDecoration: 'none',
          transition: 'background-color 0.15s, box-shadow 0.15s',
          cursor: 'pointer',
        }}
        onMouseEnter={e => { e.currentTarget.style.backgroundColor = '#FF6070'; e.currentTarget.style.boxShadow = '0 0 12px rgba(255,71,87,0.45)' }}
        onMouseLeave={e => { e.currentTarget.style.backgroundColor = '#FF4757'; e.currentTarget.style.boxShadow = 'none' }}
        title="See Who's Hot Right Now"
      >
        🔥 Breaking News
      </a>
      {NEWS.map((item, i) => (
        <div
          key={i}
          style={{
            paddingBottom: i < NEWS.length - 1 ? 10 : 0,
            marginBottom: i < NEWS.length - 1 ? 10 : 0,
            borderBottom: i < NEWS.length - 1 ? '1px solid #2A2A3E' : 'none',
          }}
        >
          <p style={{ margin: 0, fontSize: 12, lineHeight: 1.55, color: 'white' }}>{item.text}</p>
          <p style={{ margin: '3px 0 0', fontSize: 11, color: '#8B8FA8' }}>{item.time}</p>
        </div>
      ))}
    </div>
  )
}

function GetTokensButton() {
  const [hovered, setHovered] = useState(false)
  return (
    <button
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      style={{
        backgroundColor: hovered ? '#16213E' : '#1A1A2E',
        border: '1px solid #6C63FF',
        borderRadius: 12, color: 'white',
        fontSize: 22, fontWeight: 800, cursor: 'pointer',
        padding: '28px 0', width: '100%',
        lineHeight: 1.35, transition: 'background-color 0.2s',
        boxShadow: hovered ? '0 0 24px rgba(108,99,255,0.3)' : 'none',
      }}
    >
      Get<br />Tokens
    </button>
  )
}

// ─── Spotlight card ───────────────────────────────────────────────────────────

function SpotlightCard({ creator, onPrev, onNext, currentSlide, onDotClick }) {
  return (
    <div style={{
      flex: 1, position: 'relative', borderRadius: 18, overflow: 'hidden',
      minHeight: 380, border: '1px solid #2A2A3E',
    }}>
      {/* Background gradient — transitions on creator change */}
      <div
        key={`bg-${creator.rank}`}
        style={{
          position: 'absolute', inset: 0,
          background: `radial-gradient(ellipse at 50% 0%, ${creator.gradientFrom} 0%, ${creator.gradientTo} 65%, #0A0A0F 100%)`,
          animation: 'fadeIn 0.5s ease forwards',
        }}
      />

      {/* Bottom fade overlay */}
      <div style={{
        position: 'absolute', inset: 0,
        background: 'linear-gradient(to top, rgba(5,5,15,0.92) 0%, rgba(5,5,15,0.4) 45%, transparent 100%)',
      }} />

      {/* Top-left subtle vignette */}
      <div style={{
        position: 'absolute', inset: 0,
        background: 'radial-gradient(ellipse at 0% 0%, rgba(0,0,0,0.35) 0%, transparent 60%)',
        pointerEvents: 'none',
      }} />

      {/* Score badge */}
      <div style={{
        position: 'absolute', top: 16, right: 16,
        display: 'flex', alignItems: 'center', gap: 6,
        backgroundColor: 'rgba(0,200,150,0.12)',
        border: '1px solid #00C896',
        borderRadius: 999, padding: '6px 13px',
        fontSize: 13, fontWeight: 700, color: '#00C896',
        backdropFilter: 'blur(6px)',
      }}>
        <TrendingUp size={14} />
        {creator.scoreDelta} pts
      </div>

      {/* Left chevron */}
      <ChevronButton direction="left" onClick={onPrev} />

      {/* Right chevron */}
      <ChevronButton direction="right" onClick={onNext} />

      {/* Bottom content — fades in with each new creator */}
      <div
        key={`content-${creator.rank}`}
        style={{ position: 'absolute', inset: 0, animation: 'slideUp 0.4s ease forwards' }}
      >
        {/* Follower count pill */}
        <div style={{
          position: 'absolute', bottom: 48, left: 18,
          backgroundColor: 'rgba(10,10,20,0.72)',
          backdropFilter: 'blur(10px)',
          borderRadius: 10, padding: '9px 13px',
          fontSize: 12, border: '1px solid rgba(42,42,62,0.8)',
        }}>
          <div style={{ color: '#8B8FA8', fontWeight: 600, marginBottom: 5, fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.05em' }}>
            Follower Count
          </div>
          {creator.platforms.map(([platform, delta]) => (
            <div key={platform} style={{ display: 'flex', gap: 8, marginBottom: 2 }}>
              <span style={{ color: '#8B8FA8', minWidth: 60 }}>{platform}:</span>
              <span style={{ color: '#00C896', fontWeight: 600 }}>{delta}</span>
            </div>
          ))}
        </div>

        {/* Username + category */}
        <div style={{ position: 'absolute', bottom: 48, right: 20, textAlign: 'right' }}>
          <div style={{ fontSize: 22, fontWeight: 800, letterSpacing: '-0.3px', textShadow: '0 2px 12px rgba(0,0,0,0.6)' }}>
            {creator.username}
          </div>
          <div style={{ fontSize: 13, color: '#8B8FA8', marginTop: 3 }}>{creator.category}</div>
        </div>
      </div>

      {/* Pagination dots */}
      <div style={{
        position: 'absolute', bottom: 14, left: '50%', transform: 'translateX(-50%)',
        display: 'flex', gap: 6, alignItems: 'center',
      }}>
        {CREATORS.map((_, i) => (
          <button
            key={i}
            onClick={() => onDotClick(i)}
            style={{
              height: 7,
              width: i === currentSlide ? 22 : 7,
              borderRadius: 999, border: 'none', cursor: 'pointer', padding: 0,
              backgroundColor: i === currentSlide ? '#6C63FF' : 'rgba(255,255,255,0.28)',
              transition: 'all 0.3s ease',
            }}
          />
        ))}
      </div>
    </div>
  )
}

function ChevronButton({ direction, onClick }) {
  const [hovered, setHovered] = useState(false)
  const isLeft = direction === 'left'
  return (
    <button
      onClick={onClick}
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      style={{
        position: 'absolute',
        [isLeft ? 'left' : 'right']: 14,
        top: '50%', transform: 'translateY(-50%)',
        width: 40, height: 40, borderRadius: '50%', border: 'none',
        cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center',
        backgroundColor: hovered ? 'rgba(255,255,255,0.25)' : 'rgba(255,255,255,0.13)',
        backdropFilter: 'blur(8px)',
        transition: 'background-color 0.2s',
        zIndex: 10,
      }}
    >
      {isLeft ? <ChevronLeft size={22} color="white" /> : <ChevronRight size={22} color="white" />}
    </button>
  )
}

// ─── Hamburger side drawer ────────────────────────────────────────────────────

const NAV_ITEMS = [
  {
    icon: LayoutDashboard,
    label: 'Dashboard',
    badge: { text: 'MM Only', color: '#03DAC6', bg: 'rgba(3,218,198,0.12)' },
    description: 'Market Maker hub',
  },
  { icon: User,    label: 'Profile',  description: 'Your public profile' },
  { icon: Receipt, label: 'My Bets',  description: 'Active & past bets' },
  { icon: Wallet,  label: 'Wallet',   description: 'Tokens & transactions' },
  { icon: Trophy,  label: 'Arena',    description: 'Leaderboards & events' },
  { icon: Flame,   label: 'Hot Topic', description: 'Trending this week' },
]

const UTILITY_ITEMS = [
  { icon: Settings,    label: 'Settings' },
  { icon: HelpCircle,  label: 'Help' },
]

function DrawerNavRow({ item, active = false }) {
  const [hovered, setHovered] = useState(false)
  const highlighted = hovered || active
  const Icon = item.icon

  return (
    <button
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      style={{
        display: 'flex', alignItems: 'center', gap: 12,
        width: '100%', textAlign: 'left',
        background: highlighted ? 'rgba(108,99,255,0.10)' : 'none',
        border: 'none',
        borderLeft: `3px solid ${active ? '#6C63FF' : 'transparent'}`,
        borderRadius: active || hovered ? '0 8px 8px 0' : 0,
        cursor: 'pointer',
        padding: '11px 14px',
        transition: 'background 0.15s, border-color 0.15s',
      }}
    >
      {/* Icon */}
      <div style={{
        width: 34, height: 34, borderRadius: 8, flexShrink: 0,
        backgroundColor: highlighted ? 'rgba(108,99,255,0.18)' : 'rgba(42,42,62,0.8)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        transition: 'background 0.15s',
      }}>
        <Icon size={17} color={highlighted ? '#9B8FFF' : '#8B8FA8'} />
      </div>

      {/* Label + description */}
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
          <span style={{
            fontSize: 14, fontWeight: highlighted ? 600 : 500,
            color: highlighted ? 'white' : '#C8CAD8',
            transition: 'color 0.15s',
          }}>
            {item.label}
          </span>
          {item.badge && (
            <span style={{
              fontSize: 9, fontWeight: 700, letterSpacing: '0.06em',
              color: item.badge.color, backgroundColor: item.badge.bg,
              border: `1px solid ${item.badge.color}`,
              borderRadius: 999, padding: '1px 6px',
              textTransform: 'uppercase', flexShrink: 0,
              display: 'flex', alignItems: 'center', gap: 3,
            }}>
              <Crown size={8} />
              {item.badge.text}
            </span>
          )}
        </div>
        {item.description && (
          <div style={{ fontSize: 11, color: '#8B8FA8', marginTop: 1, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
            {item.description}
          </div>
        )}
      </div>
    </button>
  )
}

function SideDrawer({ open, onClose }) {
  return (
    <>
      {/* Backdrop */}
      {open && (
        <div
          onClick={onClose}
          style={{
            position: 'fixed', inset: 0,
            backgroundColor: 'rgba(0,0,0,0.55)',
            zIndex: 40, backdropFilter: 'blur(3px)',
          }}
        />
      )}

      {/* Panel */}
      <div style={{
        position: 'fixed', top: 0, left: 0, bottom: 0, width: 280,
        backgroundColor: '#12122A',
        borderRight: '1px solid #2A2A3E',
        zIndex: 50, display: 'flex', flexDirection: 'column',
        transform: open ? 'translateX(0)' : 'translateX(-100%)',
        transition: 'transform 0.28s cubic-bezier(0.4,0,0.2,1)',
        boxShadow: open ? '8px 0 32px rgba(0,0,0,0.55)' : 'none',
      }}>

        {/* ── Header ── */}
        <div style={{
          display: 'flex', alignItems: 'center', justifyContent: 'space-between',
          padding: '18px 20px 16px',
          borderBottom: '1px solid #2A2A3E',
        }}>
          <div>
            <div style={{ fontWeight: 800, fontSize: 15, color: 'white', letterSpacing: '-0.2px' }}>
              N.O.R.A. Platforms
            </div>
            <div style={{ fontSize: 11, color: '#6C63FF', marginTop: 2, fontWeight: 600 }}>Phase 1</div>
          </div>
          <button
            onClick={onClose}
            style={{
              background: 'rgba(42,42,62,0.8)', border: 'none', cursor: 'pointer',
              color: '#8B8FA8', display: 'flex', borderRadius: 8,
              padding: 7, transition: 'background 0.15s, color 0.15s',
            }}
            onMouseEnter={e => { e.currentTarget.style.background = 'rgba(108,99,255,0.2)'; e.currentTarget.style.color = 'white' }}
            onMouseLeave={e => { e.currentTarget.style.background = 'rgba(42,42,62,0.8)'; e.currentTarget.style.color = '#8B8FA8' }}
          >
            <X size={17} />
          </button>
        </div>

        {/* ── Guest user area ── */}
        <div style={{
          margin: '14px 16px',
          backgroundColor: 'rgba(108,99,255,0.08)',
          border: '1px solid rgba(108,99,255,0.2)',
          borderRadius: 12, padding: '12px 14px',
          display: 'flex', alignItems: 'center', gap: 12,
        }}>
          {/* Avatar placeholder */}
          <div style={{
            width: 40, height: 40, borderRadius: '50%', flexShrink: 0,
            background: 'linear-gradient(135deg, #2A2A3E, #3A3A5E)',
            border: '2px solid #2A2A3E',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
          }}>
            <User size={18} color="#8B8FA8" />
          </div>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 13, fontWeight: 600, color: '#C8CAD8' }}>Guest</div>
            <div style={{ fontSize: 11, color: '#8B8FA8', marginTop: 1 }}>Sign in for full access</div>
          </div>
          <button style={{
            display: 'flex', alignItems: 'center', gap: 5,
            background: 'none', border: '1px solid #6C63FF', borderRadius: 7,
            color: '#9B8FFF', fontSize: 12, fontWeight: 600, cursor: 'pointer',
            padding: '6px 10px', flexShrink: 0, transition: 'background 0.15s',
          }}
            onMouseEnter={e => { e.currentTarget.style.background = 'rgba(108,99,255,0.2)' }}
            onMouseLeave={e => { e.currentTarget.style.background = 'none' }}
          >
            <LogIn size={13} />
            Sign in
          </button>
        </div>

        {/* ── Main navigation ── */}
        <div style={{ padding: '6px 0', flex: 1, overflowY: 'auto' }}>
          <div style={{ padding: '4px 20px 8px', fontSize: 10, fontWeight: 700, color: '#8B8FA8', letterSpacing: '0.1em', textTransform: 'uppercase' }}>
            Navigate
          </div>
          {NAV_ITEMS.map(item => (
            <DrawerNavRow key={item.label} item={item} />
          ))}
        </div>

        {/* ── Divider ── */}
        <div style={{ height: 1, backgroundColor: '#2A2A3E', margin: '0 16px' }} />

        {/* ── Utility items ── */}
        <div style={{ padding: '8px 0 16px' }}>
          <div style={{ padding: '8px 20px 6px', fontSize: 10, fontWeight: 700, color: '#8B8FA8', letterSpacing: '0.1em', textTransform: 'uppercase' }}>
            Support
          </div>
          {UTILITY_ITEMS.map(item => (
            <DrawerNavRow key={item.label} item={item} />
          ))}
        </div>

        {/* ── Footer version tag ── */}
        <div style={{
          padding: '10px 20px 14px',
          borderTop: '1px solid #2A2A3E',
          fontSize: 11, color: '#8B8FA8',
          display: 'flex', justifyContent: 'space-between',
        }}>
          <span>v1.0.0 — Phase 1</span>
          <span style={{ color: '#2A2A3E' }}>NORA</span>
        </div>

      </div>
    </>
  )
}

// ─── Main Landing component ───────────────────────────────────────────────────

export default function Landing() {
  const [activeTab, setActiveTab] = useState(0)
  const [slide, setSlide] = useState(0)
  const [drawerOpen, setDrawerOpen] = useState(false)
  const timerRef = useRef(null)

  const resetTimer = useCallback(() => {
    clearInterval(timerRef.current)
    timerRef.current = setInterval(() => {
      setSlide(p => (p + 1) % CREATORS.length)
    }, 5000)
  }, [])

  useEffect(() => {
    resetTimer()
    return () => clearInterval(timerRef.current)
  }, [resetTimer])

  const goTo = useCallback((i) => {
    setSlide(i)
    resetTimer()
  }, [resetTimer])

  const prev = useCallback(() => goTo((slide - 1 + CREATORS.length) % CREATORS.length), [slide, goTo])
  const next = useCallback(() => goTo((slide + 1) % CREATORS.length), [slide, goTo])

  const creator = CREATORS[slide]

  return (
    <>
      {/* Global keyframes */}
      <style>{`
        @keyframes fadeIn {
          from { opacity: 0; }
          to   { opacity: 1; }
        }
        @keyframes slideUp {
          from { opacity: 0; transform: translateY(10px); }
          to   { opacity: 1; transform: translateY(0); }
        }
      `}</style>

      <div style={{ minHeight: '100vh', backgroundColor: '#0A0A0F', color: 'white' }}>

        <SideDrawer open={drawerOpen} onClose={() => setDrawerOpen(false)} />

        {/* ── HEADER ─────────────────────────────────────────────────────── */}
        <header style={{
          borderBottom: '1px solid #2A2A3E',
          padding: '12px 24px',
          display: 'flex', alignItems: 'center', gap: 12,
          position: 'sticky', top: 0, zIndex: 30,
          backgroundColor: 'rgba(10,10,15,0.92)',
          backdropFilter: 'blur(12px)',
        }}>
          {/* Hamburger */}
          <button
            onClick={() => setDrawerOpen(true)}
            style={{ background: 'none', border: 'none', cursor: 'pointer', padding: 6, display: 'flex', alignItems: 'center', borderRadius: 6 }}
          >
            <Menu size={21} color="white" />
          </button>

          {/* Logo */}
          <div style={{ border: '1px solid #2A2A3E', borderRadius: 8, padding: '6px 12px', flexShrink: 0, lineHeight: 1 }}>
            <div style={{ fontWeight: 800, fontSize: 13, color: 'white', letterSpacing: '-0.2px' }}>N.O.R.A. Platforms</div>
            <div style={{ fontSize: 11, color: '#8B8FA8', marginTop: 3 }}>Phase 1</div>
          </div>

          {/* Learn more pill */}
          <button style={{
            border: '1px solid #2A2A3E', borderRadius: 999,
            backgroundColor: 'transparent', padding: '7px 16px',
            fontSize: 12, color: '#8B8FA8', cursor: 'pointer', flexShrink: 0,
            transition: 'border-color 0.15s, color 0.15s',
          }}
            onMouseEnter={e => { e.currentTarget.style.borderColor = '#6C63FF'; e.currentTarget.style.color = 'white' }}
            onMouseLeave={e => { e.currentTarget.style.borderColor = '#2A2A3E'; e.currentTarget.style.color = '#8B8FA8' }}
          >
            Learn more about Phase 2 and Phase 3
          </button>

          {/* Search */}
          <div style={{ position: 'relative', flex: 1, maxWidth: 420 }}>
            <Search
              size={15} color="#8B8FA8"
              style={{ position: 'absolute', left: 13, top: '50%', transform: 'translateY(-50%)', pointerEvents: 'none' }}
            />
            <input
              placeholder="Search"
              style={{
                width: '100%', backgroundColor: '#1A1A2E',
                border: '1px solid #2A2A3E', borderRadius: 999,
                color: 'white', paddingLeft: 38, paddingRight: 16,
                paddingTop: 9, paddingBottom: 9, fontSize: 13,
                outline: 'none', boxSizing: 'border-box',
                transition: 'border-color 0.15s',
              }}
              onFocus={e => { e.target.style.borderColor = '#6C63FF' }}
              onBlur={e => { e.target.style.borderColor = '#2A2A3E' }}
            />
          </div>

          {/* Spacer */}
          <div style={{ flex: 1 }} />

          {/* Auth */}
          <button style={{ background: 'none', border: 'none', color: '#8B8FA8', fontSize: 14, fontWeight: 500, cursor: 'pointer', padding: '8px 4px', transition: 'color 0.15s' }}
            onMouseEnter={e => { e.currentTarget.style.color = 'white' }}
            onMouseLeave={e => { e.currentTarget.style.color = '#8B8FA8' }}
          >
            Login
          </button>
          <button style={{
            backgroundColor: '#6C63FF', border: 'none', borderRadius: 8,
            color: 'white', fontSize: 14, fontWeight: 600,
            padding: '8px 18px', cursor: 'pointer',
            transition: 'background-color 0.15s, box-shadow 0.15s',
          }}
            onMouseEnter={e => { e.currentTarget.style.backgroundColor = '#7B73FF'; e.currentTarget.style.boxShadow = '0 0 16px rgba(108,99,255,0.45)' }}
            onMouseLeave={e => { e.currentTarget.style.backgroundColor = '#6C63FF'; e.currentTarget.style.boxShadow = 'none' }}
          >
            Sign Up
          </button>
        </header>

        {/* ── CATEGORY NAV ────────────────────────────────────────────────── */}
        <nav style={{ borderBottom: '1px solid #2A2A3E', padding: '0 24px', display: 'flex', gap: 4, overflowX: 'auto' }}>
          {TABS.map((tab, i) => {
            const isActive = activeTab === i
            const sharedStyle = {
              padding: '13px 14px',
              fontSize: 13, fontWeight: isActive ? 600 : 400,
              color: isActive ? 'white' : '#8B8FA8',
              borderBottom: `2px solid ${isActive ? '#6C63FF' : 'transparent'}`,
              transition: 'color 0.15s, border-color 0.15s',
              whiteSpace: 'nowrap', flexShrink: 0, cursor: 'pointer',
            }

            if (tab.href) {
              return (
                <a
                  key={tab.label}
                  href={tab.href}
                  style={{ ...sharedStyle, background: 'none', border: 'none', textDecoration: 'none', display: 'inline-flex', alignItems: 'center', fontWeight: 600, color: '#6C63FF' }}
                  onMouseEnter={e => { e.currentTarget.style.color = '#9B8FFF' }}
                  onMouseLeave={e => { e.currentTarget.style.color = '#6C63FF' }}
                >
                  {tab.label} →
                </a>
              )
            }

            return (
              <button
                key={tab.label}
                onClick={() => setActiveTab(i)}
                style={{ ...sharedStyle, background: 'none', border: 'none' }}
                onMouseEnter={e => { if (!isActive) e.currentTarget.style.color = 'white' }}
                onMouseLeave={e => { if (!isActive) e.currentTarget.style.color = '#8B8FA8' }}
              >
                {tab.label}
              </button>
            )
          })}
        </nav>

        {/* ── MAIN CONTENT ─────────────────────────────────────────────────── */}
        <main style={{ padding: '24px 24px 40px' }}>

          {/* Section heading */}
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 12, marginBottom: 18 }}>
            <span style={{ fontSize: 27, fontWeight: 800, color: '#6C63FF', letterSpacing: '-0.5px' }}>
              {ORDINALS[slide]}
            </span>
            <h1 style={{ margin: 0, fontSize: 24, fontWeight: 700, letterSpacing: '-0.3px' }}>
              Weekly Spotlight
            </h1>
          </div>

          {/* Three-column layout */}
          <div style={{ display: 'flex', gap: 16, alignItems: 'stretch' }}>

            {/* ── SPOTLIGHT CARD ── */}
            <SpotlightCard
              creator={creator}
              onPrev={prev}
              onNext={next}
              currentSlide={slide}
              onDotClick={goTo}
            />

            {/* ── RANK SIDEBAR ── */}
            <div style={{ display: 'flex', flexDirection: 'column', gap: 10, width: 224, flexShrink: 0 }}>
              {CREATORS.slice(1).map(c => (
                <RankCard
                  key={c.rank}
                  creator={c}
                  isActive={slide === c.rank - 1}
                  onClick={() => goTo(c.rank - 1)}
                />
              ))}
            </div>

            {/* ── RIGHT COLUMN ── */}
            <div style={{ display: 'flex', flexDirection: 'column', gap: 14, width: 244, flexShrink: 0 }}>
              <NewsPanel />
              <GetTokensButton />
            </div>

          </div>
        </main>
      </div>
    </>
  )
}
