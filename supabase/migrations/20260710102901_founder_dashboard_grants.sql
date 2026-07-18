
do $$
declare fn text;
begin
  foreach fn in array array[
    'founder_metrics()', 'founder_users()', 'founder_signups_daily(int)',
    'founder_activity_daily(int)', 'founder_active_users_daily(int)',
    'founder_plan_breakdown()', 'founder_usage_breakdown()',
    'founder_model_breakdown()', 'founder_app_versions()',
    'founder_acquisition()', 'founder_activation()', 'founder_activation_funnel()',
    'founder_engagement()', 'founder_retention_cohorts(int)', 'founder_monetization()',
    'founder_user_notes_view()'
  ] loop
    execute format('revoke all on function public.%s from public, anon;', fn);
    execute format('grant execute on function public.%s to authenticated;', fn);
  end loop;
end $$;
