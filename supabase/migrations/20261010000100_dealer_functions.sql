-- =============================================================================
-- 业务函数：经销商、地址、价格（Issue #23）
-- 对应：需求 10、11、6.3–6.5
--
-- 错误约定同 20260927000400：message 是可直接展示给用户的中文说明，hint 是错误代码。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 新建函数默认不开放给 PUBLIC
--   PostgreSQL 默认给 PUBLIC 授予新函数的 EXECUTE；20260927000500 中按 schema 设置的
--   default privileges 只能追加、不能收回这一全局默认，所以这里在全局层面收回。
--   此后新建的函数必须显式 grant 才能被 App 调用。
-- -----------------------------------------------------------------------------
alter default privileges revoke execute on functions from public;

-- -----------------------------------------------------------------------------
-- 金额校验：不能为空、不能为负、最多两位小数
--   numeric(12,2) 会把 1.005 静默四舍五入，所以写入前必须显式检查。
-- -----------------------------------------------------------------------------
create or replace function public._check_money(p_value numeric, p_label text)
returns numeric
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_value is null then
    raise exception '请填写%', p_label using hint = 'MONEY_REQUIRED';
  end if;
  if p_value < 0 then
    raise exception '%不能为负数', p_label using hint = 'MONEY_NEGATIVE';
  end if;
  if p_value <> round(p_value, 2) then
    raise exception '%最多保留两位小数', p_label using hint = 'MONEY_SCALE';
  end if;
  if p_value >= 10000000000 then
    raise exception '%超出范围', p_label using hint = 'MONEY_RANGE';
  end if;
  return p_value;
end;
$$;

-- -----------------------------------------------------------------------------
-- 内部：校验经销商基本资料
-- -----------------------------------------------------------------------------
create or replace function public._check_dealer_fields(p_company_name text, p_contact_name text, p_phone text)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if btrim(coalesce(p_company_name, '')) = '' then
    raise exception '请填写公司名称' using hint = 'COMPANY_REQUIRED';
  end if;
  if btrim(coalesce(p_contact_name, '')) = '' then
    raise exception '请填写联系人' using hint = 'CONTACT_REQUIRED';
  end if;
  if btrim(coalesce(p_phone, '')) = '' then
    raise exception '请填写电话号码' using hint = 'PHONE_REQUIRED';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- create_dealer：新增经销商，同时新增至少一个地址
--   p_addresses：[{"label": "公司", "address": "上海市…", "is_default": true}, …]
--   没有标记默认地址时，第一个地址为默认；标记了多个默认地址时拒绝。
-- -----------------------------------------------------------------------------
create or replace function public.create_dealer(
  p_company_name  text,
  p_contact_name  text,
  p_phone         text,
  p_addresses     jsonb,
  p_request_id    uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prev      jsonb;
  v_id        uuid;
  v_addr      jsonb;
  v_defaults  integer;
  v_index     integer := 0;
begin
  v_prev := public._claim_request(p_request_id, 'create_dealer');
  if v_prev is not null then
    return v_prev;
  end if;

  perform public._check_dealer_fields(p_company_name, p_contact_name, p_phone);

  if p_addresses is null or jsonb_typeof(p_addresses) <> 'array' or jsonb_array_length(p_addresses) = 0 then
    raise exception '请至少填写一个地址' using hint = 'ADDRESS_REQUIRED';
  end if;
  select count(*) into v_defaults
  from jsonb_array_elements(p_addresses) a
  where coalesce((a ->> 'is_default')::boolean, false);
  if v_defaults > 1 then
    raise exception '每个经销商最多只能有一个默认地址' using hint = 'MULTIPLE_DEFAULT';
  end if;

  if exists (select 1 from public.dealers where company_name = btrim(p_company_name)) then
    raise exception '公司名称「%」已存在', btrim(p_company_name) using hint = 'DUPLICATE_COMPANY';
  end if;

  begin
    insert into public.dealers (company_name, contact_name, phone)
    values (btrim(p_company_name), btrim(p_contact_name), btrim(p_phone))
    returning id into v_id;
  exception when unique_violation then
    raise exception '公司名称「%」已存在', btrim(p_company_name) using hint = 'DUPLICATE_COMPANY';
  end;

  for v_addr in select * from jsonb_array_elements(p_addresses) loop
    if btrim(coalesce(v_addr ->> 'address', '')) = '' then
      raise exception '请填写详细地址' using hint = 'ADDRESS_REQUIRED';
    end if;
    insert into public.dealer_addresses (dealer_id, label, address, is_default)
    values (v_id,
            nullif(btrim(v_addr ->> 'label'), ''),
            btrim(v_addr ->> 'address'),
            case when v_defaults = 0 then v_index = 0
                 else coalesce((v_addr ->> 'is_default')::boolean, false) end);
    v_index := v_index + 1;
  end loop;

  return public._finish_request(p_request_id, jsonb_build_object('dealer_id', v_id));
end;
$$;

-- -----------------------------------------------------------------------------
-- update_dealer：修改公司名称、联系人、电话、启用状态
--   修改不影响已完成订单（订单保存了快照）。
-- -----------------------------------------------------------------------------
create or replace function public.update_dealer(
  p_dealer_id     uuid,
  p_company_name  text,
  p_contact_name  text,
  p_phone         text,
  p_active        boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.dealers;
begin
  perform 1 from public.dealers where id = p_dealer_id for update;
  if not found then
    raise exception '经销商不存在' using hint = 'DEALER_NOT_FOUND';
  end if;
  perform public._check_dealer_fields(p_company_name, p_contact_name, p_phone);
  if p_active is null then
    raise exception '请选择启用状态' using hint = 'ACTIVE_REQUIRED';
  end if;
  if exists (select 1 from public.dealers where company_name = btrim(p_company_name) and id <> p_dealer_id) then
    raise exception '公司名称「%」已存在', btrim(p_company_name) using hint = 'DUPLICATE_COMPANY';
  end if;

  begin
    update public.dealers set
      company_name = btrim(p_company_name),
      contact_name = btrim(p_contact_name),
      phone        = btrim(p_phone),
      active       = p_active
    where id = p_dealer_id
    returning * into v_row;
  exception when unique_violation then
    raise exception '公司名称「%」已存在', btrim(p_company_name) using hint = 'DUPLICATE_COMPANY';
  end;

  return to_jsonb(v_row);
end;
$$;

-- -----------------------------------------------------------------------------
-- set_dealer_active：启用 / 停用经销商（停用后不能新建出库订单，历史订单仍可查询）
-- -----------------------------------------------------------------------------
create or replace function public.set_dealer_active(p_dealer_id uuid, p_active boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.dealers;
begin
  if p_active is null then
    raise exception '请选择启用状态' using hint = 'ACTIVE_REQUIRED';
  end if;
  update public.dealers set active = p_active where id = p_dealer_id returning * into v_row;
  if not found then
    raise exception '经销商不存在' using hint = 'DEALER_NOT_FOUND';
  end if;
  return to_jsonb(v_row);
end;
$$;

-- -----------------------------------------------------------------------------
-- 内部：把某个地址设为该经销商唯一的默认地址（调用方已锁定经销商行）
--   先取消原默认再设置新默认，满足部分唯一索引 (dealer_id) where is_default。
-- -----------------------------------------------------------------------------
create or replace function public._make_default_address(p_dealer_id uuid, p_address_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.dealer_addresses set is_default = false
  where dealer_id = p_dealer_id and is_default and id <> p_address_id;
  update public.dealer_addresses set is_default = true
  where id = p_address_id and not is_default;
end;
$$;

-- -----------------------------------------------------------------------------
-- add_dealer_address：新增地址；p_is_default 为 true 时自动取消原默认地址。
--   经销商还没有有效的默认地址时，新地址自动成为默认。
-- -----------------------------------------------------------------------------
create or replace function public.add_dealer_address(
  p_dealer_id   uuid,
  p_label       text,
  p_address     text,
  p_is_default  boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id  uuid;
  v_row public.dealer_addresses;
begin
  perform 1 from public.dealers where id = p_dealer_id for update;
  if not found then
    raise exception '经销商不存在' using hint = 'DEALER_NOT_FOUND';
  end if;
  if btrim(coalesce(p_address, '')) = '' then
    raise exception '请填写详细地址' using hint = 'ADDRESS_REQUIRED';
  end if;

  insert into public.dealer_addresses (dealer_id, label, address)
  values (p_dealer_id, nullif(btrim(p_label), ''), btrim(p_address))
  returning id into v_id;

  if coalesce(p_is_default, false)
     or not exists (select 1 from public.dealer_addresses
                    where dealer_id = p_dealer_id and is_default and active) then
    perform public._make_default_address(p_dealer_id, v_id);
  end if;

  select * into v_row from public.dealer_addresses where id = v_id;
  return to_jsonb(v_row);
end;
$$;

-- -----------------------------------------------------------------------------
-- update_dealer_address：修改地址名称、详细地址、启用状态
--   * 停用默认地址时同时取消默认（之后可以另设默认地址）。
--   * 每个经销商至少保留一个有效地址。
--   * 修改不影响已完成订单（订单保存了地址快照）。
-- -----------------------------------------------------------------------------
create or replace function public.update_dealer_address(
  p_address_id  uuid,
  p_label       text,
  p_address     text,
  p_active      boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dealer uuid;
  v_row    public.dealer_addresses;
begin
  select dealer_id into v_dealer from public.dealer_addresses where id = p_address_id;
  if not found then
    raise exception '地址不存在' using hint = 'ADDRESS_NOT_FOUND';
  end if;
  perform 1 from public.dealers where id = v_dealer for update;

  if btrim(coalesce(p_address, '')) = '' then
    raise exception '请填写详细地址' using hint = 'ADDRESS_REQUIRED';
  end if;
  if p_active is null then
    raise exception '请选择启用状态' using hint = 'ACTIVE_REQUIRED';
  end if;
  if not p_active and not exists (
    select 1 from public.dealer_addresses
    where dealer_id = v_dealer and active and id <> p_address_id) then
    raise exception '每个经销商至少要保留一个有效地址' using hint = 'LAST_ADDRESS';
  end if;

  update public.dealer_addresses set
    label      = nullif(btrim(p_label), ''),
    address    = btrim(p_address),
    active     = p_active,
    is_default = is_default and p_active
  where id = p_address_id
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

-- -----------------------------------------------------------------------------
-- set_default_address：设为默认地址（自动取消原默认）；停用的地址不能设为默认
-- -----------------------------------------------------------------------------
create or replace function public.set_default_address(p_address_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dealer uuid;
  v_active boolean;
  v_row    public.dealer_addresses;
begin
  select dealer_id into v_dealer from public.dealer_addresses where id = p_address_id;
  if not found then
    raise exception '地址不存在' using hint = 'ADDRESS_NOT_FOUND';
  end if;
  perform 1 from public.dealers where id = v_dealer for update;

  select active into v_active from public.dealer_addresses where id = p_address_id;
  if not v_active then
    raise exception '停用的地址不能设为默认地址' using hint = 'ADDRESS_INACTIVE';
  end if;

  perform public._make_default_address(v_dealer, p_address_id);
  select * into v_row from public.dealer_addresses where id = p_address_id;
  return to_jsonb(v_row);
end;
$$;

-- -----------------------------------------------------------------------------
-- set_dealer_price：设置“经销商 + 型号”的默认单价
--   已有有效价格时修改（写入操作记录 dealer_price.update），否则新增。
--   修改只影响以后加入订单的产品；已加入订单的明细保存了当时的单价。
-- -----------------------------------------------------------------------------
create or replace function public.set_dealer_price(p_dealer_id uuid, p_model_id uuid, p_price numeric)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_price numeric := public._check_money(p_price, '单价');
  v_row   public.dealer_prices;
begin
  perform 1 from public.dealers where id = p_dealer_id for update;
  if not found then
    raise exception '经销商不存在' using hint = 'DEALER_NOT_FOUND';
  end if;
  perform 1 from public.product_models where id = p_model_id;
  if not found then
    raise exception '产品型号不存在' using hint = 'MODEL_NOT_FOUND';
  end if;

  update public.dealer_prices set price = v_price
  where dealer_id = p_dealer_id and model_id = p_model_id and active
  returning * into v_row;

  if not found then
    insert into public.dealer_prices (dealer_id, model_id, price)
    values (p_dealer_id, p_model_id, v_price)
    returning * into v_row;
  end if;

  return to_jsonb(v_row);
end;
$$;

-- -----------------------------------------------------------------------------
-- deactivate_dealer_price：停用价格（之后扫描该型号会提示“尚未设置价格”）
-- -----------------------------------------------------------------------------
create or replace function public.deactivate_dealer_price(p_price_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.dealer_prices;
begin
  update public.dealer_prices set active = false where id = p_price_id returning * into v_row;
  if not found then
    raise exception '价格记录不存在' using hint = 'PRICE_NOT_FOUND';
  end if;
  return to_jsonb(v_row);
end;
$$;

-- -----------------------------------------------------------------------------
-- 权限：新函数默认不开放（见 20260927000500 的 default privileges），逐个授权
-- -----------------------------------------------------------------------------
revoke execute on function public._check_money(numeric, text) from anon, authenticated, public;
revoke execute on function public._check_dealer_fields(text, text, text) from anon, authenticated, public;
revoke execute on function public._make_default_address(uuid, uuid) from anon, authenticated, public;

grant execute on function public.create_dealer(text, text, text, jsonb, uuid)         to authenticated;
grant execute on function public.update_dealer(uuid, text, text, text, boolean)       to authenticated;
grant execute on function public.set_dealer_active(uuid, boolean)                     to authenticated;
grant execute on function public.add_dealer_address(uuid, text, text, boolean)        to authenticated;
grant execute on function public.update_dealer_address(uuid, text, text, boolean)    to authenticated;
grant execute on function public.set_default_address(uuid)                            to authenticated;
grant execute on function public.set_dealer_price(uuid, uuid, numeric)                to authenticated;
grant execute on function public.deactivate_dealer_price(uuid)                        to authenticated;
