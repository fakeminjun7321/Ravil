import {workspaceGate, privateWorkspace} from '../../src/auth/access';

interface Env { WORKSPACE_API: Fetcher; }

export const onRequest: PagesFunction<Env> = async context => {
  const denied = await workspaceGate(context.request, request => context.env.WORKSPACE_API.fetch(request));
  return denied || privateWorkspace(await context.next());
};
