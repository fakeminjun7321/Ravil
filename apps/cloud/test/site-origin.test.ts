import assert from 'node:assert/strict';
import {test} from 'node:test';
import {siteOrigin} from '../src/site-origin.ts';

test('the introduction site and its exact preview use their own authentication origin', () => {
  const env = {APP_ORIGIN:'https://api.example.test', APP_ORIGINS:'https://ravil-website.pages.dev,https://workspace-preview.ravil-website.pages.dev,https://ravil.app,https://www.ravil.app'};
  for (const origin of [env.APP_ORIGIN, ...env.APP_ORIGINS.split(',')]) {
    assert.equal(siteOrigin(new Request(origin+'/api/auth/sign-in/email'), env), origin);
  }
  for (const origin of ['https://evil.example.test', 'https://ravil-website.pages.dev.evil.test', 'http://ravil-website.pages.dev', 'https://old.ravil-website.pages.dev','https://ravil.app.evil.test','http://ravil.app','https://unapproved.ravil.app']) {
    assert.equal(siteOrigin(new Request(origin+'/api/auth/sign-in/email'), env), null);
  }
  assert.equal(siteOrigin(new Request('https://evil.example.test/api/auth/sign-in/email', {headers:{'X-Forwarded-Host':'ravil-website.pages.dev'}}), env), null);
});
