-- =============================================================================
-- 库存视图与单号生成（Issue #5）
-- 对应：架构设计 5.3、6.2
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 单号：RK20260927-001 / CK20260927-001
--   * 日期按北京时间；每个前缀每天从 001 开始递增。
--   * INSERT ... ON CONFLICT DO UPDATE 会对计数行加锁，并发调用也不会重复。
--   * 超过 999 时自然扩展为 4 位及以上，不会截断。
-- -----------------------------------------------------------------------------
create or replace function public.next_doc_no(p_prefix text, p_at timestamptz default now())
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_day date := (p_at at time zone 'Asia/Shanghai')::date;
  v_no  integer;
begin
  if p_prefix not in ('RK', 'CK') then
    raise exception '未知的单号前缀：%', p_prefix;
  end if;

  insert into public.doc_counters as c (prefix, day, last_no)
  values (p_prefix, v_day, 1)
  on conflict (prefix, day) do update set last_no = c.last_no + 1
  returning c.last_no into v_no;

  return p_prefix || to_char(v_day, 'YYYYMMDD') || '-' ||
         case when v_no < 1000 then lpad(v_no::text, 3, '0') else v_no::text end;
end;
$$;

-- -----------------------------------------------------------------------------
-- v_model_stock：按型号统计库存
--   stock_qty     当前库存 = 状态为“在库”的单台产品数量
--   total_in      累计入库次数（含重新入库）
--   total_out     累计有效出库数量（只算已完成订单）
--   last_in_at    最近入库时间
--   last_out_at   最近有效出库时间
--   has_records   是否已有出入库记录（有记录的型号只能停用，不能删除）
-- security_invoker：查询视图时按调用者身份执行 RLS。
-- -----------------------------------------------------------------------------
create or replace view public.v_model_stock
with (security_invoker = on)
as
select
  m.id,
  m.name,
  m.model,
  m.barcode,
  m.photo_path,
  m.description,
  m.active,
  m.created_at,
  m.updated_at,
  coalesce(u.stock_qty, 0)  as stock_qty,
  coalesce(si.total_in, 0)  as total_in,
  coalesce(so.total_out, 0) as total_out,
  si.last_in_at,
  so.last_out_at,
  (u.unit_count is not null or si.total_in is not null) as has_records
from public.product_models m
left join lateral (
  select count(*) filter (where status = 'in_stock')::integer as stock_qty,
         count(*)::integer as unit_count
  from public.units
  where model_id = m.id
  having count(*) > 0
) u on true
left join lateral (
  select count(*)::integer as total_in, max(in_at) as last_in_at
  from public.stock_in_records
  where model_id = m.id
  having count(*) > 0
) si on true
left join lateral (
  select count(*)::integer as total_out, max(o.shipped_at) as last_out_at
  from public.outbound_items i
  join public.outbound_orders o on o.id = i.order_id
  where i.model_id = m.id and o.status = 'completed'
  having count(*) > 0
) so on true;

comment on view public.v_model_stock is '按型号统计在库数量、累计入库、累计出库、最近入库/出库时间';
