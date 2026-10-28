// Keep workspace sessions on the canonical host even for routes handled by Pages Functions.
export const onRequest: PagesFunction = async ({request,next}) => {
  const url=new URL(request.url);
  if(url.hostname==='www.ravil.app'){
    url.protocol='https:';url.hostname='ravil.app';url.port='';
    return Response.redirect(url.toString(),308);
  }
  return next();
};
