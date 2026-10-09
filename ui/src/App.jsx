import React, { useState, useEffect } from 'react';

export default function App() {
  const [token, setToken] = useState(localStorage.getItem('token') || '');
  const [email, setEmail] = useState('alice@clearpay.dev');
  const [password, setPassword] = useState('password123');
  const [account, setAccount] = useState(null);
  const [toEmail, setToEmail] = useState('bob@clearpay.dev');
  const [amount, setAmount] = useState('20.00');
  const [transactions, setTransactions] = useState([]);
  const [operational, setOperational] = useState(false);
  const [rollbackActive, setRollbackActive] = useState(false);
  const [errorMsg, setErrorMsg] = useState('');

  const checkHealth = () => {
    fetch('/health/ready')
      .then(r => r.ok ? setOperational(true) : setOperational(false))
      .catch(() => setOperational(false));
    fetch('/api/info')
      .then(r => r.json())
      .then(d => setRollbackActive(d.rollback_active))
      .catch(() => {});
  };

  const loadDashboard = (authToken) => {
    fetch('/api/accounts/me', { headers: { Authorization: `Bearer ${authToken}` } })
      .then(r => r.json())
      .then(d => { if (d.account) setAccount(d.account); });

    fetch('/api/transactions', { headers: { Authorization: `Bearer ${authToken}` } })
      .then(r => r.json())
      .then(d => { if (d.transactions) setTransactions(d.transactions); });
  };

  useEffect(() => {
    checkHealth();
    if (token) loadDashboard(token);
  }, [token]);

  const handleLogin = async (e) => {
    e.preventDefault();
    setErrorMsg('');
    const res = await fetch('/api/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, password })
    });
    const data = await res.json();
    if (data.token) {
      setToken(data.token);
      localStorage.setItem('token', data.token);
      loadDashboard(data.token);
    } else {
      setErrorMsg(data.error || 'Login failed');
    }
  };

  const handleSend = async (e) => {
    e.preventDefault();
    const cents = Math.round(parseFloat(amount) * 100);
    const idempotencyKey = 'web-' + Math.random().toString(36).substring(2, 9);
    await fetch('/api/transactions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`
      },
      body: JSON.stringify({ to_email: toEmail, amount_cents: cents, idempotency_key: idempotencyKey })
    });
    loadDashboard(token);
  };

  return (
    <div style={{ fontFamily: 'sans-serif', maxWidth: 520, margin: '40px auto', border: '1px solid #ddd', borderRadius: 8, padding: 24, boxShadow: '0 4px 12px rgba(0,0,0,0.08)' }}>
      {rollbackActive && (
        <div style={{ backgroundColor: '#ffebee', color: '#c62828', padding: 10, marginBottom: 12, borderRadius: 4, fontWeight: 'bold' }}>
          Rolled back to AWS, traffic has been restored while the GKE issue is investigated.
        </div>
      )}
      <div style={{ background: operational ? '#1b5e20' : '#c62828', color: '#fff', padding: '6px 12px', borderRadius: 4, marginBottom: 20, fontSize: '14px' }}>
        ● {operational ? 'All systems operational' : 'System Degraded'}
      </div>

      <h1 style={{ marginTop: 0 }}>ClearPay</h1>

      {!token ? (
        <form onSubmit={handleLogin}>
          <h3>Sign in</h3>
          {errorMsg && <p style={{ color: 'red' }}>{errorMsg}</p>}
          <label style={{ display: 'block', marginBottom: 4 }}>Email</label>
          <input value={email} onChange={e => setEmail(e.target.value)} style={{ display: 'block', width: '100%', padding: 8, marginBottom: 12, boxSizing: 'border-box' }} />
          <label style={{ display: 'block', marginBottom: 4 }}>Password</label>
          <input type="password" value={password} onChange={e => setPassword(e.target.value)} style={{ display: 'block', width: '100%', padding: 8, marginBottom: 16, boxSizing: 'border-box' }} />
          <button type="submit" style={{ padding: '8px 16px', background: '#0288d1', color: '#fff', border: 'none', borderRadius: 4, cursor: 'pointer' }}>Sign in</button>
        </form>
      ) : (
        <div>
          <p>Signed in as <strong>{email}</strong></p>
          <h2 style={{ color: '#2e7d32' }}>Balance: ${(account?.balance_cents / 100).toFixed(2)} {account?.currency}</h2>

          <form onSubmit={handleSend} style={{ border: '1px solid #eee', background: '#f9f9f9', padding: 16, borderRadius: 6, marginBottom: 20 }}>
            <h4 style={{ margin: '0 0 12px 0' }}>Send money</h4>
            <label style={{ display: 'block', marginBottom: 4 }}>Send to (email):</label>
            <input value={toEmail} onChange={e => setToEmail(e.target.value)} style={{ display: 'block', width: '100%', padding: 8, marginBottom: 12, boxSizing: 'border-box' }} />
            <label style={{ display: 'block', marginBottom: 4 }}>Amount (USD):</label>
            <input value={amount} onChange={e => setAmount(e.target.value)} style={{ display: 'block', width: '100%', padding: 8, marginBottom: 16, boxSizing: 'border-box' }} />
            <button type="submit" style={{ padding: '8px 16px', background: '#2e7d32', color: '#fff', border: 'none', borderRadius: 4, cursor: 'pointer' }}>Send money</button>
          </form>

          <h4>Recent activity</h4>
          <ul style={{ paddingLeft: 20 }}>
            {transactions.map(tx => (
              <li key={tx.id} style={{ marginBottom: 10 }}>
                Sent {tx.id} | <strong>-${(tx.amount_cents / 100).toFixed(2)}</strong> | <small style={{ color: '#666' }}>served by {tx.served_by}</small>
              </li>
            ))}
          </ul>
          <button onClick={() => { setToken(''); localStorage.removeItem('token'); }} style={{ marginTop: 10, padding: '6px 12px', background: '#eee', border: '1px solid #ccc', borderRadius: 4, cursor: 'pointer' }}>Sign out</button>
        </div>
      )}
    </div>
  );
}
