-- The settings check reads private.secrets (is a SeevPlus key saved before
-- SeevPlus is switched on?). It ran with the admin's own rights, which have no
-- access to the private schema, so "Turn On" failed with "permission denied
-- for schema private". Run it with the owner's rights instead. Who may change
-- settings is still decided by the row-level security on app_settings.
-- (Applied live on 5 Nov 2026.)
alter function public.check_app_setting() security definer;
