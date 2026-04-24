import { useState, useEffect } from 'react'
import { Wallet, TrendingUp, TrendingDown, RefreshCw } from 'lucide-react'
import { PageShell } from '../components/PageShell'
import { sbFetchAuth } from '../supabase'

export default function WalletPage() {
  return (
    <PageShell title="Wallet" requireAuth>
      {session => <WalletContent session={session} />}
    </PageShell>
  )
}

function WalletContent({ session }) {
  const [balance, setBalance] = useState(null)
  const [transactions, setTransactions] = useState([])
  const [loading, setLoading] = useState(true)
  const userId = session.user.id

  useEffect(() => {
    Promise.all([
      sbFetchAuth(`token_balances?user_id=eq.${userId}&select=balance`, session),
      sbFetchAuth(`token_transactions?user_id=eq.${userId}&select=amount,type,description,created_at&order=created_at.desc&limit=20`, session),
    ]).then(([bal, txs]) => {
      const b = Array.isArray(bal) ? bal[0] : bal
      setBalance(b?.balance ?? 0)
      setTransactions(Array.isArray(txs) ? txs : [])
      setLoading(false)
    }).catch(() => setLoading(false))
  }, [userId])

  if (loading) return <SkeletonLoader />

  return (
    <div style={{ padding: '24px 20px', maxWidth: 480, margin: '0 auto', width: '100%' }}>
      {/* Balance card */}
      <div style={{ background: 'linear-gradient(135deg, #6C63FF 0%, #03DAC6 100%)', borderRadius: 18, padding: '28px 24px', marginBottom: 20 }}>
        <div style={{ fontSize: 13, fontWeight: 600, color: 'rgba(255,255,255,0.75)', marginBottom: 4, letterSpacing: '0.05em', textTransform: 'uppercase' }}>Token Balance</div>
        <div style={{ fontSize: 44, fontWeight: 900, color: 'white', letterSpacing: '-1px', lineHeight: 1 }}>
          {balance?.toLocaleString() ?? '—'}
        </div>
        <div style={{ fontSize: 13, color: 'rgba(255,255,255,0.7)', marginTop: 4 }}>tokens</div>
      </div>

      {/* Get tokens */}
      <a href="/landing" style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8, backgroundColor: '#1A1A2E', border: '1px solid #6C63FF', borderRadius: 12, padding: '14px', color: '#9B8FFF', fontWeight: 700, fontSize: 14, textDecoration: 'none', marginBottom: 20, transition: 'background-color 0.15s' }}
        onMouseEnter={e => e.currentTarget.style.backgroundColor = '#16213E'}
        onMouseLeave={e => e.currentTarget.style.backgroundColor = '#1A1A2E'}
      >
        <Wallet size={16} /> Get More Tokens
      </a>

      {/* Transactions */}
      <div style={{ fontSize: 13, fontWeight: 700, color: '#8B8FA8', letterSpacing: '0.08em', textTransform: 'uppercase', marginBottom: 12 }}>
        Recent Transactions
      </div>
      {transactions.length === 0 ? (
        <div style={{ backgroundColor: '#1A1A2E', border: '1px solid #2A2A3E', borderRadius: 14, padding: '32px', textAlign: 'center', color: '#8B8FA8', fontSize: 14 }}>
          No transactions yet
        </div>
      ) : transactions.map((tx, i) => {
        const isPositive = tx.amount > 0
        return (
          <div key={i} style={{ backgroundColor: '#1A1A2E', border: '1px solid #2A2A3E', borderRadius: 12, padding: '14px 16px', marginBottom: 8, display: 'flex', alignItems: 'center', gap: 12 }}>
            <div style={{ width: 36, height: 36, borderRadius: 10, backgroundColor: isPositive ? 'rgba(0,200,150,0.12)' : 'rgba(255,71,87,0.12)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
              {tx.type === 'refund' ? <RefreshCw size={16} color="#8B8FA8" /> : isPositive ? <TrendingUp size={16} color="#00C896" /> : <TrendingDown size={16} color="#FF4757" />}
            </div>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 13, fontWeight: 600, color: 'white', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                {tx.description || tx.type}
              </div>
              <div style={{ fontSize: 11, color: '#8B8FA8', marginTop: 1 }}>
                {new Date(tx.created_at).toLocaleDateString()}
              </div>
            </div>
            <div style={{ fontSize: 14, fontWeight: 700, color: isPositive ? '#00C896' : '#FF4757', flexShrink: 0 }}>
              {isPositive ? '+' : ''}{tx.amount}
            </div>
          </div>
        )
      })}

      <OpenInApp path="/wallet" />
    </div>
  )
}

function SkeletonLoader() {
  return (
    <div style={{ padding: 24 }}>
      <div style={{ height: 120, backgroundColor: '#1A1A2E', borderRadius: 18, marginBottom: 16, opacity: 0.6 }} />
      {[1,2,3,4].map(i => <div key={i} style={{ height: 60, backgroundColor: '#1A1A2E', borderRadius: 12, marginBottom: 8, opacity: 0.6 }} />)}
    </div>
  )
}

function OpenInApp({ path }) {
  return (
    <a href={path} style={{ display: 'block', textAlign: 'center', backgroundColor: '#6C63FF', borderRadius: 12, padding: '14px', color: 'white', fontWeight: 700, fontSize: 15, textDecoration: 'none', marginTop: 12, transition: 'background-color 0.15s' }}
      onMouseEnter={e => e.currentTarget.style.backgroundColor = '#7B73FF'}
      onMouseLeave={e => e.currentTarget.style.backgroundColor = '#6C63FF'}
    >
      Open Full Wallet in App →
    </a>
  )
}
