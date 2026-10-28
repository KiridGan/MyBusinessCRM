// Публичная конфигурация браузера. Здесь НИКОГДА не должно быть secret/service_role.
// Supabase Dashboard → Project Settings → API Keys → Publishable key (sb_publishable_...).
// Пустой ключ сохраняет прежний локальный режим до завершения настройки.
window.CRM_CONFIG = Object.freeze({
  supabaseUrl: 'https://vrbbhmwwelfpgvvffsap.supabase.co',
  supabasePublishableKey: 'sb_publishable_B2CTgWYClNSBrJ4lMWio6A_kCp9OoZ3'
});
