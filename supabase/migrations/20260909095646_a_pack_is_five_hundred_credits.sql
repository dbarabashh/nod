-- The Automation Pack is 500 credits for $10, not 1,000.
--
-- Pipedream bills every proxied request, not only the reads Nod meters:
-- filing a task, posting a message and the ticket-status mirror all spend a
-- broker credit the person never sees. At 1,000 credits the $10 pack paid
-- for the metered reads and nothing else. See D0040 in nod-playbook.
--
-- Expand: three new SKUs beside the old ones, sorted ahead of them so a client
-- that picks the first active pack offers the new one; the 1,000 rows stay
-- active for checkouts already opened against them and are retired by a later
-- contract migration once no intent names them.

alter table public.topup_checkout_intents
    drop constraint if exists topup_checkout_intents_sku_check;
alter table public.topup_checkout_intents
    add constraint topup_checkout_intents_sku_check
    check (sku in (
        'starter_5h_usd_12', 'pro_10h_usd_29',
        'automation_1000_usd_10', 'starter_automation_1000_usd_10', 'teams_automation_1000_usd_10',
        'automation_500_usd_10', 'starter_automation_500_usd_10', 'teams_automation_500_usd_10'
    ));

insert into public.plan_prices (
    paddle_price_id, plan, billing_cycle, kind, display_amount, currency,
    is_founding, sort_order, active, sku, top_up_hours, top_up_credits, available_for_new_checkout
) values
    ('pri_REPLACE_automation500_pro',     'pro',     'one_time', 'topup', 10, 'USD', false, 27, true, 'automation_500_usd_10',         null, 500, false),
    ('pri_REPLACE_automation500_starter', 'starter', 'one_time', 'topup', 10, 'USD', false, 28, true, 'starter_automation_500_usd_10', null, 500, false),
    ('pri_REPLACE_automation500_teams',   'teams',   'one_time', 'topup', 10, 'USD', false, 29, true, 'teams_automation_500_usd_10',   null, 500, false)
on conflict (paddle_price_id) do nothing;

update public.plan_prices
   set available_for_new_checkout = false
 where sku in ('automation_1000_usd_10', 'starter_automation_1000_usd_10', 'teams_automation_1000_usd_10');
