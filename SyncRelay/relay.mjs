// MusicFocus remote score sync relay.
//
// Two devices open wss://<host>/v1/rooms/<6 digits>?name=<device name>&file=<16 hex>,
// where file is the start of the score PDF's SHA-256. The relay pairs them only
// when file matches and forwards binary frames from one to the other; it never
// reads, stores or logs their content (score annotations, viewport, metronome).
// Text frames from the relay tell a device what happened:
//   {"type":"waiting"}             alone in the room
//   {"type":"peer","name":"..."}   the other device is here
//   {"type":"left"}                the other device went away
// Close codes: 4003 the other device has a different score, 4004 bad address,
// 4008 alone in the room too long, 4009 room already has two devices,
// 4029 too many connections or joins from this address.
//
// With requireEntitlement (the international relay) only a subscriber opens a
// room: it connects with &host=1, first sends
//   {"type":"entitlement","jws":"<StoreKit 2 signed transaction>"}
// and is placed in the room once that verifies. A device without host=1 can only
// join a room while a verified host is in it, or within hostGraceMs after the
// last one left. Extra close codes: 4002 subscription required (missing,
// invalid or late, or the subscription already holds roomsPerSubscription rooms),
// 4010 room not open, 4011 Apple verification temporarily unavailable (retry).
import http from 'node:http';
import { realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';

import { createAppStoreAuthorizerFromEnvironment } from './app-store-subscriptions.mjs';

export function createRelay({
  maxPayload = 32 * 1024 * 1024, maxRooms = 5000, perAddress = 20, heartbeatMs = 25_000,
  joinsPerWindow = 30, joinWindowMs = 60_000, joinBlockMs = 5 * 60_000, idleMs = 15 * 60_000,
  requireEntitlement = false, entitlementTimeoutMs = 10_000, roomsPerSubscription = 3, hostGraceMs = 2 * 60_000,
  authorizeSubscription, recheckMs = 5 * 60_000
} = {}) {
  // code -> { sockets: Set<socket>, file, idle, owners: Set<originalTransactionId>, hosts: verified hosts present, hostLeftAt: ms }
  const rooms = new Map();
  const addresses = new Map();  // remote address -> open connections
  const joins = new Map();      // remote address -> { times: [ms], blockedUntil: ms }
  const held = new Map();       // originalTransactionId -> Set<code> of rooms its hosts are or were in
  const authorize = requireEntitlement ? authorizeSubscription ?? createAppStoreAuthorizerFromEnvironment() : null;

  // Loose on purpose: teacher and student may share one public address and
  // reconnect after network drops. Exceeding it refuses the address for a while.
  function admit(address) {
    const now = Date.now();
    let entry = joins.get(address);
    if (entry && entry.blockedUntil > now) return false;
    if (!entry || entry.blockedUntil) { entry = { times: [], blockedUntil: 0 }; joins.set(address, entry); }
    entry.times = entry.times.filter((t) => now - t < joinWindowMs);
    if (entry.times.length >= joinsPerWindow) { entry.times = []; entry.blockedUntil = now + joinBlockMs; return false; }
    entry.times.push(now);
    return true;
  }
  const sweep = setInterval(() => {
    const now = Date.now();
    for (const [address, entry] of joins) {
      if (entry.blockedUntil <= now && entry.times.every((t) => now - t >= joinWindowMs)) joins.delete(address);
    }
  }, Math.min(joinWindowMs, joinBlockMs));
  sweep.unref();

  // A device alone in a room is closed after idleMs; a peer joining stops the clock.
  function armIdle(room) {
    clearTimeout(room.idle);
    room.idle = setTimeout(() => { for (const s of room.sockets) s.close(4008, 'room expired'); }, idleMs);
    room.idle.unref();
  }

  const server = http.createServer((req, res) => {
    if (req.method === 'GET' && req.url === '/health') {
      res.writeHead(200, { 'content-type': 'text/plain', 'cache-control': 'no-store' });
      res.end('ok');
      return;
    }
    res.writeHead(404, { 'cache-control': 'no-store' });
    res.end();
  });
  const wss = new WebSocketServer({ server, maxPayload, perMessageDeflate: false });

  function send(socket, message) {
    if (socket.readyState === socket.OPEN) socket.send(JSON.stringify(message));
  }

  wss.on('connection', (socket, req) => {
    // Behind Cloudflare and Nginx (which sets X-Real-IP) these name the client.
    const address = String(req.headers['cf-connecting-ip'] ?? req.headers['x-real-ip'] ?? req.socket.remoteAddress ?? '').trim();
    if (!admit(address)) { socket.close(4029, 'too many joins'); return; }
    const url = new URL(req.url, 'http://relay');
    const match = /^\/v1\/rooms\/(\d{6})$/.exec(url.pathname);
    const file = url.searchParams.get('file') ?? '';
    if (!match || !/^[0-9a-f]{16}$/.test(file)) { socket.close(4004, 'bad address'); return; }
    if ((addresses.get(address) ?? 0) >= perAddress) { socket.close(4029, 'too many connections'); return; }
    const code = match[1];
    const host = requireEntitlement && url.searchParams.get('host') === '1';
    // A host still verifying has not opened its room yet. Without a host for a
    // while the room is closed to newcomers, so joiners cannot keep it going for free.
    const open = (room) => room && (room.hosts > 0 || Date.now() - room.hostLeftAt < hostGraceMs);
    if (requireEntitlement && !host && !open(rooms.get(code))) { socket.close(4010, 'room not open'); return; }
    // Someone who guesses a room number without the same PDF cannot pair, and
    // the device already in the room is not disturbed.
    const refusal = () => {
      const room = rooms.get(code);
      if (!room) return rooms.size >= maxRooms ? [4029, 'busy'] : null;
      if (room.file !== file) return [4003, 'different score'];
      if (room.sockets.size >= 2) return [4009, 'room full'];
      return null;
    };
    const refused = host ? null : refusal();
    if (refused) { socket.close(...refused); return; }

    addresses.set(address, (addresses.get(address) ?? 0) + 1);
    socket.deviceName = (url.searchParams.get('name') ?? '').trim().slice(0, 40) || 'iPad';
    socket.alive = true;
    let room = null;
    let owner = null;  // originalTransactionId of a verified host
    let pending = host;
    let recheck;
    let checking = false;
    let receipt;
    const deadline = host ? setTimeout(() => socket.close(checking ? 4011 : 4002,
      checking ? 'subscription service unavailable' : 'subscription required'), entitlementTimeoutMs) : null;

    const other = () => room && [...room.sockets].find((s) => s !== socket);
    function enter() {
      room = rooms.get(code);
      if (!room) { room = { sockets: new Set(), file, idle: null, owners: new Set(), hosts: 0, hostLeftAt: 0 }; rooms.set(code, room); }
      room.sockets.add(socket);
      if (owner) { room.hosts++; room.owners.add(owner); held.set(owner, (held.get(owner) ?? new Set()).add(code)); }
      const peer = other();
      if (peer) {
        clearTimeout(room.idle);
        send(peer, { type: 'peer', name: socket.deviceName });
        send(socket, { type: 'peer', name: peer.deviceName });
      } else {
        send(socket, { type: 'waiting' });
        armIdle(room);
      }
    }
    function scheduleCheck(grant) {
      clearTimeout(recheck);
      const delay = Math.max(1, Math.min(recheckMs, grant.validUntil - Date.now()));
      recheck = setTimeout(async () => {
        try {
          const current = await authorize(receipt);
          if (socket.readyState !== socket.OPEN) return;
          if (!current || current.owner !== owner || current.validUntil <= Date.now()) {
            socket.close(4002, 'subscription required'); return;
          }
          scheduleCheck(current);
        } catch { if (socket.readyState === socket.OPEN) socket.close(4011, 'subscription service unavailable'); }
      }, delay);
      recheck.unref();
    }
    async function admitHost(data) {
      pending = false;
      checking = true;
      let message = null;
      try { if (data.length <= 64 * 1024) message = JSON.parse(data.toString()); } catch {}
      let grant;
      try { grant = message?.type === 'entitlement' ? await authorize(message.jws) : null; }
      catch {
        clearTimeout(deadline);
        if (socket.readyState === socket.OPEN) socket.close(4011, 'subscription service unavailable');
        return;
      }
      clearTimeout(deadline);
      // The peer may have disconnected or timed out while Apple was responding.
      if (socket.readyState !== socket.OPEN) return;
      if (!grant || !grant.owner || !Number.isFinite(grant.validUntil) || grant.validUntil <= Date.now()) {
        socket.close(4002, 'subscription required'); return;
      }
      const refused = refusal();
      if (refused) { socket.close(...refused); return; }
      const id = grant.owner;
      // Reservations and admission stay synchronous after the await, so simultaneous
      // Apple responses cannot exceed capacity or enter a room for a different PDF.
      const codes = held.get(id);
      if (codes && !codes.has(code) && codes.size >= roomsPerSubscription) { socket.close(4002, 'subscription required'); return; }
      owner = id;
      receipt = message.jws;
      enter();
      scheduleCheck(grant);
    }
    if (!host) enter();

    socket.on('pong', () => { socket.alive = true; });
    socket.on('message', (data, isBinary) => {
      if (pending && !isBinary) { admitHost(data); return; }
      if (!room || !isBinary) return;  // devices only send binary sync messages
      const target = other();
      if (target && target.readyState === target.OPEN) target.send(data, { binary: true });
    });
    socket.on('close', () => {
      clearTimeout(deadline);
      clearTimeout(recheck);
      receipt = null;
      if (room) {
        room.sockets.delete(socket);
        if (owner && --room.hosts === 0) room.hostLeftAt = Date.now();
        const remaining = other();
        if (remaining) { send(remaining, { type: 'left' }); armIdle(room); }
        if (room.sockets.size === 0) {
          clearTimeout(room.idle);
          rooms.delete(code);
          for (const id of room.owners) { const codes = held.get(id); codes.delete(code); if (!codes.size) held.delete(id); }
        }
      }
      const count = (addresses.get(address) ?? 1) - 1;
      if (count > 0) addresses.set(address, count); else addresses.delete(address);
    });
    socket.on('error', () => socket.terminate());
  });

  // Phones that vanish (lost network, killed app) do not close their socket.
  const heartbeat = setInterval(() => {
    for (const socket of wss.clients) {
      if (!socket.alive) { socket.terminate(); continue; }
      socket.alive = false;
      socket.ping();
    }
  }, heartbeatMs);
  heartbeat.unref();
  server.on('close', () => { clearInterval(heartbeat); clearInterval(sweep); });

  return { server, wss, rooms, joins, held };
}

// Compare real paths: import.meta.url is percent-encoded (non-ASCII folders).
if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
  const port = Number(process.env.PORT ?? 3840);
  const host = process.env.HOST ?? '127.0.0.1';
  const requireEntitlement = process.env.REQUIRE_ENTITLEMENT === '1';
  const { server } = createRelay({ requireEntitlement });
  server.listen(port, host, () => console.log(`MusicFocus sync relay on ${host}:${port}${requireEntitlement ? ', rooms need a subscription' : ''}`));
}
