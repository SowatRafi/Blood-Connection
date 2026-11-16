/** The API stays JavaScript; the optional Python LiveKit SDK is only a synthetic audio test client. */
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createTestApp } from '../test/helpers.js';

// Start an isolated test API on a random loopback port so the probe cannot alter interactive demo data.
async function main() {
  const { app } = await createTestApp({
    livekitUrl: 'ws://127.0.0.1:7880', livekitKey: 'bloodconnection-local',
    livekitSecret: 'local-development-only-blood-connection-not-for-production-2015',
  });
  try {
    const origin = await app.listen({ host: '127.0.0.1', port: 0 });
    // No shell is involved; a configured interpreter path cannot inject command-line syntax.
    await new Promise((resolve, reject) => {
      const child = spawn(process.env.PYTHON || 'python', ['-m', 'infra.test_local_calls'], {
        cwd: fileURLToPath(new URL('../../', import.meta.url)), stdio: 'inherit',
        env: { ...process.env, BLOOD_CALL_TEST_API_URL: origin },
      });
      child.on('error', reject);
      child.on('exit', code => code === 0 ? resolve() : reject(new Error(`Synthetic media client exited with status ${code}`)));
    });
  } finally { await app.close(); }
}

await main();
