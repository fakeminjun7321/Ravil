interface Env {
  WORKSPACE_API: Fetcher;
}

// Keep authentication cookies and every workspace request on the existing site.
// The private service binding calls the Worker without redirecting the browser.
export const onRequest: PagesFunction<Env> = async ({request, env}) => {
  try {
    return await env.WORKSPACE_API.fetch(request);
  } catch {
    return Response.json({error:'연결을 마치지 못했습니다. 잠시 후 다시 시도해 주세요.'}, {
      status:503, headers:{'Cache-Control':'no-store'}
    });
  }
};
