// The device's signed receipt proves which subscription to query; it never grants
// access on its own. Every authorization consults Apple's current subscription status.
import { readFileSync } from 'node:fs';
import { X509Certificate } from 'node:crypto';
import { AppStoreServerAPIClient, Environment, SignedDataVerifier, Status } from '@apple/app-store-server-library';

export const BUNDLE_ID = 'com.FeuxFollets.MusicFocus';
export const ROOM_PRODUCT_ID = 'com.FeuxFollets.MusicFocus.rooms.yearly';
// Public Apple Root CA - G3, pinned SHA-256:
// 63343ABFB89A6A03EBB57E9B3F5FA7BE7C4F5C756F3017B3A8C488C3653E9179
const APPLE_ROOT_CA_G3 = `-----BEGIN CERTIFICATE-----
MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwS
QXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9u
IEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcN
MTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBS
b290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9y
aXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49
AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtf
TjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517
IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySr
MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gA
MGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4
at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM
6BgD56KyKA==
-----END CERTIFICATE-----`;

export class SubscriptionServiceUnavailable extends Error {
  constructor() { super('Subscription verification temporarily unavailable'); }
}

function recentEnough(payload) {
  return Number.isFinite(payload.signedDate) && payload.signedDate <= Date.now() + 5 * 60_000;
}

export function createReceiptVerifier({
  trustedRoots = [APPLE_ROOT_CA_G3], bundleId = BUNDLE_ID, appAppleId = 0,
  productIds = [ROOM_PRODUCT_ID], allowSandbox = true,
} = {}) {
  const roots = trustedRoots.map((pem) => new X509Certificate(pem).raw);
  // Evaluate certificate validity at signedDate, so annual receipts remain usable
  // after their signing leaf expires. Subscription freshness is checked by the API.
  const verifiers = new Map([Environment.PRODUCTION, ...(allowSandbox ? [Environment.SANDBOX] : [])]
    .map((environment) => [environment, new SignedDataVerifier(roots, false, environment, bundleId, appAppleId)]));
  return {
    async transaction(jws) {
      try {
        if (typeof jws !== 'string' || jws.length > 64 * 1024) return null;
        // Untrusted data selects a verifier only. Apple signature/environment/bundle
        // checks below are mandatory. Xcode/LocalTesting are never accepted by a relay.
        const hint = JSON.parse(Buffer.from(jws.split('.')[1], 'base64url'));
        const verifier = verifiers.get(hint.environment);
        if (!verifier) return null;
        const t = await verifier.verifyAndDecodeTransaction(jws);
        if (!recentEnough(t) || !productIds.includes(t.productId) || t.type !== 'Auto-Renewable Subscription'
            || typeof t.originalTransactionId !== 'string' || !t.originalTransactionId) return null;
        return t;
      } catch { return null; }
    },
    async renewal(jws, environment) {
      try {
        if (typeof jws !== 'string' || jws.length > 64 * 1024) return null;
        const r = await verifiers.get(environment)?.verifyAndDecodeRenewalInfo(jws);
        return r && recentEnough(r) ? r : null;
      } catch { return null; }
    },
  };
}

export function createSubscriptionAuthorizer({ getStatuses, ...options }) {
  const verifier = createReceiptVerifier(options);
  const bundleId = options.bundleId ?? BUNDLE_ID;
  return async (jws) => {
    const submitted = await verifier.transaction(jws);
    if (!submitted) return null;
    // Even an expired receipt can locate a renewed/grace-period subscription.
    // Refunds are decided from this live response, never a cached device receipt.
    let response;
    try {
      response = await getStatuses(submitted.originalTransactionId, submitted.environment);
    } catch (error) {
      if (error?.apiError === 4040005 || error?.apiError === 4040010) return null;
      throw new SubscriptionServiceUnavailable();
    }
    if (!response || response.bundleId !== bundleId || response.environment !== submitted.environment
        || !Array.isArray(response.data)) throw new SubscriptionServiceUnavailable();
    for (const group of response.data) {
      for (const item of group.lastTransactions ?? []) {
        if (item.originalTransactionId !== submitted.originalTransactionId) continue;
        if (item.status !== Status.ACTIVE && item.status !== Status.BILLING_GRACE_PERIOD) continue;
        const t = await verifier.transaction(item.signedTransactionInfo);
        if (!t || t.originalTransactionId !== submitted.originalTransactionId
            || t.environment !== submitted.environment || t.revocationDate != null || t.isUpgraded) continue;
        let validUntil = t.expiresDate;
        if (item.status === Status.BILLING_GRACE_PERIOD) {
          const renewal = await verifier.renewal(item.signedRenewalInfo, submitted.environment);
          if (!renewal || renewal.originalTransactionId !== t.originalTransactionId || renewal.productId !== t.productId) continue;
          validUntil = renewal.gracePeriodExpiresDate;
        }
        if (Number.isFinite(validUntil) && validUntil > Date.now()) {
          return { owner: t.environment + ':' + t.originalTransactionId, validUntil };
        }
      }
    }
    return null;
  };
}

// Native fetch aborts both headers and response-body reads. The Apple library still
// signs requests, selects the environment and validates response shapes.
export class BoundedAppStoreClient extends AppStoreServerAPIClient {
  async makeFetchRequest(path, query, method, body, headers) {
    return fetch(this.urlBase + path + '?' + query, {
      method, body, headers, signal: AbortSignal.timeout(7_000),
    });
  }
}

export function createAppStoreAuthorizerFromEnvironment(env = process.env) {
  try {
    const appAppleId = Number(env.APP_STORE_APP_ID);
    if (!env.APP_STORE_KEY_FILE || !env.APP_STORE_KEY_ID || !env.APP_STORE_ISSUER_ID
        || !Number.isSafeInteger(appAppleId) || appAppleId <= 0) throw new Error('Not configured');
    const key = readFileSync(env.APP_STORE_KEY_FILE, 'utf8');
    const clients = new Map([Environment.PRODUCTION, Environment.SANDBOX].map((environment) => [environment,
      new BoundedAppStoreClient(key, env.APP_STORE_KEY_ID, env.APP_STORE_ISSUER_ID, BUNDLE_ID, environment)]));
    return createSubscriptionAuthorizer({
      appAppleId, allowSandbox: env.APP_STORE_ALLOW_SANDBOX !== '0',
      getStatuses: (id, environment) => clients.get(environment).getAllSubscriptionStatuses(id),
    });
  } catch {
    // Missing configuration is a service problem, never proof the customer must buy.
    return async () => { throw new SubscriptionServiceUnavailable(); };
  }
}
