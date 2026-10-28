import { betterAuth } from 'better-auth';
import { bearer } from 'better-auth/plugins';
import { authRateLimit } from './auth-policy.ts';

export function authFor(env: {DB: D1Database; AUTH_SECRET: string; APP_ORIGIN: string}, origin = env.APP_ORIGIN) {
  return betterAuth({
    database: env.DB, secret: env.AUTH_SECRET, baseURL: origin,
    trustedOrigins: [origin],
    advanced: {ipAddress: {ipAddressHeaders:['cf-connecting-ip']}},
    emailAndPassword: {enabled: true, minPasswordLength: 12},
    session: {expiresIn: 60 * 60 * 24 * 14, updateAge: 60 * 60 * 24},
    plugins: [bearer()],
    rateLimit: authRateLimit,
  });
}
