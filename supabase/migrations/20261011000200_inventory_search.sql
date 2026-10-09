-- =============================================================================
-- 库存多条件查询（Issue #40）
-- 对应：需求 14
--
-- search_models：返回符合条件的型号（v_model_stock 的行），所有条件同时满足（AND）。
--   p_query            名称、型号、条码（包含即可，不区分大小写）
--   以下条件针对单台产品，同一台产品要同时满足：
--   p_serial_no        机身号（包含即可）
--   p_unit_status      in_stock 在库 / shipped 已出库
--   p_in_from / p_in_to    入库日期（北京时间，含两端）：该产品有一次入库在范围内
--   p_dealer_id        经销商：该产品有一次有效出库给该经销商
--   p_out_from / p_out_to  出库日期（北京时间，含两端）：该产品有一次有效出库在范围内
--   p_warranty_status  in_warranty / expired / expiring：该产品的当前保修状态
--   经销商、出库日期、保修状态针对同一次出库判断（例如“出库给甲且仍在保修中”）。
-- =============================================================================

create or replace function public.search_models(
  p_query            text default null,
  p_serial_no        text default null,
  p_unit_status      text default null,
  p_in_from          date default null,
  p_in_to            date default null,
  p_dealer_id        uuid default null,
  p_out_from         date default null,
  p_out_to           date default null,
  p_warranty_status  text default null
)
returns setof public.v_model_stock
language sql
stable
security definer
set search_path = ''
as $$
  select s.*
  from public.v_model_stock s
  where (nullif(btrim(p_query), '') is null
         or s.name    ilike '%' || btrim(p_query) || '%'
         or s.model   ilike '%' || btrim(p_query) || '%'
         or s.barcode ilike '%' || btrim(p_query) || '%')
    and (
      -- 没有单台产品条件时不要求存在单台产品（新建、尚未入库的型号也能查到）
      (nullif(btrim(p_serial_no), '') is null and p_unit_status is null
       and p_in_from is null and p_in_to is null
       and p_dealer_id is null and p_out_from is null and p_out_to is null and p_warranty_status is null)
      or exists (
        select 1
        from public.units u
        where u.model_id = s.id
          and (nullif(btrim(p_serial_no), '') is null or u.serial_no ilike '%' || btrim(p_serial_no) || '%')
          and (p_unit_status is null or u.status = p_unit_status)
          and (p_in_from is null and p_in_to is null or exists (
                select 1 from public.stock_in_records r
                where r.unit_id = u.id
                  and (p_in_from is null or (r.in_at at time zone 'Asia/Shanghai')::date >= p_in_from)
                  and (p_in_to is null or (r.in_at at time zone 'Asia/Shanghai')::date <= p_in_to)))
          and (p_dealer_id is null and p_out_from is null and p_out_to is null and p_warranty_status is null
               or exists (
                select 1 from public.v_warranty w
                where w.unit_id = u.id
                  and w.order_status = 'completed'
                  and (p_dealer_id is null or w.dealer_id = p_dealer_id)
                  and (p_out_from is null or w.shipped_date >= p_out_from)
                  and (p_out_to is null or w.shipped_date <= p_out_to)
                  and (p_warranty_status is null
                       or w.is_current and (
                            (p_warranty_status = 'expiring' and w.expiring_soon)
                            or w.warranty_status = p_warranty_status))))
      )
    )
  order by s.active desc, s.name, s.model;
$$;

grant execute on function public.search_models(text, text, text, date, date, uuid, date, date, text) to authenticated;
