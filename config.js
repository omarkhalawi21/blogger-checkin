// ── Fill these in from your Supabase project ──────────────────────────────
// Supabase dashboard → Project Settings → Data API (and → API Keys)
//   • URL:  Project URL              e.g. https://abcdxyz.supabase.co
//   • KEY:  the "anon / publishable" key (NOT the service_role key)
// The anon key is safe to ship publicly *because* the tables have RLS and the
// public page can only call the blogger_checkin() function.
window.BLOGGER_CFG = {
  SUPABASE_URL: 'https://YOUR-PROJECT.supabase.co',
  SUPABASE_ANON_KEY: 'YOUR-ANON-PUBLISHABLE-KEY',
  BRAND_NAME: 'Hassad Coffee Roasters',
};
