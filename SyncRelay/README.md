# MusicFocus sync relay

Pairs two devices by a six-digit room number and forwards their score-sync
messages (markings, page and zoom, metronome settings) between them. It keeps room/entitlement state only in memory and logs no score or receipt content. Audio and video stay in the teachers' own call app.

```sh
npm install
npm test
PORT=3840 npm start          # listens on 127.0.0.1 by default
```

Protocol: a device opens `/v1/rooms/<6 digits>?name=<device name>&file=<16 hex>`,
where `file` is the first 16 hex characters of the score PDF's SHA-256. The relay
sends text frames `waiting`, `peer` and `left`, and forwards binary frames only.
It closes a socket with:

- 4003: the room's first device has a different `file` (that device is not told)
- 4004: bad path, or `file` missing or not 16 lowercase hex characters
- 4008: alone in the room for 15 minutes (restarts when a peer leaves)
- 4009: the room already has two devices
- 4029: more than 30 joins a minute from one address (the address is then refused
  for 5 minutes), more than 20 open connections from it, or the relay is full

The limits are `createRelay` options. Clients stop retrying on all of these codes
and on 4002; they retry later on 4010 and 4011 (see below).

### Subscription rooms (`REQUIRE_ENTITLEMENT=1`)

With `REQUIRE_ENTITLEMENT=1` (option `requireEntitlement`) only a subscriber can open
a room; the device that joins needs no subscription. Without it the relay behaves as
above and ignores `host=1` and `entitlement` frames.

- The opening device adds `&host=1` and sends, as its first frame and within 10 s,
  the text frame `{"type":"entitlement","jws":"<StoreKit 2 signed transaction>"}`.
  Until that verifies it is not in the room: it gets no `waiting`/`peer`, its binary
  frames are dropped, and nobody else sees the room. Then it enters like any device
  (and pairs with a joiner already waiting there). Both devices may be hosts.
- A device without `host=1` can only join a room while a verified host is in it, or
  within 2 minutes (`hostGraceMs`) after the last one left; otherwise it is closed
  with 4010 and retries later. A host leaving does not close the room for a joiner
  already in it (the 15-minute idle expiry still applies), and a returning host pairs
  with that joiner.
- 4002 (subscription required): no valid entitlement in time, or the subscription
  (`originalTransactionId`) already holds 3 rooms. A room counts until it is empty.
- 4010 (room not open): see above. The client retries on 4010.

- 4011 (subscription verification unavailable): Apple timed out, returned a service error,
  or the relay's App Store credentials are missing. The client backs off and retries the
  same room; it must not ask the customer to buy again.

Apple's official Node library verifies the device transaction signature and looks up
its original transaction ID using **Get All Subscription Statuses**. The receipt alone
never grants a room: the API's latest status and signed transaction must still authorize
the same subscription, environment, app and room product. Refunded/revoked, expired,
upgraded or billing-retry subscriptions without grace are refused, even if the device
replays a valid receipt issued before the refund. No positive entitlement cache is used.

For billing grace, both the current transaction and signed renewal information are
verified, including matching product/subscription/environment. Access lasts until the
signed `gracePeriodExpiresDate`; the old transaction's `expiresDate` does not end grace.
While hosting, the relay checks again every five minutes (`recheckMs`), or at the access
deadline if earlier. Refund detection for a room already open therefore takes up to five
minutes plus the API timeout; new connections always query current status.

Receipt certificates are evaluated at `signedDate`, so a yearly receipt can outlive its
signing certificate. Live status queries provide subscription freshness. The pinned trust
anchor is Apple Root CA - G3. Production and Sandbox (TestFlight/App Review) are accepted
by default and tracked separately; Xcode/LocalTesting receipts are always refused.
An Apple API request has a seven-second timeout. Initial admission also has a ten-second
limit; results arriving after timeout/disconnect cannot create a room or reserve a slot.

The paid relay requires these **server-only** settings before it can grant access:

| Setting | Value |
| --- | --- |
| `REQUIRE_ENTITLEMENT` | `1` on the international node only |
| `APP_STORE_KEY_FILE` | Service-readable path to the In-App Purchase API `.p8` private key |
| `APP_STORE_KEY_ID` | The key ID from App Store Connect |
| `APP_STORE_ISSUER_ID` | The issuer ID from App Store Connect |
| `APP_STORE_APP_ID` | The app's numeric Apple ID |
| `APP_STORE_ALLOW_SANDBOX` | Optional; `0` disables Sandbox access |

Keep the private key outside the source tree, App bundle and public web directory; deliver
it through the server's secret/credential mechanism. Never place key contents in logs or
commit them. Missing credentials fail closed with 4011, with no offline fallback. The
mainland/free relay needs no Apple API credentials and makes no entitlement queries.

Tests use generated certificates and scripted Apple responses. They cover refunds,
renewal/grace expiry, API failure, late responses, concurrent admission, live revalidation,
and reopening the same room. They do **not** replace a real App Store sandbox purchase
against a correctly configured server. All internet/paid UI remains disabled in Release;
none of this enables the feature in the currently published local app.

References: [Apple's server library](https://github.com/apple/app-store-server-library-node),
[subscription statuses](https://developer.apple.com/documentation/appstoreserverapi/get-all-subscription-statuses),
[grace deadline](https://developer.apple.com/documentation/appstoreserverapi/graceperiodexpiresdate).

Deploy (e.g. the Contabo server):

1. Copy `relay.mjs`, `app-store-subscriptions.mjs`, `package.json`, `package-lock.json` to `/srv/musicfocus-sync-relay`, run `npm ci --omit=dev` there.
2. Install `musicfocus-sync-relay.service` in `/etc/systemd/system`, then `systemctl enable --now musicfocus-sync-relay`.
3. Add `nginx-location.conf` to the site's HTTPS server block, `nginx -t && systemctl reload nginx`.
4. Check: `curl https://712art.com/mfsync/health` → `ok`. Cloudflare passes WebSockets through.

The development client's default relay follows the App Store storefront, not the
language or device locale. Mainland China (`CHN`) uses `wss://feuxfollets.top/mfsync`;
other storefronts use `wss://712art.com/mfsync`. Invitation links carry their node and
reconnects keep it. Mainland clients cannot join an international room. Joining is free;
only an international host needs a subscription. Purchase, restore and Ask to Buy approval
resume a pending host with the same code, file and node; leaving cancels that intent.

Use the same server files for both relays. Each relay has its own six-digit rooms.
Only the international relay (712art.com) requires a subscription: add
`REQUIRE_ENTITLEMENT=1` to its service's `Environment=` line, e.g.
`Environment=HOST=127.0.0.1 PORT=3840 REQUIRE_ENTITLEMENT=1`, configure the App Store
settings above, and restart it. A successful health check alone does not prove paid
authorization is configured.
The China mainland relay (feuxfollets.top) does not set it and stays free.
