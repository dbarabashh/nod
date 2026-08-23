do $contract$
declare
    v_record_config text[];
    v_attribution_config text[];
    v_report jsonb;
    v_campaign jsonb;
    v_totals jsonb;
begin
    select p.proconfig
      into v_record_config
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = 'record_acquisition_touch'
       and pg_get_function_identity_arguments(p.oid) = 'p_payload jsonb';

    select p.proconfig
      into v_attribution_config
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = 'founder_acquisition_attribution'
       and pg_get_function_identity_arguments(p.oid) = 'p_days integer';

    if v_record_config <> array['search_path=""'] then
        raise exception 'record acquisition search path changed: %', v_record_config;
    end if;
    if v_attribution_config <> array['search_path=public, auth'] then
        raise exception 'founder attribution search path changed: %', v_attribution_config;
    end if;
    if not has_function_privilege('anon', 'public.record_acquisition_touch(jsonb)', 'EXECUTE') then
        raise exception 'anon lost record acquisition access';
    end if;
    if has_function_privilege('authenticated', 'public.record_acquisition_touch(jsonb)', 'EXECUTE') then
        raise exception 'authenticated unexpectedly gained record acquisition access';
    end if;
    if not has_function_privilege('authenticated', 'public.founder_acquisition_attribution(integer)', 'EXECUTE') then
        raise exception 'authenticated lost founder attribution access';
    end if;
    if has_function_privilege('anon', 'public.founder_acquisition_attribution(integer)', 'EXECUTE') then
        raise exception 'anon unexpectedly gained founder attribution access';
    end if;

perform public.record_acquisition_touch(jsonb_build_object(
    'event_id', '61000000-0000-4000-8000-000000000001',
    'visitor_id', '62000000-0000-4000-8000-000000000001',
    'session_id', '63000000-0000-4000-8000-000000000001',
    'event', 'demo_booking_click',
    'page_path', '/talk-to-us',
    'page_group', 'talk-to-us',
    'placement', 'legacy-contract',
    'platform', 'macos',
    'outcome', 'booking_click',
    'consent', 'granted',
    'consent_version', 'web-v1'
));

perform public.record_acquisition_touch(jsonb_build_object(
    'event_id', '61000000-0000-4000-8000-000000000002',
    'visitor_id', '62000000-0000-4000-8000-000000000002',
    'session_id', '63000000-0000-4000-8000-000000000002',
    'event', 'demo_interest_click',
    'page_path', '/talk-to-us',
    'page_group', 'talk-to-us',
    'placement', 'current-contract',
    'platform', 'macos',
    'outcome', 'interest_click',
    'consent', 'granted',
    'consent_version', 'web-v1'
));

perform public.record_acquisition_touch(jsonb_build_object(
    'event_id', '61000000-0000-4000-8000-000000000003',
    'visitor_id', '62000000-0000-4000-8000-000000000003',
    'session_id', '63000000-0000-4000-8000-000000000003',
    'event', 'demo_booking_link_click',
    'page_path', '/talk-to-us',
    'page_group', 'talk-to-us',
    'placement', 'current-contract',
    'platform', 'macos',
    'outcome', 'booking_link_click',
    'consent', 'granted',
    'consent_version', 'web-v1'
));

perform public.record_acquisition_touch(jsonb_build_object(
    'event_id', '61000000-0000-4000-8000-000000000004',
    'visitor_id', '62000000-0000-4000-8000-000000000004',
    'session_id', '63000000-0000-4000-8000-000000000004',
    'event', 'contact_email_click',
    'page_path', '/talk-to-us',
    'page_group', 'talk-to-us',
    'placement', 'current-contract',
    'platform', 'macos',
    'outcome', 'email_click',
    'consent', 'granted',
    'consent_version', 'web-v1'
));

perform public.record_acquisition_touch(jsonb_build_object(
    'event_id', '61000000-0000-4000-8000-000000000005',
    'visitor_id', '62000000-0000-4000-8000-000000000005',
    'session_id', '63000000-0000-4000-8000-000000000005',
    'event', 'demo_booked',
    'page_path', '/booking-confirmed',
    'page_group', 'booking-confirmed',
    'placement', 'calendly-redirect',
    'platform', 'macos',
    'outcome', 'confirmation_redirect',
    'consent', 'granted',
    'consent_version', 'web-v1'
));

perform public.record_acquisition_touch(jsonb_build_object(
    'event_id', '61000000-0000-4000-8000-000000000006',
    'visitor_id', '62000000-0000-4000-8000-000000000006',
    'session_id', '63000000-0000-4000-8000-000000000006',
    'event', 'download_click',
    'page_path', '/pricing',
    'page_group', 'pricing',
    'placement', 'contract-download',
    'platform', 'macos',
    'outcome', 'download',
    'utm_campaign_id', 'nod108-contract',
    'consent', 'granted',
    'consent_version', 'web-v1'
));

perform public.record_acquisition_touch(jsonb_build_object(
    'event_id', '61000000-0000-4000-8000-000000000007',
    'visitor_id', '62000000-0000-4000-8000-000000000007',
    'session_id', '63000000-0000-4000-8000-000000000007',
    'event', 'invite_download',
    'page_path', '/invite',
    'page_group', 'invite',
    'placement', 'invite',
    'platform', 'macos',
    'outcome', 'download',
    'utm_campaign_id', 'nod108-contract',
    'consent', 'granted',
    'consent_version', 'web-v1'
));

perform public.record_acquisition_touch(jsonb_build_object(
    'event_id', '61000000-0000-4000-8000-000000000008',
    'visitor_id', '62000000-0000-4000-8000-000000000008',
    'session_id', '63000000-0000-4000-8000-000000000008',
    'event', 'download_click',
    'page_path', '/pricing',
    'page_group', 'pricing',
    'placement', 'contract-intent',
    'platform', 'other',
    'outcome', 'redirect_to_get_nod',
    'utm_campaign_id', 'nod108-contract',
    'consent', 'granted',
    'consent_version', 'web-v1'
));

perform public.record_acquisition_touch(jsonb_build_object(
    'event_id', '61000000-0000-4000-8000-000000000003',
    'visitor_id', '62000000-0000-4000-8000-000000000003',
    'session_id', '63000000-0000-4000-8000-000000000003',
    'event', 'demo_booking_link_click',
    'page_path', '/talk-to-us',
    'page_group', 'talk-to-us',
    'platform', 'macos',
    'outcome', 'booking_link_click',
    'consent', 'granted',
    'consent_version', 'web-v1'
));

    if (select count(*) from public.acquisition_touches where id between
        '61000000-0000-4000-8000-000000000001' and '61000000-0000-4000-8000-000000000008') <> 8 then
        raise exception 'event idempotency or accepted payload contract changed';
    end if;
    if not exists (
        select 1
          from public.acquisition_touches
         where id = '61000000-0000-4000-8000-000000000001'
           and event = 'demo_booking_click'
           and outcome = 'booking_click'
           and placement = 'legacy-contract'
    ) then
        raise exception 'legacy booking payload was not preserved';
    end if;

    begin
        perform public.record_acquisition_touch(jsonb_build_object(
            'visitor_id', '62000000-0000-4000-8000-000000000009',
            'session_id', '63000000-0000-4000-8000-000000000009',
            'event', 'invalid_event',
            'consent', 'granted'
        ));
        raise exception 'invalid event unexpectedly succeeded';
    exception when sqlstate '22023' then
        null;
    end;

    begin
        perform public.record_acquisition_touch(jsonb_build_object(
            'visitor_id', '62000000-0000-4000-8000-000000000010',
            'session_id', '63000000-0000-4000-8000-000000000010',
            'event', 'demo_booked',
            'outcome', 'verified_booking',
            'consent', 'granted'
        ));
        raise exception 'invalid outcome unexpectedly succeeded';
    exception when check_violation then
        null;
    end;

    perform set_config('request.jwt.claims', '{"email":"dmytro@hellonod.app"}', true);
    v_report := public.founder_acquisition_attribution(30);

    select value
      into v_campaign
      from jsonb_array_elements(v_report -> 'campaigns')
     where value ->> 'campaign_id' = 'nod108-contract';

    v_totals := v_report #> '{lead_funnel,totals}';

    if not v_report ?& array[
        'window_days', 'eligible_signups', 'attributed_signups', 'coverage_pct',
        'platforms', 'campaigns', 'generated_at', 'qualified_mac_downloads', 'lead_funnel'
    ] then
        raise exception 'founder attribution response fields are incomplete';
    end if;
    if (v_campaign ->> 'downloads')::integer <> 3 then
        raise exception 'download intent meaning changed: %', v_campaign;
    end if;
    if (v_campaign ->> 'qualified_mac_downloads')::integer <> 2 then
        raise exception 'qualified Mac download definition changed: %', v_campaign;
    end if;
    if (v_totals ->> 'booking_link_clicks')::integer
        <> (v_totals ->> 'legacy_booking_clicks')::integer
         + (v_totals ->> 'current_booking_link_clicks')::integer then
        raise exception 'combined booking click total does not match its diagnostic split';
    end if;
    if jsonb_array_length(v_report #> '{lead_funnel,daily}') <> 30 then
        raise exception 'daily lead funnel did not preserve the requested window';
    end if;

    delete from public.acquisition_touches
     where id between '61000000-0000-4000-8000-000000000001'
                  and '61000000-0000-4000-8000-000000000008';
end;
$contract$;
