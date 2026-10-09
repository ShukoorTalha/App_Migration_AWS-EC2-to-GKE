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
