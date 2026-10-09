-- =============================================================================
-- 保修查询（Issue #37）
-- 对应：需求 13，架构设计 7
--
--   * 保修记录 = 已完成或已撤销订单的出库明细（outbound_items 兼作保修记录），历次记录都保留。
--   * 保修状态不保存，查询时按北京时间的“今天”计算：
--       今天 <= 截止日 → 保修中（截止日当天仍算保修中）
--       今天 >  截止日 → 已过保
--       订单已撤销     → 已失效
--     即将过保 = 保修中且截止日在未来 30 天内（含今天）。
--   * 当前保修 = 该产品最近一次未撤销出库的记录。
-- =============================================================================

create or replace function public.beijing_today()
returns date
language sql
stable
set search_path = ''
as $$
  select (now() at time zone 'Asia/Shanghai')::date;
$$;

-- 保修状态：in_warranty 保修中 / expired 已过保 / void 已失效（订单已撤销）
create or replace function public.warranty_status(p_end date, p_order_status text, p_today date)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_order_status = 'cancelled' then 'void'
    when p_today <= p_end then 'in_warranty'
    else 'expired'
  end;
$$;

create or replace view public.v_warranty
with (security_invoker = on)
as
select
  i.id                as item_id,
  i.unit_id,
  i.model_id,
  m.name              as model_name,
  m.model,
  i.barcode,
  i.serial_no,
  o.id                as order_id,
  o.order_no,
  o.dealer_id,
  o.dealer_name,
  o.status            as order_status,
  o.shipped_at,
  (o.shipped_at at time zone 'Asia/Shanghai')::date as shipped_date,
  i.warranty_start,
  i.warranty_end,
  public.warranty_status(i.warranty_end, o.status, t.today) as warranty_status,
  (o.status = 'completed' and i.warranty_end >= t.today and i.warranty_end <= t.today + 30) as expiring_soon,
  case when o.status = 'completed' then i.warranty_end - t.today end as days_left,
  (o.status = 'completed' and i.id = cur.item_id) as is_current,
  u.status            as unit_status
from public.outbound_items i
join public.outbound_orders o on o.id = i.order_id
join public.product_models m on m.id = i.model_id
join public.units u on u.id = i.unit_id
cross join (select public.beijing_today() as today) t
left join lateral (
  select i2.id as item_id
  from public.outbound_items i2
  join public.outbound_orders o2 on o2.id = i2.order_id
  where i2.unit_id = i.unit_id and o2.status = 'completed'
  order by o2.shipped_at desc, i2.id
  limit 1
) cur on true
where o.status in ('completed', 'cancelled') and i.warranty_end is not null;

comment on view public.v_warranty is '保修记录：每次出库一条；按北京时间计算保修中 / 已过保 / 即将过保；is_current 为当前保修';

grant execute on function public.beijing_today() to authenticated;
grant execute on function public.warranty_status(date, text, date) to authenticated;

revoke all on public.v_warranty from anon, authenticated, public;
grant select on public.v_warranty to authenticated;
