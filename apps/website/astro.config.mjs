import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://ravil.app',
  output: 'static',
  trailingSlash: 'always',
  devToolbar: { enabled: false }
});
