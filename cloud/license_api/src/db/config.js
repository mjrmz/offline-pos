export function databaseConfig(env = process.env) {
  if (!env.DATABASE_URL) throw new Error('DATABASE_URL is required');
  const config = { connectionString: env.DATABASE_URL };
  if (env.NODE_ENV === 'production') {
    if (!env.DB_SSL_CA_CERT) throw new Error('DB_SSL_CA_CERT is required in production');
    const url = new URL(env.DATABASE_URL);
    if (!['postgres:', 'postgresql:'].includes(url.protocol)) throw new Error('DATABASE_URL must be PostgreSQL');
    // node-postgres URL SSL parameters override the explicit CA configuration.
    for (const key of ['sslmode', 'sslrootcert', 'sslcert', 'sslkey']) url.searchParams.delete(key);
    config.connectionString = url.toString();
    config.ssl = { ca: env.DB_SSL_CA_CERT.replace(/\\n/g, '\n'), rejectUnauthorized: true };
  }
  return config;
}
