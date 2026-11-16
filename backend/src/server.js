import { createApp } from './app.js';

// Only the launcher owns the network listener; tests use Fastify's in-memory HTTP injection.
const app = await createApp();
await app.listen({ host: app.settings.host, port: app.settings.port });
console.info(`Blood Connection API listening on ${app.settings.host}:${app.settings.port}`);
for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, async () => { await app.close(); process.exit(0); });
