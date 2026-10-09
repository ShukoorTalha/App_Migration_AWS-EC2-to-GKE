#!/usr/bin/env bash
set -e

echo "Creating ClearPay project structure..."
mkdir -p db api/src/routes api/db ui/src

# ------------------------------------------------------------------------------
# 1. Database Schema
# ------------------------------------------------------------------------------
cat <<'EOF' > db/schema.sql
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS accounts (
    id SERIAL PRIMARY KEY,
    user_id INT REFERENCES users(id) ON DELETE CASCADE,
    balance_cents BIGINT NOT NULL DEFAULT 100000,
    currency VARCHAR(3) NOT NULL DEFAULT 'USD',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS transactions (
    id VARCHAR(64) PRIMARY KEY,
    idempotency_key VARCHAR(255) UNIQUE NOT NULL,
    from_user_id INT REFERENCES users(id),
    to_user_id INT REFERENCES users(id),
    amount_cents BIGINT NOT NULL,
    served_by VARCHAR(64) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
EOF

# ------------------------------------------------------------------------------
# 2. API Backend
# ------------------------------------------------------------------------------
cat <<'EOF' > api/package.json
{
  "name": "clearpay-api",
  "version": "1.0.0",
  "main": "src/index.js",
  "scripts": {
    "start": "node src/index.js",
    "seed": "node db/seed.js"
  },
  "dependencies": {
    "bcryptjs": "^2.4.3",
    "cors": "^2.8.5",
    "express": "^4.19.2",
    "jsonwebtoken": "^9.0.2",
    "pg": "^8.11.5"
  }
}
EOF

cat <<'EOF' > api/Dockerfile
FROM node:22-slim AS deps
WORKDIR /app
COPY package*.json ./
RUN npm install --omit=dev

FROM node:22-slim
WORKDIR /app
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*
RUN useradd -u 1001 -m appuser
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx /opt/yarn*
USER appuser
EXPOSE 4000
CMD ["node", "src/index.js"]
EOF

cat <<'EOF' > api/db/seed.js
const bcrypt = require('bcryptjs');
const { pool } = require('../src/db');

async function seed() {
  const users = [
    { email: 'alice@clearpay.dev', pass: 'password123' },
    { email: 'bob@clearpay.dev', pass: 'password123' }
  ];

  for (const u of users) {
    const existing = await pool.query('SELECT id FROM users WHERE email = $1', [u.email]);
    if (existing.rows.length > 0) {
      console.log(`skip (already exists): ${u.email}`);
      continue;
    }
    const hash = await bcrypt.hash(u.pass, 10);
    const resUser = await pool.query(
      'INSERT INTO users (email, password_hash) VALUES ($1, $2) RETURNING id',
      [u.email, hash]
    );
    await pool.query(
      'INSERT INTO accounts (user_id, balance_cents, currency) VALUES ($1, 100000, $2)',
      [resUser.rows[0].id, 'USD']
    );
    console.log(`seeded: ${u.email} (password: ${u.pass})`);
  }
  await pool.end();
}

seed().catch(err => {
  console.error('Seed error:', err);
  process.exit(1);
});
EOF

cat <<'EOF' > api/src/servedBy.js
const os = require('os');

module.exports = function getServedBy() {
  return {
    platform: process.env.PLATFORM || 'aws',
    version: process.env.APP_VERSION || '1.0.0',
    instance: os.hostname(),
    commit: process.env.GIT_COMMIT || 'local',
    rollback_active: process.env.ROLLBACK_ACTIVE === 'true'
  };
};
EOF

cat <<'EOF' > api/src/db.js
const { Pool } = require('pg');

const connectionString = process.env.DATABASE_URL || 'postgres://clearpay:clearpay123@postgres:5432/clearpay';
const pool = new Pool({
  connectionString,
  max: parseInt(process.env.DB_POOL_SIZE || '10', 10)
});

async function checkConnection() {
  const client = await pool.connect();
  try {
    await client.query('SELECT 1');
    return true;
  } finally {
    client.release();
  }
}

module.exports = { pool, checkConnection };
EOF

cat <<'EOF' > api/src/routes/auth.js
const express = require('express');
const router = express.Router();
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { pool } = require('../db');

const JWT_SECRET = process.env.JWT_SECRET || 'local_secret_key_12345';

router.post('/login', async (req, res) => {
  const { email, password } = req.body;
  try {
    const userRes = await pool.query('SELECT * FROM users WHERE email = $1', [email]);
    if (userRes.rows.length === 0) return res.status(401).json({ error: 'invalid credentials' });

    const user = userRes.rows[0];
    const match = await bcrypt.compare(password, user.password_hash);
    if (!match) return res.status(401).json({ error: 'invalid credentials' });

    const token = jwt.sign({ userId: user.id, email: user.email }, JWT_SECRET, { expiresIn: '12h' });
    res.json({ token, user: { id: user.id, email: user.email } });
  } catch (err) {
    res.status(500).json({ error: 'internal_error' });
  }
});

module.exports = router;
EOF

cat <<'EOF' > api/src/routes/accounts.js
const express = require('express');
const router = express.Router();
const jwt = require('jsonwebtoken');
const { pool } = require('../db');
const getServedBy = require('../servedBy');

const JWT_SECRET = process.env.JWT_SECRET || 'local_secret_key_12345';

router.get('/me', async (req, res) => {
  const auth = req.headers.authorization;
  if (!auth) return res.status(401).json({ error: 'missing_token' });

  try {
    const decoded = jwt.verify(auth.replace('Bearer ', ''), JWT_SECRET);
    const result = await pool.query('SELECT * FROM accounts WHERE user_id = $1', [decoded.userId]);
    if (result.rows.length === 0) return res.status(404).json({ error: 'account_not_found' });

    res.json({
      account: {
        id: result.rows[0].id,
        balance_cents: String(result.rows[0].balance_cents),
        currency: result.rows[0].currency
      },
      served_by: getServedBy()
    });
  } catch (err) {
    return res.status(401).json({ error: 'invalid_token' });
  }
});

module.exports = router;
EOF

cat <<'EOF' > api/src/routes/transactions.js
const express = require('express');
const router = express.Router();
const crypto = require('crypto');
const jwt = require('jsonwebtoken');
const { pool } = require('../db');
const getServedBy = require('../servedBy');

const JWT_SECRET = process.env.JWT_SECRET || 'local_secret_key_12345';

router.post('/', async (req, res) => {
  const auth = req.headers.authorization;
  if (!auth) return res.status(401).json({ error: 'missing_token' });

  let decoded;
  try {
    decoded = jwt.verify(auth.replace('Bearer ', ''), JWT_SECRET);
  } catch {
    return res.status(401).json({ error: 'invalid_token' });
  }

  const { to_email, amount_cents, idempotency_key } = req.body;
  const served = getServedBy();
  const servedStr = `${served.platform}/${served.version}`;

  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    if (idempotency_key) {
      const existingTx = await client.query('SELECT * FROM transactions WHERE idempotency_key = $1', [idempotency_key]);
      if (existingTx.rows.length > 0) {
        await client.query('ROLLBACK');
        return res.json({
          replayed: true,
          transaction: existingTx.rows[0],
          served_by: served
        });
      }
    }

    const toUser = await client.query('SELECT id FROM users WHERE email = $1', [to_email]);
    if (toUser.rows.length === 0) {
      await client.query('ROLLBACK');
      return res.status(400).json({ error: 'recipient_not_found' });
    }

    const fromAcc = await client.query('SELECT balance_cents FROM accounts WHERE user_id = $1 FOR UPDATE', [decoded.userId]);
    if (parseInt(fromAcc.rows[0].balance_cents, 10) < amount_cents) {
      await client.query('ROLLBACK');
      return res.status(400).json({ error: 'insufficient_funds' });
    }

    await client.query('UPDATE accounts SET balance_cents = balance_cents - $1 WHERE user_id = $2', [amount_cents, decoded.userId]);
    await client.query('UPDATE accounts SET balance_cents = balance_cents + $1 WHERE user_id = $2', [amount_cents, toUser.rows[0].id]);

    const txId = crypto.randomBytes(4).toString('hex');
    const tx = await client.query(
      `INSERT INTO transactions (id, idempotency_key, from_user_id, to_user_id, amount_cents, served_by)
       VALUES ($1, $2, $3, $4, $5, $6) RETURNING *`,
      [txId, idempotency_key || txId, decoded.userId, toUser.rows[0].id, amount_cents, servedStr]
    );

    await client.query('COMMIT');
    res.json({ replayed: false, transaction: tx.rows[0], served_by: served });
  } catch (err) {
    await client.query('ROLLBACK');
    console.error('Transaction failure:', err);
    res.status(500).json({ level: 'error', message: 'transaction_failed' });
  } finally {
    client.release();
  }
});

router.get('/', async (req, res) => {
  const result = await pool.query('SELECT * FROM transactions ORDER BY created_at DESC LIMIT 10');
  res.json({ transactions: result.rows, served_by: getServedBy() });
});

module.exports = router;
EOF

cat <<'EOF' > api/src/index.js
const express = require('express');
const cors = require('cors');
const { checkConnection } = require('./db');
const getServedBy = require('./servedBy');

const app = express();
app.use(cors());
app.use(express.json());

app.use('/api/auth', require('./routes/auth'));
app.use('/api/accounts', require('./routes/accounts'));
app.use('/api/transactions', require('./routes/transactions'));

app.get('/health', (req, res) => {
  res.json({ status: 'ok', served_by: getServedBy() });
});

app.get('/health/ready', async (req, res) => {
  try {
    await checkConnection();
    res.json({ status: 'ready', platform: process.env.PLATFORM || 'aws' });
  } catch (e) {
    res.status(500).json({ status: 'not_ready', error: e.message });
  }
});

app.get('/api/info', (req, res) => {
  const sb = getServedBy();
  res.json({ platform: sb.platform, rollback_active: sb.rollback_active });
});

const port = process.env.PORT || 4000;
app.listen(port, () => {
  console.log(JSON.stringify({ message: 'api_started', port }));
});
EOF

# ------------------------------------------------------------------------------
# 3. Frontend UI
# ------------------------------------------------------------------------------
cat <<'EOF' > ui/package.json
{
  "name": "clearpay-ui",
  "private": true,
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build"
  },
  "dependencies": {
    "react": "^18.3.1",
    "react-dom": "^18.3.1"
  },
  "devDependencies": {
    "@vitejs/plugin-react": "^4.3.0",
    "vite": "^5.3.0"
  }
}
EOF

cat <<'EOF' > ui/vite.config.js
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  server: {
    host: '0.0.0.0',
    port: 5173,
    proxy: {
      '/api': 'http://api:4000',
      '/health': 'http://api:4000'
    }
  }
});
EOF

cat <<'EOF' > ui/index.html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>ClearPay</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
EOF

cat <<'EOF' > ui/src/main.jsx
import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App';

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <App/>
  </React.StrictMode>
);
EOF

cat <<'EOF' > ui/src/App.jsx
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
EOF

# ------------------------------------------------------------------------------
# 4. Root Docker Compose
# ------------------------------------------------------------------------------
cat <<'EOF' > docker-compose.yml
services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: clearpay
      POSTGRES_PASSWORD: clearpay123
      POSTGRES_DB: clearpay
    ports:
      - "5432:5432"
    volumes:
      - ./db/schema.sql:/docker-entrypoint-initdb.d/init.sql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U clearpay -d clearpay"]
      interval: 3s
      timeout: 3s
      retries: 5

  api:
    build: ./api
    ports:
      - "4000:4000"
    environment:
      PLATFORM: aws
      APP_VERSION: 1.0.0
      GIT_COMMIT: local
      ROLLBACK_ACTIVE: "false"
      PORT: 4000
      DB_POOL_SIZE: "10"
      DATABASE_URL: postgres://clearpay:clearpay123@postgres:5432/clearpay
      JWT_SECRET: local_development_secret_32_bytes_long
    depends_on:
      postgres:
        condition: service_healthy

  ui:
    image: node:20-alpine
    working_dir: /app
    volumes:
      - ./ui:/app
    ports:
      - "5173:5173"
    command: sh -c "npm install && npm run dev -- --host 0.0.0.0"
    depends_on:
      - api
EOF

echo "All files successfully created."