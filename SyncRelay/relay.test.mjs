import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { execFileSync } from 'node:child_process';
import { generateKeyPairSync, sign, X509Certificate } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join as joinPath } from 'node:path';
import WebSocket from 'ws';
import { createRelay } from './relay.mjs';
import { createReceiptVerifier, createSubscriptionAuthorizer, createAppStoreAuthorizerFromEnvironment } from './app-store-subscriptions.mjs';

const APPLE_CHAIN_OIDS = { leaf: '1.2.840.113635.100.6.11.1', intermediate: '1.2.840.113635.100.6.2.1' };

// Receipt-only checks belong to crypto/transport fixtures, never production authorization.
function createTransactionVerifier(options = {}) {
  const verifier = createReceiptVerifier(options);
  return async (jws) => {
    const t = await verifier.transaction(jws);
    return t && Number.isFinite(t.expiresDate) && t.expiresDate > Date.now() && t.revocationDate == null
      ? t.originalTransactionId : null;
  };
}

async function start(options) {
  const relay = createRelay({ heartbeatMs: 60_000, ...options });
  relay.server.listen(0, '127.0.0.1');
  await once(relay.server, 'listening');
  const base = `ws://127.0.0.1:${relay.server.address().port}`;
  return { ...relay, base, stop: () => new Promise((r) => { relay.wss.clients.forEach((c) => c.terminate()); relay.server.close(r); }) };
}

const FILE = '0123456789abcdef';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const closeCode = (socket) => once(socket, 'close').then(([code]) => code);

function join(base, path, name, { file = FILE, address, host = false } = {}) {
  const query = `?name=${encodeURIComponent(name)}` + (file === null ? '' : `&file=${file}`) + (host ? '&host=1' : '');
  const socket = new WebSocket(`${base}${path}${query}`, address ? { headers: { 'x-real-ip': address } } : {});
  socket.inbox = [];
  socket.waiters = [];
  socket.on('message', (data, isBinary) => {
    const item = isBinary ? Buffer.from(data) : JSON.parse(data.toString());
    const waiter = socket.waiters.shift();
    waiter ? waiter(item) : socket.inbox.push(item);
  });
  socket.next = () => socket.inbox.length ? Promise.resolve(socket.inbox.shift()) : new Promise((r) => socket.waiters.push(r));
  return socket;
}

test('pairs two devices and forwards binary messages both ways', async () => {
  const relay = await start();
  const teacher = join(relay.base, '/v1/rooms/123456', 'Teacher iPad');
  assert.deepEqual(await teacher.next(), { type: 'waiting' });
  const student = join(relay.base, '/v1/rooms/123456', 'Student');
  assert.deepEqual(await student.next(), { type: 'peer', name: 'Teacher iPad' });
  assert.deepEqual(await teacher.next(), { type: 'peer', name: 'Student' });

  teacher.send(Buffer.from([1, 2, 3]));
  assert.deepEqual(await student.next(), Buffer.from([1, 2, 3]));
  const big = Buffer.alloc(3 * 1024 * 1024, 7);
  student.send(big);
  assert.equal((await teacher.next()).length, big.length);

  // Text from a device is ignored, not forwarded.
  teacher.send('hello');
  teacher.send(Buffer.from([9]));
  assert.deepEqual(await student.next(), Buffer.from([9]));

  student.close();
  assert.deepEqual(await teacher.next(), { type: 'left' });
  teacher.close();
  await once(teacher, 'close');
  await new Promise((r) => setTimeout(r, 50));
  assert.equal(relay.rooms.size, 0, 'empty rooms are removed');
  await relay.stop();
});

test('a third device and bad addresses are refused', async () => {
  const relay = await start();
  const a = join(relay.base, '/v1/rooms/000111', 'A');
  await a.next();
  const b = join(relay.base, '/v1/rooms/000111', 'B');
  await b.next();
  const c = join(relay.base, '/v1/rooms/000111', 'C');
  const [code] = await once(c, 'close');
  assert.equal(code, 4009);
  const bad = join(relay.base, '/v1/rooms/12ab', 'X');
  const [badCode] = await once(bad, 'close');
  assert.equal(badCode, 4004);
  for (const file of [null, '', '0123456789ABCDEF', '0123456789abcde', '0123456789abcdef0', '0123456789abcdeg']) {
    assert.equal(await closeCode(join(relay.base, '/v1/rooms/555555', 'X', { file })), 4004, `file=${file}`);
  }
  assert.equal(relay.rooms.has('555555'), false);
  // Other rooms are independent.
  const d = join(relay.base, '/v1/rooms/999999', 'D');
  assert.deepEqual(await d.next(), { type: 'waiting' });
  await relay.stop();
});

test('pairs only devices with the same score file', async () => {
  const relay = await start();
  const teacher = join(relay.base, '/v1/rooms/424242', 'Teacher');
  assert.deepEqual(await teacher.next(), { type: 'waiting' });
  const stranger = join(relay.base, '/v1/rooms/424242', 'Stranger', { file: 'ffffffffffffffff' });
  assert.equal(await closeCode(stranger), 4003);
  await sleep(50);
  assert.deepEqual(teacher.inbox, [], 'the waiting device is told nothing');
  assert.equal(teacher.readyState, WebSocket.OPEN);

  const student = join(relay.base, '/v1/rooms/424242', 'Student');
  assert.deepEqual(await student.next(), { type: 'peer', name: 'Teacher' });
  assert.deepEqual(await teacher.next(), { type: 'peer', name: 'Student' });
  student.send(Buffer.from([4, 2]));
  assert.deepEqual(await teacher.next(), Buffer.from([4, 2]));
  // A mismatched file is refused as such even when the room is full.
  assert.equal(await closeCode(join(relay.base, '/v1/rooms/424242', 'Other', { file: 'ffffffffffffffff' })), 4003);

  // An emptied room forgets its file.
  teacher.close(); student.close();
  await Promise.all([once(teacher, 'close'), once(student, 'close')]);
  await sleep(50);
  const fresh = join(relay.base, '/v1/rooms/424242', 'Fresh', { file: 'ffffffffffffffff' });
  assert.deepEqual(await fresh.next(), { type: 'waiting' });
  await relay.stop();
});

test('limits joins per address, then refuses it for a while', async () => {
  const relay = await start({ joinsPerWindow: 3, joinWindowMs: 200, joinBlockMs: 500 });
  for (let i = 0; i < 3; i++) {
    const socket = join(relay.base, `/v1/rooms/70000${i}`, 'A', { address: '203.0.113.1' });
    assert.deepEqual(await socket.next(), { type: 'waiting' });
    socket.close();
  }
  assert.equal(await closeCode(join(relay.base, '/v1/rooms/700009', 'A', { address: '203.0.113.1' })), 4029);
  const other = join(relay.base, '/v1/rooms/700009', 'B', { address: '203.0.113.2' });
  assert.deepEqual(await other.next(), { type: 'waiting' }, 'other addresses are unaffected');
  other.close();
  await sleep(300);  // past the window but still blocked
  assert.equal(await closeCode(join(relay.base, '/v1/rooms/700009', 'A', { address: '203.0.113.1' })), 4029);
  await sleep(300);  // block over
  const again = join(relay.base, '/v1/rooms/700009', 'A', { address: '203.0.113.1' });
  assert.deepEqual(await again.next(), { type: 'waiting' });
  again.close();
  await sleep(500);
  assert.equal(relay.joins.size, 0, 'expired bookkeeping is removed');
  await relay.stop();
});

test('a device alone in a room expires, and the clock restarts after a peer leaves', async () => {
  const relay = await start({ idleMs: 300 });
  const lonely = join(relay.base, '/v1/rooms/808080', 'Lonely');
  assert.deepEqual(await lonely.next(), { type: 'waiting' });
  const started = Date.now();
  assert.equal(await closeCode(lonely), 4008);
  assert.ok(Date.now() - started >= 250);
  await sleep(50);
  assert.equal(relay.rooms.size, 0);

  const teacher = join(relay.base, '/v1/rooms/909090', 'Teacher');
  assert.deepEqual(await teacher.next(), { type: 'waiting' });
  await sleep(200);
  const student = join(relay.base, '/v1/rooms/909090', 'Student');
  assert.deepEqual(await teacher.next(), { type: 'peer', name: 'Student' });
  await sleep(400);  // well past the first device's original deadline
  assert.equal(teacher.readyState, WebSocket.OPEN, 'a paired room does not expire');
  student.close();
  assert.deepEqual(await teacher.next(), { type: 'left' });
  const left = Date.now();
  assert.equal(await closeCode(teacher), 4008);
  assert.ok(Date.now() - left >= 250, 'the full idle time starts again after the peer leaves');
  await relay.stop();
});

test('limits connections per address', async () => {
  const relay = await start({ perAddress: 2 });
  const one = join(relay.base, '/v1/rooms/100000', '1');
  await one.next();
  const two = join(relay.base, '/v1/rooms/200000', '2');
  await two.next();
  const three = join(relay.base, '/v1/rooms/300000', '3');
  const [code] = await once(three, 'close');
  assert.equal(code, 4029);
  await relay.stop();
});

test('health check', async () => {
  const relay = await start();
  const response = await fetch(relay.base.replace('ws:', 'http:') + '/health');
  assert.equal(await response.text(), 'ok');
  await relay.stop();
});

// ---- Subscription rooms ----
// Test certificates come from the openssl command line (node:crypto cannot issue them).

function makePki() {
  execFileSync('openssl', ['version'], { stdio: 'ignore' });
  const dir = mkdtempSync(joinPath(tmpdir(), 'mfsync-pki-'));
  try {
    const path = (name) => joinPath(dir, name);
    writeFileSync(path('ext.cnf'), [
      '[req]', 'distinguished_name = dn', '[dn]',
      '[root]', 'basicConstraints = critical,CA:true', 'keyUsage = critical,keyCertSign,cRLSign', 'subjectKeyIdentifier = hash',
      '[intermediate]', 'basicConstraints = critical,CA:true,pathlen:0', 'keyUsage = critical,keyCertSign,cRLSign',
      `${APPLE_CHAIN_OIDS.intermediate} = ASN1:NULL`,
      '[leaf]', 'basicConstraints = critical,CA:false', 'keyUsage = critical,digitalSignature', `${APPLE_CHAIN_OIDS.leaf} = ASN1:NULL`,
      '[bareLeaf]', 'basicConstraints = critical,CA:false', 'keyUsage = critical,digitalSignature', '',
    ].join('\n'));
    let serial = 1;
    const issue = (name, section, issuer) => {
      const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
      writeFileSync(path(`${name}.key`), privateKey.export({ type: 'pkcs8', format: 'pem' }));
      const common = ['-subj', `/CN=MusicFocus test ${name}`, '-key', path(`${name}.key`), '-config', path('ext.cnf')];
      if (!issuer) {
        execFileSync('openssl', ['req', '-x509', '-new', ...common, '-extensions', section, '-days', '30', '-sha256', '-set_serial', String(serial++), '-out', path(`${name}.pem`)], { stdio: 'pipe' });
      } else {
        execFileSync('openssl', ['req', '-new', ...common, '-out', path(`${name}.csr`)], { stdio: 'pipe' });
        execFileSync('openssl', ['x509', '-req', '-in', path(`${name}.csr`), '-CA', path(`${issuer}.pem`), '-CAkey', path(`${issuer}.key`),
          '-set_serial', String(serial++), '-days', '30', '-sha256', '-extfile', path('ext.cnf'), '-extensions', section, '-out', path(`${name}.pem`)], { stdio: 'pipe' });
      }
      const pem = readFileSync(path(`${name}.pem`), 'utf8');
      return { pem, der: new X509Certificate(pem).raw.toString('base64'), key: privateKey };
    };
    const root = issue('root', 'root');
    const intermediate = issue('intermediate', 'intermediate', 'root');
    const leaf = issue('leaf', 'leaf', 'intermediate');
    const bareLeaf = issue('bareLeaf', 'bareLeaf', 'intermediate');
    const otherRoot = issue('otherRoot', 'root');
    const otherIntermediate = issue('otherIntermediate', 'intermediate', 'otherRoot');
    const otherLeaf = issue('otherLeaf', 'leaf', 'otherIntermediate');
    return {
      root: root.pem,
      good: { key: leaf.key, x5c: [leaf.der, intermediate.der, root.der] },
      bare: { key: bareLeaf.key, x5c: [bareLeaf.der, intermediate.der, root.der] },
      // Names the trusted root as its third certificate, but its intermediate was not issued by it.
      untrusted: { key: otherLeaf.key, x5c: [otherLeaf.der, otherIntermediate.der, root.der] },
      // A genuine intermediate, but a leaf it did not issue.
      foreignLeaf: { key: otherLeaf.key, x5c: [otherLeaf.der, intermediate.der, root.der] },
    };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

let pki = null;
let noPki = false;
try { pki = makePki(); } catch (error) { noPki = `openssl is needed to make test certificates (${error.code ?? error.message})`; }

const b64url = (value) => Buffer.from(typeof value === 'string' ? value : JSON.stringify(value)).toString('base64url');
function transaction(overrides = {}, { chain = pki.good, header = {} } = {}) {
  const payload = {
    transactionId: '2000000123456789', originalTransactionId: '2000000000000001', bundleId: 'com.FeuxFollets.MusicFocus',
    productId: 'com.FeuxFollets.MusicFocus.rooms.yearly', type: 'Auto-Renewable Subscription', purchaseDate: Date.now() - 1000,
    expiresDate: Date.now() + 86_400_000, environment: 'Production', signedDate: Date.now(), ...overrides,
  };
  const input = `${b64url({ alg: 'ES256', x5c: chain.x5c, ...header })}.${b64url(payload)}`;
  return `${input}.${sign('sha256', Buffer.from(input), { key: chain.key, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
}
const entitlement = (jws) => JSON.stringify({ type: 'entitlement', jws });
// These transport tests script entitlement decisions with signed test receipts.
// Live status/renewal behavior is covered separately below, using the real authorizer.
const paid = (options = {}) => {
  const verify = createTransactionVerifier({ trustedRoots: pki ? [pki.root] : [], ...options });
  return start({ requireEntitlement: true, authorizeSubscription: async (jws) => {
    const owner = await verify(jws);
    return owner ? { owner, validUntil: Date.now() + 86_400_000 } : null;
  }, ...options });
};
function host(base, path, name, jws, options) {
  const socket = join(base, path, name, { host: true, ...options });
  socket.once('open', () => socket.send(entitlement(jws)));
  return socket;
}

test('the free relay ignores host=1 and entitlement frames', async () => {
  const relay = await start();
  const a = join(relay.base, '/v1/rooms/111222', 'A', { host: true });
  assert.deepEqual(await a.next(), { type: 'waiting' });
  a.send(entitlement('not.a.jws'));
  const b = join(relay.base, '/v1/rooms/111222', 'B');
  assert.deepEqual(await b.next(), { type: 'peer', name: 'A' });
  assert.deepEqual(await a.next(), { type: 'peer', name: 'B' });
  b.send(Buffer.from([5]));
  assert.deepEqual(await a.next(), Buffer.from([5]));
  // A join to a room nobody opened still works.
  const c = join(relay.base, '/v1/rooms/333444', 'C');
  assert.deepEqual(await c.next(), { type: 'waiting' });
  await relay.stop();
});

test('a joiner cannot open a room, nor see one whose host is still verifying', async () => {
  const relay = await start({ requireEntitlement: true });
  assert.equal(await closeCode(join(relay.base, '/v1/rooms/121212', 'Student')), 4010);
  const pending = join(relay.base, '/v1/rooms/121212', 'Teacher', { host: true });
  await once(pending, 'open');
  pending.send(Buffer.from([1]));
  assert.equal(await closeCode(join(relay.base, '/v1/rooms/121212', 'Student')), 4010);
  await sleep(50);
  assert.deepEqual(pending.inbox, [], 'an unverified host is told nothing');
  assert.equal(relay.rooms.size, 0);
  await relay.stop();
});

test('a subscriber opens a room and a joiner pairs with it', { skip: noPki }, async () => {
  const relay = await paid();
  const teacher = join(relay.base, '/v1/rooms/246810', 'Teacher', { host: true });
  await once(teacher, 'open');
  teacher.send(Buffer.from([0]));  // dropped: not verified yet
  teacher.send(entitlement(transaction({ environment: 'Sandbox' })));
  assert.deepEqual(await teacher.next(), { type: 'waiting' });
  const student = join(relay.base, '/v1/rooms/246810', 'Student');
  assert.deepEqual(await student.next(), { type: 'peer', name: 'Teacher' });
  assert.deepEqual(await teacher.next(), { type: 'peer', name: 'Student' });
  teacher.send(Buffer.from([1, 2]));
  assert.deepEqual(await student.next(), Buffer.from([1, 2]));
  student.send(Buffer.from([3, 4]));
  assert.deepEqual(await teacher.next(), Buffer.from([3, 4]));
  teacher.send(entitlement(transaction()));  // later text is ignored
  // The usual rules still apply to a verified host.
  assert.equal(await closeCode(host(relay.base, '/v1/rooms/246810', 'Third', transaction({ originalTransactionId: '9' }))), 4009);
  assert.equal(await closeCode(host(relay.base, '/v1/rooms/246810', 'Other', transaction(), { file: 'ffffffffffffffff' })), 4003);
  await relay.stop();
});

test('two subscribers may share a room', { skip: noPki }, async () => {
  const relay = await paid();
  const a = host(relay.base, '/v1/rooms/135790', 'A', transaction());
  assert.deepEqual(await a.next(), { type: 'waiting' });
  const b = host(relay.base, '/v1/rooms/135790', 'B', transaction({ originalTransactionId: '2000000000000002' }));
  assert.deepEqual(await b.next(), { type: 'peer', name: 'A' });
  assert.deepEqual(await a.next(), { type: 'peer', name: 'B' });
  b.send(Buffer.from([8]));
  assert.deepEqual(await a.next(), Buffer.from([8]));
  await relay.stop();
});

test('a joiner left in the room pairs when the host returns, and nothing passes before it verifies', { skip: noPki }, async () => {
  const relay = await paid();
  const teacher = host(relay.base, '/v1/rooms/987654', 'Teacher', transaction());
  assert.deepEqual(await teacher.next(), { type: 'waiting' });
  const student = join(relay.base, '/v1/rooms/987654', 'Student');
  assert.deepEqual(await student.next(), { type: 'peer', name: 'Teacher' });
  assert.deepEqual(await teacher.next(), { type: 'peer', name: 'Student' });
  teacher.close();
  assert.deepEqual(await student.next(), { type: 'left' });
  assert.equal(student.readyState, WebSocket.OPEN, 'the room stays open for the joiner');

  const back = join(relay.base, '/v1/rooms/987654', 'Teacher', { host: true });
  await once(back, 'open');
  back.send(Buffer.from([6, 6]));
  await sleep(100);
  assert.deepEqual(student.inbox, [], 'no peer message and no frames before verification');
  student.send(Buffer.from([7]));
  back.send(entitlement(transaction()));
  assert.deepEqual(await back.next(), { type: 'peer', name: 'Student' });
  assert.deepEqual(await student.next(), { type: 'peer', name: 'Teacher' });
  back.send(Buffer.from([9]));
  assert.deepEqual(await student.next(), Buffer.from([9]));
  student.send(Buffer.from([10]));
  assert.deepEqual(await back.next(), Buffer.from([10]), 'the frame sent before pairing was not delivered');
  await relay.stop();
});

test('newcomers may join a host-less room only within the grace period', { skip: noPki }, async () => {
  const relay = await paid({ hostGraceMs: 300 });
  const teacher = host(relay.base, '/v1/rooms/313131', 'Teacher', transaction());
  assert.deepEqual(await teacher.next(), { type: 'waiting' });
  const student = join(relay.base, '/v1/rooms/313131', 'Student');
  assert.deepEqual(await student.next(), { type: 'peer', name: 'Teacher' });
  await teacher.next();
  teacher.close();
  assert.deepEqual(await student.next(), { type: 'left' });

  const within = join(relay.base, '/v1/rooms/313131', 'Within');
  assert.deepEqual(await within.next(), { type: 'peer', name: 'Student' }, 'accepted within the grace period');
  assert.deepEqual(await student.next(), { type: 'peer', name: 'Within' });
  within.close();
  assert.deepEqual(await student.next(), { type: 'left' });
  await sleep(400);
  assert.equal(await closeCode(join(relay.base, '/v1/rooms/313131', 'After')), 4010, 'refused after the grace period');
  assert.equal(student.readyState, WebSocket.OPEN, 'the joiner already there stays');

  const back = host(relay.base, '/v1/rooms/313131', 'Teacher', transaction());
  assert.deepEqual(await back.next(), { type: 'peer', name: 'Student' }, 'a returning host still pairs');
  assert.deepEqual(await student.next(), { type: 'peer', name: 'Teacher' });
  student.close();
  assert.deepEqual(await back.next(), { type: 'left' });
  const next = join(relay.base, '/v1/rooms/313131', 'Next');
  assert.deepEqual(await next.next(), { type: 'peer', name: 'Teacher' }, 'open again while the host is in it');
  await relay.stop();
});

test('invalid, missing or late subscriptions are refused with 4002', { skip: noPki }, async () => {
  const relay = await paid({ entitlementTimeoutMs: 300 });
  const good = transaction();
  const [h, p, s] = good.split('.');
  const tamperedPayload = b64url({ ...JSON.parse(Buffer.from(p, 'base64url')), expiresDate: Date.now() + 9e12 });
  const flipped = Buffer.from(s, 'base64url'); flipped[10] ^= 1;
  const cases = {
    expired: transaction({ expiresDate: Date.now() - 1000 }),
    'no expiry': transaction({ expiresDate: undefined }),
    revoked: transaction({ revocationDate: Date.now() - 1000, revocationReason: 0 }),
    'wrong bundle': transaction({ bundleId: 'com.example.Other' }),
    'wrong product': transaction({ productId: 'com.FeuxFollets.MusicFocus.other' }),
    'Xcode environment': transaction({ environment: 'Xcode' }),
    'unknown environment': transaction({ environment: 'LocalTesting' }),
    'no original transaction': transaction({ originalTransactionId: undefined }),
    'signed in the future': transaction({ signedDate: Date.now() + 10 * 60_000 }),
    'no signing date': transaction({ signedDate: undefined }),
    'tampered payload': `${h}.${tamperedPayload}.${s}`,
    'tampered signature': `${h}.${p}.${flipped.toString('base64url')}`,
    'DER signature': `${h}.${p}.${sign('sha256', Buffer.from(`${h}.${p}`), pki.good.key).toString('base64url')}`,
    'untrusted chain': transaction({}, { chain: pki.untrusted }),
    'leaf not issued by the intermediate': transaction({}, { chain: pki.foreignLeaf }),
    'two certificates': transaction({}, { header: { x5c: pki.good.x5c.slice(0, 2) } }),
    'no chain': transaction({}, { header: { x5c: undefined } }),
    'alg none': transaction({}, { header: { alg: 'none' } }),
    'leaf and intermediate swapped': transaction({}, { header: { x5c: [pki.good.x5c[1], pki.good.x5c[0], pki.good.x5c[2]] } }),
    'two parts': `${h}.${p}`,
    garbage: 'not a jws',
    'bad base64': '%%%.%%%.%%%',
    number: 42,
  };
  let room = 500000;
  for (const [label, jws] of Object.entries(cases)) {
    assert.equal(await closeCode(host(relay.base, `/v1/rooms/${room++}`, 'H', jws)), 4002, label);
  }
  for (const frame of ['{"type":"hello"}', 'not json', JSON.stringify({ type: 'entitlement' })]) {
    const socket = join(relay.base, `/v1/rooms/${room++}`, 'H', { host: true });
    socket.once('open', () => socket.send(frame));
    assert.equal(await closeCode(socket), 4002, frame);
  }
  const silent = join(relay.base, `/v1/rooms/${room++}`, 'Silent', { host: true });
  await once(silent, 'open');
  const opened = Date.now();
  silent.send(Buffer.from([1]));  // binary does not count as the entitlement
  assert.equal(await closeCode(silent), 4002, 'timeout');
  assert.ok(Date.now() - opened >= 250);
  await sleep(50);
  assert.equal(relay.rooms.size, 0);
  assert.equal(relay.held.size, 0);
  const valid = host(relay.base, `/v1/rooms/${room++}`, 'Valid', good);
  assert.deepEqual(await valid.next(), { type: 'waiting' }, 'the untampered transaction is accepted');
  await relay.stop();
});

test('environment and trust options', { skip: noPki }, async () => {
  const strict = await paid({ allowSandbox: false });
  assert.equal(await closeCode(host(strict.base, '/v1/rooms/100001', 'H', transaction({ environment: 'Sandbox' }))), 4002);
  assert.deepEqual(await host(strict.base, '/v1/rooms/100002', 'H', transaction()).next(), { type: 'waiting' });
  await strict.stop();

  const xcode = await paid({ allowXcode: true });
  assert.equal(await closeCode(host(xcode.base, '/v1/rooms/100003', 'H', transaction({ environment: 'Xcode' }))), 4002, 'local Xcode receipts never grant server access');
  await xcode.stop();

  // With Apple's marker OIDs required, a leaf without one is refused.
  const marked = await paid({ chainOids: APPLE_CHAIN_OIDS });
  assert.deepEqual(await host(marked.base, '/v1/rooms/100004', 'H', transaction()).next(), { type: 'waiting' });
  assert.equal(await closeCode(host(marked.base, '/v1/rooms/100005', 'H', transaction({}, { chain: pki.bare }))), 4002);
  await marked.stop();

  // The default trust is Apple's root alone, which the test chain does not reach.
  const apple = await paid({ trustedRoots: undefined });
  assert.equal(await closeCode(host(apple.base, '/v1/rooms/100006', 'H', transaction())), 4002);
  await apple.stop();

  const products = await paid({ bundleId: 'org.example.App', productIds: ['a', 'b'] });
  assert.deepEqual(await host(products.base, '/v1/rooms/100007', 'H', transaction({ bundleId: 'org.example.App', productId: 'b' })).next(), { type: 'waiting' });
  await products.stop();
});

test('certificates are judged at the signing date, which cannot be in the future', { skip: noPki }, async () => {
  const verifyTransaction = createTransactionVerifier({ trustedRoots: [pki.root] });
  const day = 86_400_000;
  const realNow = Date.now;
  const later = realNow() + 31 * day;  // test certificates last 30 days
  const expires = { expiresDate: realNow() + 90 * day };
  assert.equal(await verifyTransaction(transaction({ ...expires, signedDate: realNow() + 60_000 })), '2000000000000001', 'within clock skew');
  assert.equal(await verifyTransaction(transaction({ ...expires, signedDate: realNow() + 10 * 60_000 })), null, 'signed in the future');
  assert.equal(await verifyTransaction(transaction({ ...expires, signedDate: realNow() - day })), null, 'signed before the certificates were valid');
  for (const signedDate of [undefined, String(realNow()), NaN, Infinity]) {
    assert.equal(await verifyTransaction(transaction({ ...expires, signedDate })), null, `signedDate ${signedDate}`);
  }
  const signedEarlier = transaction(expires);
  const signedAfterExpiry = transaction({ ...expires, signedDate: later });
  try {
    Date.now = () => later;
    assert.equal(await verifyTransaction(signedEarlier), '2000000000000001', 'signed while valid, leaf expired since');
    assert.equal(await verifyTransaction(signedAfterExpiry), null, 'signed after the certificates expired');
    assert.equal(await verifyTransaction(transaction({ expiresDate: later - 1 })), null, 'expiresDate uses the real clock');
  } finally {
    Date.now = realNow;
  }
});

test('one subscription holds a limited number of rooms', { skip: noPki }, async () => {
  const relay = await paid({ roomsPerSubscription: 2 });
  const mine = transaction();
  const one = host(relay.base, '/v1/rooms/400001', 'One', mine);
  assert.deepEqual(await one.next(), { type: 'waiting' });
  const two = host(relay.base, '/v1/rooms/400002', 'Two', mine);
  assert.deepEqual(await two.next(), { type: 'waiting' });
  assert.equal(await closeCode(host(relay.base, '/v1/rooms/400003', 'Three', mine)), 4002);
  // A second device of the same subscriber in a room it already holds is fine.
  const again = host(relay.base, '/v1/rooms/400001', 'One again', mine);
  assert.deepEqual(await again.next(), { type: 'peer', name: 'One' });
  // Another subscription is unaffected.
  const other = host(relay.base, '/v1/rooms/400003', 'Other', transaction({ originalTransactionId: '2000000000000003' }));
  assert.deepEqual(await other.next(), { type: 'waiting' });

  // Leaving a joiner behind keeps the room counted; an emptied room frees it.
  const student = join(relay.base, '/v1/rooms/400002', 'Student');
  assert.deepEqual(await student.next(), { type: 'peer', name: 'Two' });
  two.close();
  assert.deepEqual(await student.next(), { type: 'left' });
  assert.equal(await closeCode(host(relay.base, '/v1/rooms/400004', 'Four', mine)), 4002);
  student.close();
  await once(student, 'close');
  await sleep(50);
  const four = host(relay.base, '/v1/rooms/400004', 'Four', mine);
  assert.deepEqual(await four.next(), { type: 'waiting' });
  await relay.stop();
});

test('a refused subscription counts as an ordinary join', { skip: noPki }, async () => {
  const relay = await paid({ joinsPerWindow: 2 });
  const options = { address: '203.0.113.9' };
  assert.equal(await closeCode(host(relay.base, '/v1/rooms/600001', 'H', 'bad', options)), 4002);
  assert.equal(await closeCode(host(relay.base, '/v1/rooms/600002', 'H', 'bad', options)), 4002);
  assert.equal(await closeCode(host(relay.base, '/v1/rooms/600003', 'H', transaction(), options)), 4029);
  await relay.stop();
});

// ---- Current App Store status (real signature verification, scripted Apple API) ----
function renewal(overrides = {}) {
  const payload = {
    originalTransactionId: '2000000000000001', productId: 'com.FeuxFollets.MusicFocus.rooms.yearly',
    autoRenewProductId: 'com.FeuxFollets.MusicFocus.rooms.yearly', autoRenewStatus: 1,
    environment: 'Production', signedDate: Date.now(), gracePeriodExpiresDate: Date.now() + 86_400_000,
    ...overrides,
  };
  const input = `${b64url({ alg: 'ES256', x5c: pki.good.x5c })}.${b64url(payload)}`;
  return `${input}.${sign('sha256', Buffer.from(input), { key: pki.good.key, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
}
function statusResponse(jws, status = 1, signedRenewalInfo) {
  const t = JSON.parse(Buffer.from(jws.split('.')[1], 'base64url'));
  return { bundleId: t.bundleId, environment: t.environment, data: [{ lastTransactions: [{
    originalTransactionId: t.originalTransactionId, status, signedTransactionInfo: jws, signedRenewalInfo,
  }] }] };
}
const liveAuthorizer = (getStatuses) => createSubscriptionAuthorizer({ trustedRoots: [pki.root], getStatuses });

test('an old receipt cannot override the latest refund, but can locate a renewed subscription', { skip: noPki }, async () => {
  const old = transaction();
  let current = statusResponse(transaction({ revocationDate: Date.now() }), 5);
  let calls = 0;
  const authorize = liveAuthorizer(async (id, environment) => {
    calls++;
    assert.equal(id, '2000000000000001');
    assert.equal(environment, 'Production');
    return current;
  });
  assert.equal(await authorize(old), null, 'refund blocks a previously valid device receipt');
  current.data[0].lastTransactions[0].status = 1;
  assert.equal(await authorize(old), null, 'revocation on the signed latest transaction also blocks it');
  for (const status of [2, 3, 5]) {
    current = statusResponse(old, status);
    assert.equal(await authorize(old), null, 'expired/retry/revoked status ' + status);
  }
  const expiredDeviceReceipt = transaction({ expiresDate: Date.now() - 60_000 });
  current = statusResponse(transaction({ transactionId: 'renewal', expiresDate: Date.now() + 86_400_000 }));
  assert.equal((await authorize(expiredDeviceReceipt)).owner, 'Production:2000000000000001');
  assert.equal(calls, 6, 'no stale positive cache across status changes');
});

test('billing grace uses the verified renewal deadline, not the old transaction expiry', { skip: noPki }, async () => {
  const old = transaction({ expiresDate: Date.now() - 60_000 });
  let current = statusResponse(old, 4, renewal());
  const authorize = liveAuthorizer(async () => current);
  assert.ok((await authorize(old)).validUntil > Date.now());
  for (const overrides of [
    { gracePeriodExpiresDate: Date.now() - 1 }, { gracePeriodExpiresDate: undefined },
    { originalTransactionId: 'another subscriber' }, { productId: 'other product' },
    { environment: 'Sandbox' }, { signedDate: Date.now() + 10 * 60_000 },
  ]) {
    current = statusResponse(old, 4, renewal(overrides));
    assert.equal(await authorize(old), null, JSON.stringify(overrides));
  }
  current = statusResponse(old, 4, renewal() + 'tampered');
  assert.equal(await authorize(old), null);
  current = statusResponse(old, 1);
  assert.equal(await authorize(old), null, 'ordinary expired status is not a grace period');
});

test('latest entitlement must match the receipt owner, environment, app and room product', { skip: noPki }, async () => {
  const original = transaction();
  let current;
  let calls = 0;
  const authorize = liveAuthorizer(async () => { calls++; return current; });
  assert.equal(await authorize('forged.receipt.data'), null);
  assert.equal(calls, 0, 'invalid signatures never cause Apple API requests');
  for (const changes of [
    { originalTransactionId: 'someone else' }, { environment: 'Sandbox' },
    { bundleId: 'other.app' }, { productId: 'other.product' }, { isUpgraded: true },
  ]) {
    current = statusResponse(original);
    current.data[0].lastTransactions[0].signedTransactionInfo = transaction(changes);
    assert.equal(await authorize(original), null, JSON.stringify(changes));
  }
  current = statusResponse(original);
  current.data[0].lastTransactions[0].signedTransactionInfo = transaction({}, { chain: pki.untrusted });
  assert.equal(await authorize(original), null);
  current = { ...statusResponse(original), environment: 'Sandbox' };
  await assert.rejects(authorize(original), /temporarily unavailable/);
});

test('missing configuration and Apple errors close with retryable 4011, never a purchase request', { skip: noPki }, async () => {
  await assert.rejects(createAppStoreAuthorizerFromEnvironment({})(transaction()), /temporarily unavailable/);
  let unavailable = true;
  const original = transaction();
  const authorize = liveAuthorizer(async () => {
    if (unavailable) throw new Error('Apple unavailable');
    return statusResponse(original);
  });
  const relay = await paid({ authorizeSubscription: authorize });
  try {
    assert.equal(await closeCode(host(relay.base, '/v1/rooms/710001', 'H', original)), 4011);
    assert.equal(relay.rooms.size, 0);
    unavailable = false;
    assert.deepEqual(await host(relay.base, '/v1/rooms/710001', 'H', original).next(), { type: 'waiting' });
  } finally { await relay.stop(); }
});

test('late Apple responses cannot create a room after auth timeout or disconnect', { skip: noPki }, async () => {
  for (const disconnect of [false, true]) {
    let resolve;
    const relay = await paid({ entitlementTimeoutMs: 80, authorizeSubscription: () => new Promise((r) => { resolve = r; }) });
    try {
      const socket = host(relay.base, '/v1/rooms/720001', 'H', transaction());
      const closed = closeCode(socket);
      while (!resolve) await sleep(1);
      if (disconnect) socket.close();
      const code = await closed;
      if (!disconnect) assert.equal(code, 4011);
      resolve({ owner: 'test', validUntil: Date.now() + 60_000 });
      await sleep(20);
      assert.equal(relay.rooms.size, 0);
      assert.equal(relay.held.size, 0);
    } finally { await relay.stop(); }
  }
});

test('simultaneous Apple responses respect room capacity and score matching', { skip: noPki }, async () => {
  const pending = [];
  const relay = await paid({ authorizeSubscription: () => new Promise((resolve) => pending.push(resolve)) });
  try {
    const first = host(relay.base, '/v1/rooms/730001', 'First', transaction());
    const second = host(relay.base, '/v1/rooms/730001', 'Second', transaction());
    const third = host(relay.base, '/v1/rooms/730001', 'Third', transaction());
    const closed = closeCode(third);
    while (pending.length < 3) await sleep(1);
    pending.forEach((resolve) => resolve({ owner: 'same subscription', validUntil: Date.now() + 60_000 }));
    assert.deepEqual(await first.next(), { type: 'waiting' });
    assert.deepEqual(await second.next(), { type: 'peer', name: 'First' });
    assert.equal(await closed, 4009);
    assert.equal(relay.rooms.get('730001').sockets.size, 2);
  } finally { await relay.stop(); }
});

test('an in-use room rechecks refunds and can reconnect after a genuine renewal', { skip: noPki }, async () => {
  const original = transaction();
  let current = statusResponse(original);
  const relay = await paid({ recheckMs: 100, authorizeSubscription: liveAuthorizer(async () => current) });
  try {
    const teacher = host(relay.base, '/v1/rooms/740001', 'H', original);
    await teacher.next();
    const student = join(relay.base, '/v1/rooms/740001', 'S');
    await student.next(); await teacher.next();
    const teacherClosed = closeCode(teacher);
    current = statusResponse(transaction({ revocationDate: Date.now() }), 5);
    assert.equal(await teacherClosed, 4002);
    assert.deepEqual(await student.next(), { type: 'left' });
    assert.equal(await closeCode(host(relay.base, '/v1/rooms/740001', 'H', original)), 4002);
    current = statusResponse(transaction({ transactionId: 'new renewal' }));
    const restored = host(relay.base, '/v1/rooms/740001', 'H', original);
    assert.deepEqual(await restored.next(), { type: 'peer', name: 'S' });
    assert.deepEqual(await student.next(), { type: 'peer', name: 'H' });
    restored.send(Buffer.from([4, 2]));
    assert.deepEqual(await student.next(), Buffer.from([4, 2]));
  } finally { await relay.stop(); }
});

test('grace deadline is enforced while the room is connected', { skip: noPki }, async () => {
  const original = transaction({ expiresDate: Date.now() - 1000 });
  const current = statusResponse(original, 4, renewal({ gracePeriodExpiresDate: Date.now() + 180 }));
  const relay = await paid({ authorizeSubscription: liveAuthorizer(async () => current), recheckMs: 10_000 });
  try {
    const teacher = host(relay.base, '/v1/rooms/750001', 'H', original);
    const closed = closeCode(teacher);
    assert.deepEqual(await teacher.next(), { type: 'waiting' });
    assert.equal(await closed, 4002);
    await sleep(20);
    assert.equal(relay.held.size, 0);
  } finally { await relay.stop(); }
});
