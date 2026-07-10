import { Pool } from 'pg';

let pool: Pool;

const buildPool = (): Pool => {
  const databaseUrl = process.env.DATABASE_URL;

  if (databaseUrl) {
    return new Pool({
      connectionString: databaseUrl,
      max: 20,
      idleTimeoutMillis: 30000,
      connectionTimeoutMillis: 2000,
    });
  }

  return new Pool({
    host: process.env.DB_HOST || 'localhost',
    port: parseInt(process.env.DB_PORT || '5432', 10),
    database: process.env.DB_NAME || 'products_db',
    user: process.env.DB_USER || 'postgres',
    password: process.env.DB_PASSWORD || 'password',
    max: 20,
    idleTimeoutMillis: 30000,
    connectionTimeoutMillis: 2000,
  });
};

const sleep = (ms: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, ms));

export const connectDB = async (): Promise<void> => {
  const retryDelayMs = parseInt(process.env.DB_CONNECT_RETRY_DELAY_MS || '2000', 10);
  const maxRetryDelayMs = parseInt(process.env.DB_CONNECT_MAX_DELAY_MS || '10000', 10);
  const maxRetries = parseInt(process.env.DB_CONNECT_MAX_RETRIES || '0', 10);

  let attempt = 0;

  while (maxRetries === 0 || attempt < maxRetries) {
    attempt++;
    const candidatePool = buildPool();

    try {
      await candidatePool.query('SELECT NOW()');
      pool = candidatePool;
      console.log(`Connected to PostgreSQL database for product service after ${attempt} attempt(s)`);
      return;
    } catch (error) {
      await candidatePool.end().catch(() => undefined);

      const delayMs = Math.min(retryDelayMs * attempt, maxRetryDelayMs);
      console.error(
        `Database connection attempt ${attempt} failed for product service. Retrying in ${delayMs}ms...`,
        error
      );

      await sleep(delayMs);
    }
  }

  throw new Error('Exceeded maximum PostgreSQL connection retries for product service');
};

export const query = (text: string, params?: any[]): Promise<any> => {
  if (!pool) {
    throw new Error('Database not connected');
  }
  return pool.query(text, params);
};

export const getPool = (): Pool => {
  if (!pool) {
    throw new Error('Database not connected');
  }
  return pool;
};
