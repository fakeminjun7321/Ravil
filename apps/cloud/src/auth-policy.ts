// Session reads occur at the site entry, server gate and workspace startup.
// Keep those reads separate from password-attempt throttling.
export const authRateLimit = {
  enabled:true, storage:'database' as const, window:60, max:20,
  customRules:{'/get-session':{window:60, max:120}}
};
