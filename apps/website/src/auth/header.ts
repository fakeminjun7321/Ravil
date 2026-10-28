const entries = document.querySelectorAll<HTMLAnchorElement>('[data-auth-entry]');
if (entries.length && !document.querySelector('#auth-form')) void fetch('/api/auth/get-session', {credentials:'include', cache:'no-store'})
  .then(response => response.ok ? response.json() : null)
  .then(value => { if (value?.user) entries.forEach(link => { link.href = '/workspace/'; link.textContent = '내 작업'; }); })
  .catch(() => {});
if ('serviceWorker' in navigator) void navigator.serviceWorker.getRegistration('/workspace/').then(registration => registration?.update()).catch(() => {});
