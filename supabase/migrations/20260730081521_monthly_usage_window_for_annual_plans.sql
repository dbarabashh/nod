-- Meter hours per month on multi-month billing terms.
--
-- The resolver metered usage across the WHOLE stored billing period while
-- comparing it against `plans.limits->>'hours_per_month'`. For a monthly term
-- the two coincide, so this never showed. The first annual subscriber exposed
-- it: `current_period_end` is a year out, so `hours_used` accumulated for 12
-- months against a 15-hour cap — a Starter annual plan silently metered as
-- 15 hours per YEAR. The referral reward has the same shape, since
-- `deferRenewal` pushes a renewal months into the future.
--
-- The window is now the anniversary month inside the term: [term_start + n
-- months, term_start + n+1 months), clamped to the term end. A monthly term
-- resolves to n = 0 and the identical window it had before, so nothing changes
-- for monthly subscribers.
--
-- `renewal_date` keeps meaning the real end of the paid term (the client shows
-- it as "renews on"); the metering window it no longer equals is reported
-- separately as `usage_period_start` / `usage_period_end`.

create or replace function public.resolve_entitlement(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_sub          public.subscriptions%rowtype;
    v_plan         public.plans%rowtype;
    v_status       text;
    v_active       boolean;
    v_features     text[];
    v_limits       jsonb;
    v_term_start   timestamptz;
    v_period_start timestamptz;
    v_period_end   timestamptz;
    v_renewal      timestamptz;
    v_months       int;
    v_hours_used   numeric;
begin
    select * into v_sub from public.subscriptions where user_id = p_user_id;
    if not found then
        return jsonb_build_object(
            'plan', 'none', 'status', 'none',
            'price_id', null,
            'features', '[]'::jsonb,
            'limits', jsonb_build_object('hours_per_month', 0, 'devices', 0),
            'hours_used', 0, 'hours_limit', 0,
            'trial_ends_at', null, 'renewal_date', null,
            'usage_period_start', null, 'usage_period_end', null
        );
    end if;

    select * into v_plan from public.plans where plan = v_sub.plan;

    v_status := v_sub.status;
    if v_status = 'trialing'
       and v_sub.trial_ends_at is not null
       and now() > v_sub.trial_ends_at then
        v_status := 'expired';
    end if;
    v_active := v_status in ('trialing', 'active');

    if v_status = 'trialing' then
        v_period_start := v_sub.current_period_start;
        v_period_end   := coalesce(v_sub.trial_ends_at, now() + interval '100 years');
        v_renewal      := v_period_end;
    else
        v_term_start := coalesce(v_sub.current_period_start, date_trunc('month', now()));
        v_renewal    := coalesce(v_sub.current_period_end, v_term_start + interval '1 month');
        if now() >= v_renewal then
            v_period_start := date_trunc('month', now());
            v_period_end   := v_period_start + interval '1 month';
            v_renewal      := v_period_end;
        else
            v_months := greatest(0, extract(year  from age(now(), v_term_start))::int * 12
                                  + extract(month from age(now(), v_term_start))::int);
            -- A term starting on the 29th–31st lands short in February, where
            -- `age()` still reports the previous whole month for up to a day
            -- after that clamped anniversary has passed. Without this the
            -- window sits entirely in the past and meters nothing.
            if now() >= v_term_start + make_interval(months => v_months + 1) then
                v_months := v_months + 1;
            end if;
            v_period_start := v_term_start + make_interval(months => v_months);
            v_period_end   := least(v_term_start + make_interval(months => v_months + 1), v_renewal);
        end if;
    end if;

    v_features := coalesce(v_plan.features, '{}') || coalesce(v_sub.feature_overrides, '{}');
    v_limits   := coalesce(v_plan.limits, '{}'::jsonb) || coalesce(v_sub.limit_overrides, '{}'::jsonb);

    select coalesce(sum(audio_seconds), 0) / 3600.0 into v_hours_used
    from public.usage_events
    where user_id = p_user_id
      and kind = 'transcribe'
      and created_at >= v_period_start
      and created_at <  v_period_end;

    return jsonb_build_object(
        'plan', v_sub.plan,
        'status', v_status,
        'price_id', v_sub.paddle_price_id,
        'features', case when v_active
                         then to_jsonb((select array(select distinct unnest(v_features))))
                         else '[]'::jsonb end,
        'limits', v_limits,
        'hours_used', round(v_hours_used, 3),
        'hours_limit', case when v_active
                            then coalesce((v_limits->>'hours_per_month')::numeric, 0)
                            else 0 end,
        'trial_ends_at', v_sub.trial_ends_at,
        'renewal_date', v_renewal,
        'usage_period_start', v_period_start,
        'usage_period_end', v_period_end
    );
end;
$$;

revoke all on function public.resolve_entitlement(uuid) from public, anon, authenticated;
grant execute on function public.resolve_entitlement(uuid) to service_role;
