import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, verify } from 'node:crypto';
import { Environment } from '@apple/app-store-server-library';
import { BoundedAppStoreClient, BUNDLE_ID } from './app-store-subscriptions.mjs';

test('Apple API adapter signs requests, selects the environment and applies a timeout', async () => {
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const key = privateKey.export({ type: 'pkcs8', format: 'pem' });
  const originalFetch = globalThis.fetch;
  let requests = 0;
  try {
    for (const [environment, expectedHost] of [
      [Environment.PRODUCTION, 'api.storekit.apple.com'],
      [Environment.SANDBOX, 'api.storekit-sandbox.apple.com'],
    ]) {
      globalThis.fetch = async (url, options) => {
        requests++;
        assert.equal(new URL(url).host, expectedHost);
        assert.equal(new URL(url).pathname, '/inApps/v1/subscriptions/123456789');
        assert.equal(options.method, 'GET');
        assert.ok(options.signal instanceof AbortSignal, 'request and body reads can be cancelled');
        const token = options.headers.Authorization.replace(/^Bearer /, '');
        const [header, payload, signature] = token.split('.');
        const claims = JSON.parse(Buffer.from(payload, 'base64url'));
        assert.equal(claims.bid, BUNDLE_ID);
        assert.equal(claims.iss, 'test-issuer');
        assert.equal(JSON.parse(Buffer.from(header, 'base64url')).kid, 'test-key');
        assert.ok(verify('sha256', Buffer.from(header + '.' + payload),
          { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(signature, 'base64url')));
        return new Response(JSON.stringify({ bundleId: BUNDLE_ID, environment, data: [] }), { status: 200 });
      };
      const client = new BoundedAppStoreClient(key, 'test-key', 'test-issuer', BUNDLE_ID, environment);
      assert.deepEqual((await client.getAllSubscriptionStatuses('123456789')).data, []);
    }
    assert.equal(requests, 2);
  } finally { globalThis.fetch = originalFetch; }
});
