export function workspaceReturn(value: string | null): string {
  if (!value || value.includes('\\')) return '/workspace/';
  try {
    const url = new URL(value, 'https://ravil.invalid');
    if (url.origin === 'https://ravil.invalid' && (url.pathname === '/workspace' || url.pathname.startsWith('/workspace/')))
      return url.pathname + url.search + url.hash;
  } catch { /* Invalid return paths use the workspace home. */ }
  return '/workspace/';
}

export async function workspaceGate(request: Request, getSession: (request: Request) => Promise<Response>): Promise<Response | null> {
  try {
    const headers = new Headers();
    for (const key of ['Cookie', 'Authorization', 'CF-Connecting-IP']) {
      const value = request.headers.get(key);
      if (value) headers.set(key, value);
    }
    const session = await getSession(new Request(new URL('/api/auth/get-session', request.url), {headers}));
    if (!session.ok) throw new Error('Session unavailable');
    const value = await session.json() as {user?: {id?: string}} | null;
    if (typeof value?.user?.id === 'string' && value.user.id) return null;
    const url = new URL(request.url);
    const next = workspaceReturn(url.pathname + url.search);
    return new Response(null, {status:303, headers:{Location:'/login/?next='+encodeURIComponent(next), 'Cache-Control':'no-store'}});
  } catch {
    return new Response('<!doctype html><html lang="ko"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>로그인 확인 · RAVIL</title><body><p>로그인을 확인하려면 연결이 필요해요. 잠시 후 다시 시도해 주세요.</p><a href="/login/">로그인 화면으로</a></body></html>', {status:503, headers:{'Content-Type':'text/html; charset=utf-8', 'Cache-Control':'no-store'}});
  }
}

export function privateWorkspace(response: Response): Response {
  const headers = new Headers(response.headers);
  headers.set('Cache-Control', 'private, no-store');
  headers.append('Vary', 'Cookie');
  return new Response(response.body, {status:response.status, statusText:response.statusText, headers});
}
