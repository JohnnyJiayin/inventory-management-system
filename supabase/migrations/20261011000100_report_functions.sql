-- =============================================================================
-- 统计函数（Issue #43）：月度、经销商、产品型号、运费、保修五类统计 + 首页汇总
-- 对应：需求 15、16.1，架构设计 7
--
-- 统一筛选参数（五类统计相同，App 切换报表时直接沿用）：
--   p_from / p_to       出库 / 入库日期范围（北京时间日期，含两端）；按月筛选时由 App 换算为当月首尾两天
--   p_dealer_id         经销商
--   p_model_id          产品型号
--   p_serial_no         机身号（精确匹配）
--   p_order_status      completed（默认，有效订单）/ cancelled（只看已撤销订单）
--   p_warranty_status   in_warranty 保修中 / expired 已过保 / expiring 即将过保 / void 已失效
--
-- 统计口径：
--   * 默认只统计已完成订单，已撤销订单的金额和运费不计入。
--   * 运费按订单计一次，不按产品数量重复计算。
--   * 销售金额 = 符合条件的产品实际单价合计；订单总金额 = 销售金额 + 运费。
--     不筛选型号 / 机身号 / 保修状态时，与订单上保存的金额一致。
--   * 入库数量只受日期、型号、机身号筛选影响（入库与经销商、订单、保修无关）。
--   * 保修中 / 已过保数量按每台产品的当前保修计算（与保修查询页“只看当前保修”一致）。
--   * 月份按北京时间自然月。
--
-- 报表函数为 security definer（与其他业务函数一致），只读不写；内部函数（_ 开头）不开放给 App。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- v_report_items：出库明细 + 金额 + 保修状态（统计的基础数据）
-- -----------------------------------------------------------------------------
create or replace view public.v_report_items
with (security_invoker = on)
as
select
  w.item_id,
  w.order_id,
  w.order_no,
  w.order_status,
  w.dealer_id,
  d.company_name                                   as dealer_name,
  w.model_id,
  w.model_name,
  w.model,
  w.serial_no,
  i.actual_price,
  o.shipping_fee,
  w.shipped_at,
  w.shipped_date,
  date_trunc('month', w.shipped_date)::date        as month,
  w.warranty_status,
  w.expiring_soon,
  w.is_current
from public.v_warranty w
join public.outbound_items i on i.id = w.item_id
join public.outbound_orders o on o.id = w.order_id
join public.dealers d on d.id = w.dealer_id;

comment on view public.v_report_items is '统计用出库明细：每台每次出库一条，含实际单价、订单运费、北京时间月份和保修状态';

-- -----------------------------------------------------------------------------
-- 内部：按统一筛选条件取出库明细
-- -----------------------------------------------------------------------------
create or replace function public._report_items(
  p_from             date,
  p_to               date,
  p_dealer_id        uuid,
  p_model_id         uuid,
  p_serial_no        text,
  p_order_status     text,
  p_warranty_status  text
)
returns setof public.v_report_items
language sql
stable
set search_path = ''
as $$
  select r.*
  from public.v_report_items r
  where r.order_status = coalesce(p_order_status, 'completed')
    and (p_from is null or r.shipped_date >= p_from)
    and (p_to is null or r.shipped_date <= p_to)
    and (p_dealer_id is null or r.dealer_id = p_dealer_id)
    and (p_model_id is null or r.model_id = p_model_id)
    and (nullif(btrim(p_serial_no), '') is null or r.serial_no = btrim(p_serial_no))
    and (p_warranty_status is null
         or (p_warranty_status = 'expiring' and r.expiring_soon)
         or r.warranty_status = p_warranty_status);
$$;

-- -----------------------------------------------------------------------------
-- 内部：按日期、型号、机身号取入库记录
-- -----------------------------------------------------------------------------
create or replace function public._report_stock_ins(
  p_from       date,
  p_to         date,
  p_model_id   uuid,
  p_serial_no  text
)
returns table (model_id uuid, serial_no text, in_date date, month date)
language sql
stable
set search_path = ''
as $$
  select r.model_id, r.serial_no, d.in_date, date_trunc('month', d.in_date)::date
  from public.stock_in_records r
  cross join lateral (select (r.in_at at time zone 'Asia/Shanghai')::date as in_date) d
  where (p_from is null or d.in_date >= p_from)
    and (p_to is null or d.in_date <= p_to)
    and (p_model_id is null or r.model_id = p_model_id)
    and (nullif(btrim(p_serial_no), '') is null or r.serial_no = btrim(p_serial_no));
$$;

-- -----------------------------------------------------------------------------
-- report_monthly：月度统计（需求 15.1），按月份倒序
-- -----------------------------------------------------------------------------
create or replace function public.report_monthly(
  p_from             date default null,
  p_to               date default null,
  p_dealer_id        uuid default null,
  p_model_id         uuid default null,
  p_serial_no        text default null,
  p_order_status     text default 'completed',
  p_warranty_status  text default null
)
returns table (
  month            date,
  in_qty           integer,
  out_qty          integer,
  order_count      integer,
  products_amount  numeric,
  shipping_fee     numeric,
  total_amount     numeric,
  in_warranty_qty  integer,
  expired_qty      integer
)
language sql
stable
security definer
set search_path = ''
as $$
  with items as (
    select * from public._report_items(p_from, p_to, p_dealer_id, p_model_id, p_serial_no,
                                       p_order_status, p_warranty_status)
  ),
  outs as (
    select it.month,
           count(*)::integer                                                       as out_qty,
           sum(it.actual_price)                                                    as amount,
           count(*) filter (where it.is_current and it.warranty_status = 'in_warranty')::integer as iw,
           count(*) filter (where it.is_current and it.warranty_status = 'expired')::integer     as ex
    from items it
    group by it.month
  ),
  fees as (
    -- 一张订单的明细都在同一个月；运费按订单计一次
    select o.month, count(*)::integer as order_count, sum(o.shipping_fee) as fee
    from (select distinct on (it.order_id) it.order_id, it.month, it.shipping_fee from items it) o
    group by o.month
  ),
  ins as (
    select s.month, count(*)::integer as in_qty
    from public._report_stock_ins(p_from, p_to, p_model_id, p_serial_no) s
    group by s.month
  )
  select coalesce(outs.month, ins.month),
         coalesce(ins.in_qty, 0),
         coalesce(outs.out_qty, 0),
         coalesce(fees.order_count, 0),
         coalesce(outs.amount, 0),
         coalesce(fees.fee, 0),
         coalesce(outs.amount, 0) + coalesce(fees.fee, 0),
         coalesce(outs.iw, 0),
         coalesce(outs.ex, 0)
  from outs
  join fees on fees.month = outs.month
  full join ins on ins.month = outs.month
  order by 1 desc;
$$;

-- -----------------------------------------------------------------------------
-- report_dealers：经销商统计（需求 15.2），按订单总金额倒序
--   models：各型号出库数量 [{model_id, model_name, model, qty}]
-- -----------------------------------------------------------------------------
create or replace function public.report_dealers(
  p_from             date default null,
  p_to               date default null,
  p_dealer_id        uuid default null,
  p_model_id         uuid default null,
  p_serial_no        text default null,
  p_order_status     text default 'completed',
  p_warranty_status  text default null
)
returns table (
  dealer_id        uuid,
  dealer_name      text,
  order_count      integer,
  item_count       integer,
  products_amount  numeric,
  shipping_fee     numeric,
  total_amount     numeric,
  models           jsonb
)
language sql
stable
security definer
set search_path = ''
as $$
  with items as (
    select * from public._report_items(p_from, p_to, p_dealer_id, p_model_id, p_serial_no,
                                       p_order_status, p_warranty_status)
  ),
  per_dealer as (
    select it.dealer_id, min(it.dealer_name) as dealer_name,
           count(*)::integer as item_count, sum(it.actual_price) as amount
    from items it
    group by it.dealer_id
  ),
  fees as (
    select o.dealer_id, count(*)::integer as order_count, sum(o.shipping_fee) as fee
    from (select distinct on (it.order_id) it.order_id, it.dealer_id, it.shipping_fee from items it) o
    group by o.dealer_id
  ),
  per_model as (
    select x.dealer_id,
           jsonb_agg(jsonb_build_object('model_id', x.model_id, 'model_name', x.model_name,
                                        'model', x.model, 'qty', x.qty)
                     order by x.qty desc, x.model_name, x.model) as models
    from (select it.dealer_id, it.model_id, min(it.model_name) as model_name, min(it.model) as model,
                 count(*)::integer as qty
          from items it
          group by it.dealer_id, it.model_id) x
    group by x.dealer_id
  )
  select p.dealer_id, p.dealer_name, f.order_count, p.item_count,
         p.amount, f.fee, p.amount + f.fee, m.models
  from per_dealer p
  join fees f on f.dealer_id = p.dealer_id
  join per_model m on m.dealer_id = p.dealer_id
  order by p.amount + f.fee desc, p.dealer_name;
$$;

-- -----------------------------------------------------------------------------
-- report_models：产品型号统计（需求 15.3）
--   stock_qty 为当前库存（不受日期筛选影响）。只列出有入库、出库或库存的型号。
-- -----------------------------------------------------------------------------
create or replace function public.report_models(
  p_from             date default null,
  p_to               date default null,
  p_dealer_id        uuid default null,
  p_model_id         uuid default null,
  p_serial_no        text default null,
  p_order_status     text default 'completed',
  p_warranty_status  text default null
)
returns table (
  model_id         uuid,
  model_name       text,
  model            text,
  in_qty           integer,
  out_qty          integer,
  stock_qty        integer,
  dealer_count     integer,
  products_amount  numeric,
  in_warranty_qty  integer,
  expired_qty      integer
)
language sql
stable
security definer
set search_path = ''
as $$
  with items as (
    select * from public._report_items(p_from, p_to, p_dealer_id, p_model_id, p_serial_no,
                                       p_order_status, p_warranty_status)
  ),
  outs as (
    select it.model_id,
           count(*)::integer as out_qty,
           count(distinct it.dealer_id)::integer as dealer_count,
           sum(it.actual_price) as amount,
           count(*) filter (where it.is_current and it.warranty_status = 'in_warranty')::integer as iw,
           count(*) filter (where it.is_current and it.warranty_status = 'expired')::integer     as ex
    from items it
    group by it.model_id
  ),
  ins as (
    select s.model_id, count(*)::integer as in_qty
    from public._report_stock_ins(p_from, p_to, p_model_id, p_serial_no) s
    group by s.model_id
  ),
  stock as (
    select u.model_id, count(*)::integer as stock_qty
    from public.units u
    where u.status = 'in_stock'
      and (p_model_id is null or u.model_id = p_model_id)
      and (nullif(btrim(p_serial_no), '') is null or u.serial_no = btrim(p_serial_no))
    group by u.model_id
  )
  select m.id, m.name, m.model,
         coalesce(ins.in_qty, 0),
         coalesce(outs.out_qty, 0),
         coalesce(stock.stock_qty, 0),
         coalesce(outs.dealer_count, 0),
         coalesce(outs.amount, 0),
         coalesce(outs.iw, 0),
         coalesce(outs.ex, 0)
  from public.product_models m
  left join outs on outs.model_id = m.id
  left join ins on ins.model_id = m.id
  left join stock on stock.model_id = m.id
  where (p_model_id is null or m.id = p_model_id)
    and (outs.model_id is not null or ins.model_id is not null or stock.model_id is not null)
  order by m.name, m.model;
$$;

-- -----------------------------------------------------------------------------
-- report_shipping：运费统计明细（需求 15.5），每张订单一行，按出库时间倒序
--   每月总运费、每个经销商每月运费、每月订单数、每月出库产品数由这些行汇总得到。
-- -----------------------------------------------------------------------------
create or replace function public.report_shipping(
  p_from             date default null,
  p_to               date default null,
  p_dealer_id        uuid default null,
  p_model_id         uuid default null,
  p_serial_no        text default null,
  p_order_status     text default 'completed',
  p_warranty_status  text default null
)
returns table (
  month            date,
  dealer_id        uuid,
  dealer_name      text,
  order_id         uuid,
  order_no         text,
  shipped_at       timestamptz,
  item_count       integer,
  products_amount  numeric,
  shipping_fee     numeric,
  total_amount     numeric
)
language sql
stable
security definer
set search_path = ''
as $$
  select min(it.month), it.dealer_id, min(it.dealer_name), it.order_id, min(it.order_no), min(it.shipped_at),
         count(*)::integer,
         sum(it.actual_price),
         min(it.shipping_fee),
         sum(it.actual_price) + min(it.shipping_fee)
  from public._report_items(p_from, p_to, p_dealer_id, p_model_id, p_serial_no,
                            p_order_status, p_warranty_status) it
  group by it.order_id, it.dealer_id
  order by min(it.shipped_at) desc, min(it.order_no) desc;
$$;

-- -----------------------------------------------------------------------------
-- report_warranty：保修统计（需求 13.3、16.6）
--   保修中 / 已过保 / 即将过保按当前保修计算，与保修查询页“只看当前保修”的结果一致；
--   已失效 = 已撤销订单中的保修记录（只在筛选已撤销订单时出现）。明细直接查询 v_warranty。
-- -----------------------------------------------------------------------------
create or replace function public.report_warranty(
  p_from             date default null,
  p_to               date default null,
  p_dealer_id        uuid default null,
  p_model_id         uuid default null,
  p_serial_no        text default null,
  p_order_status     text default 'completed',
  p_warranty_status  text default null
)
returns table (
  in_warranty_qty  integer,
  expiring_qty     integer,
  expired_qty      integer,
  void_qty         integer
)
language sql
stable
security definer
set search_path = ''
as $$
  select count(*) filter (where it.is_current and it.warranty_status = 'in_warranty')::integer,
         count(*) filter (where it.is_current and it.expiring_soon)::integer,
         count(*) filter (where it.is_current and it.warranty_status = 'expired')::integer,
         count(*) filter (where it.warranty_status = 'void')::integer
  from public._report_items(p_from, p_to, p_dealer_id, p_model_id, p_serial_no,
                            p_order_status, p_warranty_status) it;
$$;

-- -----------------------------------------------------------------------------
-- dashboard_summary：首页（需求 16.1）
--   当月按北京时间自然月；当月数字直接取 report_monthly / report_warranty，保证与报表页一致。
-- -----------------------------------------------------------------------------
create or replace function public.dashboard_summary()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with t as (
    select date_trunc('month', public.beijing_today())::date as month_start
  ),
  m as (
    select r.*
    from t, public.report_monthly(t.month_start, (t.month_start + interval '1 month - 1 day')::date) r
  ),
  w as (
    select r.* from public.report_warranty() r
  )
  select jsonb_build_object(
    'month',            (select month_start from t),
    'stock_qty',        (select count(*) from public.units where status = 'in_stock'),
    'model_count',      (select count(*) from public.product_models where active),
    'month_in_qty',     coalesce((select in_qty from m), 0),
    'month_out_qty',    coalesce((select out_qty from m), 0),
    'month_order_count', coalesce((select order_count from m), 0),
    'month_sales',      coalesce((select products_amount from m), 0),
    'month_shipping',   coalesce((select shipping_fee from m), 0),
    'expiring_qty',     (select expiring_qty from w)
  );
$$;

-- -----------------------------------------------------------------------------
-- 权限：只开放给已登录用户
-- -----------------------------------------------------------------------------
revoke all on public.v_report_items from anon, authenticated, public;
grant select on public.v_report_items to authenticated;

revoke execute on function public._report_items(date, date, uuid, uuid, text, text, text) from anon, authenticated, public;
revoke execute on function public._report_stock_ins(date, date, uuid, text) from anon, authenticated, public;
grant execute on function public.report_monthly(date, date, uuid, uuid, text, text, text)  to authenticated;
grant execute on function public.report_dealers(date, date, uuid, uuid, text, text, text)  to authenticated;
grant execute on function public.report_models(date, date, uuid, uuid, text, text, text)   to authenticated;
grant execute on function public.report_shipping(date, date, uuid, uuid, text, text, text) to authenticated;
grant execute on function public.report_warranty(date, date, uuid, uuid, text, text, text) to authenticated;
grant execute on function public.dashboard_summary()                                       to authenticated;
