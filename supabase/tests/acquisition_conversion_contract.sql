begin;

do $$
begin
    if has_function_privilege(
        'authenticated',
        'public.enqueue_paid_transaction_conversion(uuid,timestamptz,numeric,text)',
        'EXECUTE'
    ) then
        raise exception 'authenticated role unexpectedly has paid conversion access';
    end if;

    if not has_function_privilege(
        'service_role',
        'public.enqueue_paid_transaction_conversion(uuid,timestamptz,numeric,text)',
        'EXECUTE'
    ) then
        raise exception 'service role cannot enqueue paid conversions';
    end if;
end;
$$;

insert into auth.users (id, email, created_at, updated_at)
values (
    '10000000-0000-4000-8000-000000000010',
    'ads-contract@example.invalid',
    now(),
    now()
);

insert into public.acquisition_touches (
    id,
    visitor_id,
    session_id,
    event,
    page_path,
    page_group,
    ga_client_id,
    consent_version
) values (
    '20000000-0000-4000-8000-000000000010',
    '30000000-0000-4000-8000-000000000010',
    '40000000-0000-4000-8000-000000000010',
    'page_view',
    '/',
    'home',
    '1234567890.1234567890',
    'web-v1'
);

insert into public.user_acquisition (
    user_id,
    first_touch_id,
    last_touch_id,
    coverage_status
) values (
    '10000000-0000-4000-8000-000000000010',
    '20000000-0000-4000-8000-000000000010',
    '20000000-0000-4000-8000-000000000010',
    'attributed'
);

do $$
begin
    if not public.enqueue_paid_transaction_conversion(
        '10000000-0000-4000-8000-000000000010',
        now(),
        188.00,
        'eur'
    ) then
        raise exception 'expected confirmed transaction conversion to be accepted';
    end if;

    if not exists (
        select 1
          from public.google_conversion_outbox
         where user_id = '10000000-0000-4000-8000-000000000010'
           and event = 'subscription_paid'
           and value = 188.00
           and currency = 'EUR'
           and ga_client_id = '1234567890.1234567890'
    ) then
        raise exception 'paid conversion value or attribution was not persisted';
    end if;

    if public.enqueue_paid_transaction_conversion(
        '10000000-0000-4000-8000-000000000010',
        now(),
        200.00,
        'EUR'
    ) then
        raise exception 'later transaction unexpectedly replaced first paid conversion';
    end if;

    if not exists (
        select 1
          from public.google_conversion_outbox
         where user_id = '10000000-0000-4000-8000-000000000010'
           and event = 'subscription_paid'
           and value = 188.00
    ) then
        raise exception 'first paid conversion value was not preserved';
    end if;

    update public.google_conversion_outbox
       set status = 'sent', sent_at = now()
     where user_id = '10000000-0000-4000-8000-000000000010'
       and event = 'subscription_paid';

    if public.enqueue_paid_transaction_conversion(
        '10000000-0000-4000-8000-000000000010',
        now(),
        200.00,
        'EUR'
    ) then
        raise exception 'sent paid conversion was unexpectedly replaced';
    end if;
end;
$$;

insert into public.acquisition_consent_revocations (visitor_id)
values ('30000000-0000-4000-8000-000000000010');

delete from public.google_conversion_outbox
where user_id = '10000000-0000-4000-8000-000000000010';

do $$
begin
    if public.enqueue_paid_transaction_conversion(
        '10000000-0000-4000-8000-000000000010',
        now(),
        188.00,
        'EUR'
    ) then
        raise exception 'revoked acquisition consent unexpectedly produced a conversion';
    end if;
end;
$$;

rollback;
