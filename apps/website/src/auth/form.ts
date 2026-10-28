import {workspaceReturn} from './access';

const form = document.querySelector<HTMLFormElement>('#auth-form')!;
const submit = form.querySelector<HTMLButtonElement>('button[type="submit"]')!;
const error = document.querySelector<HTMLParagraphElement>('#auth-error')!;
const signup = form.dataset.signup === 'true';
const next = workspaceReturn(new URLSearchParams(location.search).get('next'));
document.querySelector<HTMLAnchorElement>('#auth-switch')!.href = (signup ? '/login/' : '/signup/') + '?next=' + encodeURIComponent(next);
const messages: Record<string,string> = {
  INVALID_EMAIL_OR_PASSWORD:'이메일과 비밀번호를 다시 확인해 주세요.',
  USER_ALREADY_EXISTS:'이미 등록된 이메일이에요. 로그인 화면에서 이어가세요.',
  USER_ALREADY_EXISTS_USE_ANOTHER_EMAIL:'이미 등록된 이메일이에요. 로그인 화면에서 이어가세요.',
  PASSWORD_TOO_SHORT:'비밀번호는 12자 이상으로 설정해 주세요.',
  INVALID_EMAIL:'이메일 주소를 확인해 주세요.'
};
form.addEventListener('submit', async event => {
  event.preventDefault();
  if (submit.disabled) return;
  submit.disabled = true;
  submit.textContent = signup ? '계정을 만드는 중…' : '로그인 중…';
  error.hidden = true;
  try {
    const data = new FormData(form);
    const response = await fetch('/api/auth/' + (signup ? 'sign-up/email' : 'sign-in/email'), {
      method:'POST', credentials:'include', headers:{'Content-Type':'application/json'},
      body:JSON.stringify({email:String(data.get('email')).trim(), password:String(data.get('password')), ...(signup ? {name:String(data.get('name')).trim()} : {})})
    });
    const value = await response.json();
    if (!response.ok || !value.user) throw new Error(messages[value.code] || (response.status === 429 ? '잠시 후 다시 시도해 주세요.' : '로그인 정보를 확인하고 다시 시도해 주세요.'));
    location.replace(next);
  } catch (failure) {
    error.textContent = failure instanceof TypeError ? '연결을 확인하고 다시 시도해 주세요.' : (failure as Error).message;
    error.hidden = false;
    submit.disabled = false;
    submit.textContent = signup ? '계정 만들기' : '로그인';
  }
});
// Existing sessions continue without asking for credentials again.
void fetch('/api/auth/get-session', {credentials:'include', cache:'no-store'}).then(r => r.ok ? r.json() : null).then(value => {
  if (value?.user && !submit.disabled) location.replace(next);
}).catch(() => {});
