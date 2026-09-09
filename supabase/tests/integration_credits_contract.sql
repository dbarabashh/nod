begin;

-- Integration credits: who may buy a pack, whose pool it lands in, what a
-- refund gives back, and that the pool is a pool — spent by the workspace's
-- stamped rows and seen the same by every member and by the Billing page.

insert into auth.users (id, email, created_at, updated_at)
values
    ('80000000-0000-4000-8000-000000000001', 'credits-owner@example.invalid', now(), now()),
    ('80000000-0000-4000-8000-000000000002', 'credits-member@example.invalid', now(), now()),
    ('80000000-0000-4000-8000-000000000003', 'credits-solo@example.invalid', now(), now());

insert into public.organizations (id, name, slug, created_by)
values ('81000000-0000-4000-8000-000000000001', 'Credits Co', 'credits-co',
        '80000000-0000-4000-8000-000000000001');

insert into public.org_members (org_id, user_id, role, status)
values
    ('81000000-0000-4000-8000-000000000001', '80000000-0000-4000-8000-000000000001', 'owner', 'active'),
    ('81000000-0000-4000-8000-000000000001', '80000000-0000-4000-8000-000000000002', 'member', 'active');

update public.profiles
   set active_org_id = '81000000-0000-4000-8000-000000000001'
 where user_id in ('80000000-0000-4000-8000-000000000001', '80000000-0000-4000-8000-000000000002');

insert into public.org_subscriptions (
    org_id, plan, status, seats, current_period_start, current_period_end,
    paddle_customer_id, paddle_subscription_id, paddle_price_id, purchased_by
) values (
    '81000000-0000-4000-8000-000000000001', 'teams', 'active', 3,
    now() - interval '3 days', now() + interval '27 days',
    'ctm_credits', 'sub_credits_teams', null, '80000000-0000-4000-8000-000000000001'
);

-- The solo person pays for Pro themselves.
update public.subscriptions
   set plan = 'pro', status = 'active', paddle_subscription_id = 'sub_credits_pro',
       current_period_start = now() - interval '3 days', current_period_end = now() + interval '27 days'
 where user_id = '80000000-0000-4000-8000-000000000003';

-- Packs are dark until a real Paddle price exists; the test stands one up.
update public.plan_prices
   set paddle_price_id = 'pri_test_pack_teams', available_for_new_checkout = true
 where sku = 'teams_automation_1000_usd_10';
update public.plan_prices
   set paddle_price_id = 'pri_test_pack_pro', available_for_new_checkout = true
 where sku = 'automation_1000_usd_10';

do $$
declare
    v_owner uuid := '80000000-0000-4000-8000-000000000001';
    v_member uuid := '80000000-0000-4000-8000-000000000002';
    v_solo uuid := '80000000-0000-4000-8000-000000000003';
    v_org uuid := '81000000-0000-4000-8000-000000000001';
    v_intent jsonb;
    v_result jsonb;
    v_ent jsonb;
begin
    if has_function_privilege('authenticated', 'public.create_topup_checkout_intent(uuid, text)', 'execute')
       or has_function_privilege('authenticated', 'public.apply_topup_purchase(uuid, text, text, uuid)', 'execute')
       or has_function_privilege('authenticated', 'public.refund_topup_transaction(text, text)', 'execute')
       or has_function_privilege('authenticated', 'public.resolve_entitlement(uuid)', 'execute')
    then
        raise exception 'a client can mint, fulfil or refund a pack, or read another person''s entitlement';
    end if;

    -- The pool is seats × the plan's allowance, and every member sees it.
    v_ent := public.resolve_entitlement(v_member);
    if v_ent->>'payer' <> 'organization'
       or (v_ent->>'integration_credits_included')::numeric <> 1500
       or (v_ent->>'can_run_integration_action')::boolean is not true then
        raise exception 'a covered member does not see the workspace pool: %', v_ent;
    end if;

    -- A member cannot spend the workspace's money.
    v_intent := public.create_topup_checkout_intent(v_member, 'teams_automation_1000_usd_10');
    if (v_intent->>'created')::boolean or v_intent->>'error' <> 'topup_not_eligible' then
        raise exception 'a member minted a workspace pack: %', v_intent;
    end if;

    -- A personal plan cannot buy another plan's pack, and vice versa.
    v_intent := public.create_topup_checkout_intent(v_solo, 'teams_automation_1000_usd_10');
    if (v_intent->>'created')::boolean then
        raise exception 'a personal Pro subscriber minted a Teams pack: %', v_intent;
    end if;
    v_intent := public.create_topup_checkout_intent(v_owner, 'automation_1000_usd_10');
    if (v_intent->>'created')::boolean then
        raise exception 'a workspace owner minted a personal Pro pack: %', v_intent;
    end if;

    -- The owner buys for the workspace; the pack is the workspace's.
    v_intent := public.create_topup_checkout_intent(v_owner, 'teams_automation_1000_usd_10');
    if (v_intent->>'created')::boolean is not true
       or (v_intent->>'org_id')::uuid is distinct from v_org
       or v_intent->>'plan' <> 'teams' then
        raise exception 'the owner could not mint a workspace pack: %', v_intent;
    end if;
    perform public.attach_topup_checkout_transaction((v_intent->>'intent_id')::uuid, 'txn_credits_1');

    -- Between checkout and Paddle's webhook the buyer wandered off to another
    -- workspace. The workspace's window has not moved, so the pack still lands.
    update public.profiles set active_org_id = null where user_id = v_owner;
    v_result := public.apply_topup_purchase(v_owner, 'txn_credits_1', 'pri_test_pack_teams', (v_intent->>'intent_id')::uuid);
    update public.profiles set active_org_id = v_org where user_id = v_owner;
    if (v_result->>'applied')::boolean is not true or (v_result->>'credits')::numeric <> 1000 then
        raise exception 'the workspace pack was not applied: %', v_result;
    end if;
    if not exists (select 1 from public.usage_topups where paddle_transaction_id = 'txn_credits_1' and org_id = v_org and credits = 1000) then
        raise exception 'the pack was not stamped as the workspace''s';
    end if;

    v_ent := public.resolve_entitlement(v_member);
    if (v_ent->>'integration_credits_included')::numeric <> 2500 then
        raise exception 'a member does not see the bought credits: %', v_ent;
    end if;
    v_ent := public.resolve_entitlement(v_solo);
    if (v_ent->>'integration_credits_included')::numeric <> 500 then
        raise exception 'a stranger''s pool moved: %', v_ent;
    end if;

    -- The pool is spent by stamped rows, whoever in the workspace made them.
    insert into public.usage_events (user_id, kind, model, status, cost_usd, task, org_id)
    select v_member, 'integration', 'linear.search_issues', 200, 0.012, 'ask', v_org
      from generate_series(1, 1600);
    v_ent := public.resolve_entitlement(v_owner);
    if (v_ent->>'integration_credits_used')::numeric <> 1600
       or (v_ent->>'integration_credits_remaining')::numeric <> 900 then
        raise exception 'the workspace pool did not count a member''s reads: %', v_ent;
    end if;

    -- 1,600 spent against 1,500 included: the pack is 100 credits in, so a
    -- refund is a question for a person, not an automatic yes.
    v_result := public.refund_topup_transaction('txn_credits_1', 'test');
    if v_result->>'action' <> 'review_required'
       or (v_result->>'consumed')::numeric <> 100
       or v_result->>'unit' <> 'credits' then
        raise exception 'a partly spent credits pack was refunded blindly: %', v_result;
    end if;

    -- Rows the pool never counted do not block a refund.
    delete from public.usage_events where org_id = v_org and kind = 'integration';
    update public.usage_topups set status = 'active', refund_reason = null where paddle_transaction_id = 'txn_credits_1';
    v_result := public.refund_topup_transaction('txn_credits_1', 'test');
    if v_result->>'action' <> 'refunded' then
        raise exception 'an unused credits pack was not refunded: %', v_result;
    end if;
    v_ent := public.resolve_entitlement(v_member);
    if (v_ent->>'integration_credits_included')::numeric <> 1500 then
        raise exception 'a refunded pack still counts: %', v_ent;
    end if;

    -- At zero the gate closes and nothing else does.
    insert into public.usage_events (user_id, kind, model, status, cost_usd, task, org_id)
    select v_owner, 'integration', 'gmail.search_messages', 200, 0.012, 'ask', v_org
      from generate_series(1, 1500);
    v_ent := public.resolve_entitlement(v_member);
    if (v_ent->>'can_run_integration_action')::boolean is not false
       or (v_ent->>'can_start_meeting')::boolean is not true then
        raise exception 'an empty credit pool did not close only its own gate: %', v_ent;
    end if;
end;
$$;

rollback;
