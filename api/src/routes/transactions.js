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
