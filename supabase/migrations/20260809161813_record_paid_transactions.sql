drop trigger if exists on_subscription_insert_paid_acquisition_conversion
    on public.subscriptions;
drop trigger if exists on_subscription_update_paid_acquisition_conversion
    on public.subscriptions;
drop function if exists public.enqueue_paid_conversion();

create or replace function public.enqueue_paid_transaction_conversion(
    p_user_id uuid,
    p_occurred_at timestamptz,
    p_value numeric,
    p_currency text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_touch_id uuid;
    v_ga_client_id text;
    v_rows integer;
begin
    if p_user_id is null
       or p_occurred_at is null
       or p_value is null
       or p_value <= 0
       or p_currency is null
       or upper(p_currency) !~ '^[A-Z]{3}$' then
        raise exception 'invalid paid conversion payload' using errcode = '22023';
    end if;

    select ua.last_touch_id, t.ga_client_id
      into v_touch_id, v_ga_client_id
      from public.user_acquisition ua
      join public.acquisition_touches t on t.id = ua.last_touch_id
     where ua.user_id = p_user_id
       and ua.coverage_status = 'attributed'
       and not exists (
           select 1
             from public.acquisition_consent_revocations r
            where r.visitor_id = t.visitor_id
       );

    if v_touch_id is null or v_ga_client_id is null then
        return false;
    end if;

    insert into public.google_conversion_outbox (
        user_id,
        event,
        occurred_at,
        touch_id,
        ga_client_id,
        value,
        currency
    ) values (
        p_user_id,
        'subscription_paid',
        p_occurred_at,
        v_touch_id,
        v_ga_client_id,
        p_value,
        upper(p_currency)
    )
    on conflict (user_id, event) do nothing;

    get diagnostics v_rows = row_count;
    return v_rows = 1;
end;
$$;

revoke all on function public.enqueue_paid_transaction_conversion(uuid, timestamptz, numeric, text)
    from public, anon, authenticated;
grant execute on function public.enqueue_paid_transaction_conversion(uuid, timestamptz, numeric, text)
    to service_role;
