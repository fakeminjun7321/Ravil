import {test} from 'node:test';
import assert from 'node:assert/strict';
import {workspaceReturn, workspaceGate, privateWorkspace} from '../../website/src/auth/access.ts';

test('return paths remain inside the workspace', () => {
  assert.equal(workspaceReturn('/workspace/?view=plan#physics'),'/workspace/?view=plan#physics');
  for (const value of [null, '/login/', 'https://evil.test/workspace/', '//evil.test/workspace/', '\\evil.test', '/workspace/../../signup/'])
    assert.equal(workspaceReturn(value),'/workspace/');
});

test('workspace access requires a verified session and preserves its return path', async () => {
  const request = new Request('https://workspace-preview.ravil-website.pages.dev/workspace/?view=plan', {headers:{Cookie:'test-session=fixture','CF-Connecting-IP':'203.0.113.17','X-Forwarded-For':'spoofed-fixture'}});
  const denied = await workspaceGate(request, async forwarded => {
    assert.equal(new URL(forwarded.url).pathname, '/api/auth/get-session');
    assert.equal(forwarded.headers.get('Cookie'),'test-session=fixture');
    assert.equal(forwarded.headers.get('CF-Connecting-IP'),'203.0.113.17');
    assert.equal(forwarded.headers.get('X-Forwarded-For'),null);
    return Response.json(null);
  });
  assert.equal(denied?.status,303);
  assert.equal(denied?.headers.get('Location'),'/login/?next=%2Fworkspace%2F%3Fview%3Dplan');
  assert.equal(denied?.headers.get('Cache-Control'),'no-store');
  assert.equal(await workspaceGate(request, async () => Response.json({user:{id:'authenticated-fixture'}})),null);
  assert.equal((await workspaceGate(request, async () => {throw new Error('Unavailable');}))?.status,503);
});

test('protected workspace responses cannot become shared or offline HTML caches', () => {
  const response = privateWorkspace(new Response('workspace shell', {headers:{'Cache-Control':'public, max-age=3600'}}));
  assert.equal(response.headers.get('Cache-Control'),'private, no-store');
  assert.ok(response.headers.get('Vary')?.includes('Cookie'));
});
