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
