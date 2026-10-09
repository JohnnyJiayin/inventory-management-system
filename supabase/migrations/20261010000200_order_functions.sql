-- =============================================================================
-- 业务函数：出库订单（Issue #27 编辑、#28 确认出库、#29 撤销出库）
-- 对应：需求 11、12、17、20.4，架构设计 6、6.1、6.3
--
-- 订单状态：draft 编辑中 → completed 已完成 → cancelled 已撤销
--           （编辑中的订单也可以直接作废为 cancelled，不影响库存）
-- “编辑中”的订单只保存在云端：关闭 App 或断网恢复后可以继续编辑。
-- 快照（经销商名称、联系人、电话、地址）在确认出库时保存，之后修改经销商资料不影响历史订单。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- units.last_out_order_id：最近一次把该产品出库的订单（撤销出库时判断是否已重新入库）
--   不能用时间判断：now() 是事务开始时间，等待行锁的事务时间可能早于实际提交顺序。
-- -----------------------------------------------------------------------------
alter table public.units
  add column if not exists last_out_order_id uuid references public.outbound_orders (id) on delete set null;
comment on column public.units.last_out_order_id is '最近一次出库的订单；撤销出库后清空';
-- 已有数据：已出库的产品取最近一张已完成订单
update public.units u set last_out_order_id = (
  select o.id from public.outbound_items i join public.outbound_orders o on o.id = i.order_id
  where i.unit_id = u.id and o.status = 'completed'
  order by o.shipped_at desc limit 1)
where u.status = 'shipped' and u.last_out_order_id is null;

-- -----------------------------------------------------------------------------
-- 内部：锁定并返回“编辑中”的订单；其他状态拒绝修改
-- -----------------------------------------------------------------------------
create or replace function public._lock_draft_order(p_order_id uuid)
returns public.outbound_orders
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.outbound_orders;
begin
  select * into v_order from public.outbound_orders where id = p_order_id for update;
  if not found then
    raise exception '订单不存在' using hint = 'ORDER_NOT_FOUND';
  end if;
  if v_order.status = 'completed' then
    raise exception '订单 % 已确认出库，不能修改', v_order.order_no using hint = 'ORDER_COMPLETED';
  end if;
  if v_order.status = 'cancelled' then
    raise exception '订单 % 已撤销，不能修改', v_order.order_no using hint = 'ORDER_CANCELLED';
  end if;
  return v_order;
end;
$$;

-- -----------------------------------------------------------------------------
-- 内部：校验收货地址属于该经销商且有效
-- -----------------------------------------------------------------------------
create or replace function public._check_order_address(p_dealer_id uuid, p_address_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dealer uuid;
  v_active boolean;
begin
  if p_address_id is null then
    raise exception '请选择收货地址' using hint = 'ADDRESS_REQUIRED';
  end if;
  select dealer_id, active into v_dealer, v_active from public.dealer_addresses where id = p_address_id;
  if not found or v_dealer <> p_dealer_id then
    raise exception '收货地址不属于该经销商' using hint = 'ADDRESS_MISMATCH';
  end if;
  if not v_active then
    raise exception '收货地址已停用，请重新选择' using hint = 'ADDRESS_INACTIVE';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- create_order：新建“编辑中”的出库订单（需求 12.1）
--   经销商必须启用；不指定地址时自动选择默认地址（没有默认地址时选最早的有效地址）。
--   生成出库单号 CK20260927-001，扫码页面顶部始终显示。
-- -----------------------------------------------------------------------------
create or replace function public.create_order(
  p_dealer_id   uuid,
  p_address_id  uuid default null,
  p_request_id  uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prev     jsonb;
  v_dealer   public.dealers;
  v_address  uuid := p_address_id;
  v_id       uuid;
  v_no       text;
begin
  v_prev := public._claim_request(p_request_id, 'create_order');
  if v_prev is not null then
    return v_prev;
  end if;

  select * into v_dealer from public.dealers where id = p_dealer_id for share;
  if not found then
    raise exception '经销商不存在' using hint = 'DEALER_NOT_FOUND';
  end if;
  if not v_dealer.active then
    raise exception '经销商「%」已停用，不能新建出库订单', v_dealer.company_name using hint = 'DEALER_INACTIVE';
  end if;

  if v_address is null then
    select id into v_address from public.dealer_addresses
    where dealer_id = p_dealer_id and active
    order by is_default desc, created_at
    limit 1;
  end if;
  perform public._check_order_address(p_dealer_id, v_address);

  v_no := public.next_doc_no('CK');
  insert into public.outbound_orders (order_no, dealer_id, address_id)
  values (v_no, p_dealer_id, v_address)
  returning id into v_id;

  return public._finish_request(p_request_id, jsonb_build_object(
    'order_id', v_id, 'order_no', v_no, 'address_id', v_address));
end;
$$;

-- -----------------------------------------------------------------------------
-- add_order_item：向订单加入一台产品（需求 12.2）
--   校验：订单编辑中、型号启用、机身号属于该型号、产品在库、订单内不重复、经销商有该型号价格。
--   写入默认单价和实际单价（相同）。
--   订单原来只有 1 台且已改价时，加入第 2 台必须由用户确认（p_reset_price = true），
--   已改的价格恢复为默认单价（架构设计 6.3）。
-- -----------------------------------------------------------------------------
create or replace function public.add_order_item(
  p_order_id     uuid,
  p_model_id     uuid,
  p_serial_no    text,
  p_reset_price  boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order   public.outbound_orders := public._lock_draft_order(p_order_id);
  v_model   public.product_models;
  v_serial  text := btrim(coalesce(p_serial_no, ''));
  v_unit    public.units;
  v_price   numeric;
  v_last_no text;
  v_single  public.outbound_items;
  v_count   integer;
  v_row     public.outbound_items;
begin
  select * into v_model from public.product_models where id = p_model_id;
  if not found then
    raise exception '产品型号不存在' using hint = 'MODEL_NOT_FOUND';
  end if;
  if not v_model.active then
    raise exception '「% %」已停用，不能出库', v_model.name, v_model.model using hint = 'MODEL_INACTIVE';
  end if;
  if v_serial = '' then
    raise exception '机身号不能为空' using hint = 'EMPTY_SERIAL';
  end if;

  select * into v_unit from public.units where model_id = p_model_id and serial_no = v_serial;
  if not found then
    if exists (select 1 from public.units where serial_no = v_serial) then
      raise exception '机身号 % 不属于「% %」，请确认扫描的产品条码是否正确', v_serial, v_model.name, v_model.model
        using hint = 'MODEL_MISMATCH';
    end if;
    raise exception '「% %」下没有机身号 % 的产品，请先入库', v_model.name, v_model.model, v_serial
      using hint = 'UNIT_NOT_FOUND';
  end if;

  if exists (select 1 from public.outbound_items where order_id = p_order_id and unit_id = v_unit.id) then
    raise exception '机身号 % 已在本订单中', v_serial using hint = 'DUPLICATE_IN_ORDER';
  end if;

  if v_unit.status <> 'in_stock' then
    select o.order_no into v_last_no
    from public.outbound_items i join public.outbound_orders o on o.id = i.order_id
    where i.unit_id = v_unit.id and o.status = 'completed'
    order by o.shipped_at desc limit 1;
    raise exception '机身号 % 已出库%，不能重复出库', v_serial,
      coalesce('（订单 ' || v_last_no || '）', '') using hint = 'UNIT_SHIPPED';
  end if;

  select price into v_price from public.dealer_prices
  where dealer_id = v_order.dealer_id and model_id = p_model_id and active;
  if not found then
    raise exception '当前经销商尚未设置该型号的价格，请先填写单价' using hint = 'PRICE_NOT_SET';
  end if;

  select count(*) into v_count from public.outbound_items where order_id = p_order_id;
  if v_count = 1 then
    select * into v_single from public.outbound_items where order_id = p_order_id;
    if v_single.actual_price <> v_single.default_price then
      if not coalesce(p_reset_price, false) then
        raise exception '多台订单不能改价，已改的价格将恢复为默认单价' using hint = 'PRICE_RESET_REQUIRED';
      end if;
      update public.outbound_items set actual_price = default_price where id = v_single.id;
    end if;
  end if;

  insert into public.outbound_items (order_id, unit_id, model_id, barcode, serial_no, default_price, actual_price)
  values (p_order_id, v_unit.id, p_model_id, v_model.barcode, v_serial, v_price, v_price)
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

-- -----------------------------------------------------------------------------
-- remove_order_item：从编辑中的订单删除一台产品；运费不变（需求 12.3）
-- -----------------------------------------------------------------------------
create or replace function public.remove_order_item(p_item_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order_id uuid;
begin
  select order_id into v_order_id from public.outbound_items where id = p_item_id;
  if not found then
    raise exception '订单明细不存在' using hint = 'ITEM_NOT_FOUND';
  end if;
  perform public._lock_draft_order(v_order_id);
  delete from public.outbound_items where id = p_item_id;
  return jsonb_build_object('order_id', v_order_id, 'item_id', p_item_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- update_order：修改收货地址、运费、备注（只限编辑中的订单）
--   p_shipping_fee 为 null 表示尚未填写（确认出库时必填，没有运费填 0）。
-- -----------------------------------------------------------------------------
create or replace function public.update_order(
  p_order_id      uuid,
  p_address_id    uuid,
  p_shipping_fee  numeric,
  p_note          text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.outbound_orders := public._lock_draft_order(p_order_id);
  v_row   public.outbound_orders;
begin
  perform public._check_order_address(v_order.dealer_id, p_address_id);
  if p_shipping_fee is not null then
    perform public._check_money(p_shipping_fee, '运费');
  end if;

  update public.outbound_orders set
    address_id   = p_address_id,
    shipping_fee = p_shipping_fee,
    note         = nullif(btrim(p_note), '')
  where id = p_order_id
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

-- -----------------------------------------------------------------------------
-- set_order_item_price：修改实际单价（售后补发，架构设计 6.3）
--   只有订单明细为 1 台时可以修改，可以改为 0；只影响本订单，不改经销商默认价格。
-- -----------------------------------------------------------------------------
create or replace function public.set_order_item_price(p_item_id uuid, p_actual_price numeric)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order_id uuid;
  v_price    numeric := public._check_money(p_actual_price, '实际单价');
  v_row      public.outbound_items;
begin
  select order_id into v_order_id from public.outbound_items where id = p_item_id;
  if not found then
    raise exception '订单明细不存在' using hint = 'ITEM_NOT_FOUND';
  end if;
  perform public._lock_draft_order(v_order_id);

  if (select count(*) from public.outbound_items where order_id = v_order_id) <> 1 then
    raise exception '多台订单不能修改实际单价' using hint = 'MULTI_ITEM_PRICE';
  end if;

  update public.outbound_items set actual_price = v_price where id = p_item_id returning * into v_row;
  return to_jsonb(v_row);
end;
$$;

-- -----------------------------------------------------------------------------
-- confirm_order：确认出库（需求 12.4、20.4，架构设计 6.1）
--   一个事务内：锁定订单和产品行 → 全部校验 → 保存快照 → 计算金额 → 产品改为已出库
--   → 写保修起止时间 → 订单改为已完成。任何一步失败整体回滚，库存完全不变。
--   p_request_id：App 点击确认时生成，超时重试使用同一个；重复请求直接返回上次结果。
-- -----------------------------------------------------------------------------
create or replace function public.confirm_order(p_order_id uuid, p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prev      jsonb;
  v_order     public.outbound_orders;
  v_dealer    public.dealers;
  v_address   public.dealer_addresses;
  v_count     integer;
  v_problems  text;
  v_now       timestamptz := now();
  v_end       date := ((v_now at time zone 'Asia/Shanghai')::date + interval '1 year')::date;
  v_amount    numeric;
  v_row       public.outbound_orders;
begin
  if p_request_id is null then
    raise exception '缺少请求编号' using hint = 'REQUEST_ID_REQUIRED';
  end if;

  v_prev := public._claim_request(p_request_id, 'confirm_order');
  if v_prev is not null then
    return v_prev;
  end if;

  v_order := public._lock_draft_order(p_order_id);

  -- 经销商与地址：锁定经销商行（共享锁），停用经销商、修改 / 停用地址都要先锁定经销商行，
  -- 所以确认提交之前它们无法生效，不会出现“停用后仍然出库”
  select * into v_dealer from public.dealers where id = v_order.dealer_id for share;
  if not v_dealer.active then
    raise exception '经销商「%」已停用，不能出库', v_dealer.company_name using hint = 'DEALER_INACTIVE';
  end if;
  perform public._check_order_address(v_order.dealer_id, v_order.address_id);
  select * into v_address from public.dealer_addresses where id = v_order.address_id;

  -- 至少一台、运费已填写
  select count(*) into v_count from public.outbound_items where order_id = p_order_id;
  if v_count = 0 then
    raise exception '订单中至少要有一台产品' using hint = 'NO_ITEMS';
  end if;
  if v_order.shipping_fee is null then
    raise exception '请填写运费（没有运费填 0）' using hint = 'FEE_REQUIRED';
  end if;

  -- 锁定订单内所有产品行（按 id 顺序加锁，避免并发确认时死锁），
  -- 锁定后读到的是最新状态：同一台产品被另一张订单先确认时，这里会看到“已出库”
  perform 1 from public.units
  where id in (select unit_id from public.outbound_items where order_id = p_order_id)
  order by id
  for update;

  select string_agg(format('机身号 %s（%s %s）%s', i.serial_no, m.name, m.model,
                           case when not m.active then '型号已停用'
                                when u.status <> 'in_stock' then '已出库'
                           end), '；' order by i.created_at)
  into v_problems
  from public.outbound_items i
  join public.units u on u.id = i.unit_id
  join public.product_models m on m.id = i.model_id
  where i.order_id = p_order_id and (u.status <> 'in_stock' or not m.active);
  if v_problems is not null then
    raise exception '以下产品不能出库：%', v_problems using hint = 'UNIT_NOT_AVAILABLE';
  end if;

  -- 多台订单：实际单价必须等于默认单价（App 出错也不会写入错误价格）
  if v_count > 1 and exists (select 1 from public.outbound_items
                             where order_id = p_order_id and actual_price <> default_price) then
    raise exception '多台订单不能改价，实际单价必须等于默认单价' using hint = 'MULTI_ITEM_PRICE';
  end if;

  select sum(actual_price) into v_amount from public.outbound_items where order_id = p_order_id;
  -- 单价和运费各自不超过上限，但合计可能超出 numeric(12,2)，提前给出业务错误
  if v_amount + v_order.shipping_fee >= 10000000000 then
    raise exception '订单金额合计超出范围' using hint = 'MONEY_RANGE';
  end if;

  update public.units set status = 'shipped', last_out_at = v_now, last_out_order_id = p_order_id
  where id in (select unit_id from public.outbound_items where order_id = p_order_id);

  update public.outbound_items set warranty_start = v_now, warranty_end = v_end
  where order_id = p_order_id;

  update public.outbound_orders set
    status          = 'completed',
    dealer_name     = v_dealer.company_name,
    contact_name    = v_dealer.contact_name,
    phone           = v_dealer.phone,
    address_text    = v_address.address,
    products_amount = v_amount,
    total_amount    = v_amount + shipping_fee,
    shipped_at      = v_now,
    completed_at    = v_now
  where id = p_order_id
  returning * into v_row;

  return public._finish_request(p_request_id, jsonb_build_object(
    'order_id', v_row.id,
    'order_no', v_row.order_no,
    'item_count', v_count,
    'products_amount', v_row.products_amount,
    'shipping_fee', v_row.shipping_fee,
    'total_amount', v_row.total_amount,
    'shipped_at', v_row.shipped_at,
    'warranty_end', v_end
  ));
end;
$$;

-- -----------------------------------------------------------------------------
-- cancel_order：撤销出库（需求 12.5）
--   已完成的订单：一个事务内订单改为已撤销 → 产品恢复在库 → 本次保修失效（订单状态为已撤销，
--   保修查询不再以它为准）→ 记录撤销时间和原因。订单保留在历史中，金额和运费不计入统计。
--   编辑中的订单：直接作废（没有扣过库存）。
--   订单中的产品在本次出库之后已经重新入库的，不能撤销（否则库存会被重复恢复）。
-- -----------------------------------------------------------------------------
create or replace function public.cancel_order(
  p_order_id    uuid,
  p_reason      text,
  p_request_id  uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prev      jsonb;
  v_order     public.outbound_orders;
  v_reason    text := btrim(coalesce(p_reason, ''));
  v_problems  text;
  v_now       timestamptz := now();
  v_row       public.outbound_orders;
begin
  v_prev := public._claim_request(p_request_id, 'cancel_order');
  if v_prev is not null then
    return v_prev;
  end if;

  select * into v_order from public.outbound_orders where id = p_order_id for update;
  if not found then
    raise exception '订单不存在' using hint = 'ORDER_NOT_FOUND';
  end if;
  if v_order.status = 'cancelled' then
    raise exception '订单 % 已撤销', v_order.order_no using hint = 'ORDER_CANCELLED';
  end if;
  if v_reason = '' then
    raise exception '请填写撤销原因' using hint = 'REASON_REQUIRED';
  end if;

  if v_order.status = 'completed' then
    perform 1 from public.units
    where id in (select unit_id from public.outbound_items where order_id = p_order_id)
    order by id
    for update;

    -- 产品仍为已出库、且最近一次出库就是本订单，才说明之后没有重新入库
    -- （重新入库后状态变为在库；之后再被其他订单出库时，最近出库订单变为那张订单）
    select string_agg(format('机身号 %s', i.serial_no), '、' order by i.created_at) into v_problems
    from public.outbound_items i
    join public.units u on u.id = i.unit_id
    where i.order_id = p_order_id
      and (u.status <> 'shipped' or u.last_out_order_id is distinct from p_order_id);
    if v_problems is not null then
      raise exception '% 在本次出库之后已重新入库，不能撤销该订单', v_problems using hint = 'UNIT_RESTOCKED';
    end if;

    -- 恢复在库；最近出库时间改为该产品其他有效订单中最近的一次
    update public.units u set
      status            = 'in_stock',
      last_out_order_id = null,
      last_out_at = (select max(o.shipped_at)
                     from public.outbound_items i2
                     join public.outbound_orders o on o.id = i2.order_id
                     where i2.unit_id = u.id and o.status = 'completed' and o.id <> p_order_id)
    where u.id in (select unit_id from public.outbound_items where order_id = p_order_id);
  end if;

  update public.outbound_orders set
    status        = 'cancelled',
    cancelled_at  = v_now,
    cancel_reason = v_reason
  where id = p_order_id
  returning * into v_row;

  return public._finish_request(p_request_id, jsonb_build_object(
    'order_id', v_row.id,
    'order_no', v_row.order_no,
    'was_completed', v_order.status = 'completed',
    'cancelled_at', v_row.cancelled_at
  ));
end;
$$;

-- -----------------------------------------------------------------------------
-- v_order_summary：订单列表与详情
--   编辑中的订单显示经销商当前资料和实时金额；已完成 / 已撤销的订单显示确认时保存的快照。
-- -----------------------------------------------------------------------------
create or replace view public.v_order_summary
with (security_invoker = on)
as
select
  o.id,
  o.order_no,
  o.dealer_id,
  o.address_id,
  o.status,
  coalesce(o.dealer_name, d.company_name)  as dealer_name,
  coalesce(o.contact_name, d.contact_name) as contact_name,
  coalesce(o.phone, d.phone)               as phone,
  coalesce(o.address_text, a.address)      as address_text,
  a.label                                  as address_label,
  coalesce(i.item_count, 0)                as item_count,
  coalesce(o.products_amount, i.amount, 0) as products_amount,
  o.shipping_fee,
  coalesce(o.total_amount, coalesce(i.amount, 0) + coalesce(o.shipping_fee, 0)) as total_amount,
  coalesce(i.price_modified, false)        as price_modified,
  o.shipped_at,
  o.completed_at,
  o.cancelled_at,
  o.cancel_reason,
  o.note,
  o.created_at,
  o.updated_at
from public.outbound_orders o
join public.dealers d on d.id = o.dealer_id
left join public.dealer_addresses a on a.id = o.address_id
left join lateral (
  select count(*)::integer as item_count,
         sum(actual_price) as amount,
         bool_or(actual_price <> default_price) as price_modified
  from public.outbound_items
  where order_id = o.id
  having count(*) > 0
) i on true;

comment on view public.v_order_summary is '出库订单列表：产品数量、金额；编辑中订单显示实时资料，已完成订单显示快照';

-- -----------------------------------------------------------------------------
-- 权限
-- -----------------------------------------------------------------------------
revoke execute on function public._lock_draft_order(uuid) from anon, authenticated, public;
revoke execute on function public._check_order_address(uuid, uuid) from anon, authenticated, public;

grant execute on function public.create_order(uuid, uuid, uuid)                    to authenticated;
grant execute on function public.add_order_item(uuid, uuid, text, boolean)         to authenticated;
grant execute on function public.remove_order_item(uuid)                           to authenticated;
grant execute on function public.update_order(uuid, uuid, numeric, text)           to authenticated;
grant execute on function public.set_order_item_price(uuid, numeric)               to authenticated;
grant execute on function public.confirm_order(uuid, uuid)                         to authenticated;
grant execute on function public.cancel_order(uuid, text, uuid)                    to authenticated;

revoke all on public.v_order_summary from anon, authenticated, public;
grant select on public.v_order_summary to authenticated;
