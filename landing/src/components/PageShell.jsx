import { useState, useEffect } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { ChevronLeft } from 'lucide-react'
import { supabase } from '../supabase'

// ── Auth guard + page shell ────────────────────────────────────────────────

export function useSession() {
  const [session, setSession] = useState(undefined) // undefined = loading

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => setSession(data.session ?? null))
    const { data: { subscription } } = supabase.auth.onAuthStateChange((_e, s) => setSession(s))
    return () => subscription.unsubscribe()
  }, [])

  return session
}

export function PageShell({ title, children, requireAuth = false }) {
  const navigate = useNavigate()
  const session = useSession()

  if (session === undefined) {
    return (
      <div style={{ minHeight: '100vh', backgroundColor: '#0A0A0F', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <div style={{ width: 32, height: 32, border: '3px solid #6C63FF', borderTopColor: 'transparent', borderRadius: '50%', animation: 'spin 0.8s linear infinite' }} />
        <style>{`@keyframes spin { to { transform: rotate(360deg) } }`}</style>
      </div>
    )
  }

  if (requireAuth && !session) {
    return (
      <div style={{ minHeight: '100vh', backgroundColor: '#0A0A0F', color: 'white', display: 'flex', flexDirection: 'column' }}>
        <Header title={title} onBack={() => navigate('/')} />
        <SignInPrompt title={title} />
      </div>
    )
  }

  return (
    <div style={{ minHeight: '100vh', backgroundColor: '#0A0A0F', color: 'white', display: 'flex', flexDirection: 'column' }}>
      <Header title={title} onBack={() => navigate('/')} />
      {children(session)}
    </div>
  )
}

function Header({ title, onBack }) {
  return (
    <header style={{
      borderBottom: '1px solid #2A2A3E',
      padding: '12px 20px',
      display: 'flex', alignItems: 'center', gap: 12,
      position: 'sticky', top: 0, zIndex: 30,
      backgroundColor: 'rgba(10,10,15,0.92)',
      backdropFilter: 'blur(12px)',
    }}>
      <button onClick={onBack} style={{ background: 'none', border: 'none', cursor: 'pointer', display: 'flex', alignItems: 'center', color: '#8B8FA8', padding: 4, transition: 'color 0.15s' }}
        onMouseEnter={e => e.currentTarget.style.color = 'white'}
        onMouseLeave={e => e.currentTarget.style.color = '#8B8FA8'}
      >
        <ChevronLeft size={22} />
      </button>
      <div style={{ fontWeight: 700, fontSize: 16, color: 'white' }}>{title}</div>
      <div style={{ flex: 1 }} />
      <Link to="/" style={{ border: '1px solid #2A2A3E', borderRadius: 8, padding: '6px 12px', fontSize: 12, color: '#8B8FA8', textDecoration: 'none', fontWeight: 600 }}>
        N.O.R.A.
      </Link>
    </header>
  )
}

function SignInPrompt({ title }) {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState(null)

  async function handleSignIn(e) {
    e.preventDefault()
    setLoading(true)
    setError(null)
    const { error: err } = await supabase.auth.signInWithPassword({ email, password })
    if (err) {
      setError(err.message)
      setLoading(false)
    }
    // On success, onAuthStateChange fires and session updates — page re-renders
  }

  const input = {
    width: '100%', backgroundColor: '#1A1A2E', border: '1px solid #2A2A3E',
    borderRadius: 10, color: 'white', padding: '12px 14px', fontSize: 14,
    outline: 'none', boxSizing: 'border-box',
  }

  return (
    <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 24 }}>
      <div style={{ width: '100%', maxWidth: 380 }}>
        <div style={{ textAlign: 'center', marginBottom: 32 }}>
          <div style={{ fontSize: 36, fontWeight: 800, color: '#6C63FF', letterSpacing: 4, marginBottom: 4 }}>N.O.R.A.</div>
          <div style={{ fontSize: 13, color: '#8B8FA8' }}>Sign in to view {title}</div>
        </div>
        <form onSubmit={handleSignIn} style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
          <input style={input} type="email" placeholder="Email" value={email} onChange={e => setEmail(e.target.value)} required
            onFocus={e => e.target.style.borderColor = '#6C63FF'}
            onBlur={e => e.target.style.borderColor = '#2A2A3E'}
          />
          <input style={input} type="password" placeholder="Password" value={password} onChange={e => setPassword(e.target.value)} required
            onFocus={e => e.target.style.borderColor = '#6C63FF'}
            onBlur={e => e.target.style.borderColor = '#2A2A3E'}
          />
          {error && <p style={{ margin: 0, color: '#FF4757', fontSize: 13, textAlign: 'center' }}>{error}</p>}
          <button type="submit" disabled={loading} style={{
            backgroundColor: loading ? '#3A3A5E' : '#6C63FF', border: 'none', borderRadius: 10,
            color: 'white', fontSize: 15, fontWeight: 700, padding: '14px', cursor: loading ? 'default' : 'pointer',
            transition: 'background-color 0.15s',
          }}>
            {loading ? 'Signing in…' : 'Sign In'}
          </button>
        </form>
        <p style={{ textAlign: 'center', fontSize: 13, color: '#8B8FA8', marginTop: 20 }}>
          Don't have an account?{' '}
          <a href="/signup" style={{ color: '#6C63FF', fontWeight: 600 }}>Sign Up</a>
        </p>
      </div>
    </div>
  )
}
