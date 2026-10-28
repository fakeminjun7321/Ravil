export interface SiteOrigins {
  APP_ORIGIN: string;
  APP_ORIGINS?: string;
}

// Only URLs configured by the deployment may become an authentication origin.
// Forwarded host headers and arbitrary Pages subdomains are never trusted.
export function siteOrigin(request: Request, env: SiteOrigins): string | null {
  const origin = new URL(request.url).origin;
  const allowed = [env.APP_ORIGIN, ...(env.APP_ORIGINS || '').split(',')].map(s => s.trim()).filter(Boolean);
  return allowed.includes(origin) ? origin : null;
}
