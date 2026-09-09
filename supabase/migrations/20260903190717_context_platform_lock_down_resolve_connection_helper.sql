revoke all on function public._resolve_active_connection_id(uuid, text) from public, anon, authenticated;
grant execute on function public._resolve_active_connection_id(uuid, text) to service_role;
