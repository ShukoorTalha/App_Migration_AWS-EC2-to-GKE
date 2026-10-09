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
