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
