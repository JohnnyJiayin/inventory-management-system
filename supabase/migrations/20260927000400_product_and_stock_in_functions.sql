-- =============================================================================
-- 业务函数：产品型号与入库（Issue #14、#15）以及保活 ping（Issue #8）
-- 对应：需求 7、9、17，架构设计 6、10.2
--
-- 所有写操作只能通过这些函数完成。每个函数都在一个事务中执行，
-- 任何一步失败（raise exception）都会整体回滚。
--
-- 错误约定：raise exception 的 message 是可直接展示给用户的中文说明，
--           hint 是机器可读的错误代码（App 可按需判断）。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 防重复提交（需求 17）
--   _claim_request：返回 null 表示本次请求首次执行；否则返回上次的结果。
--   同一请求编号并发提交时，后到的事务会在 INSERT 处等待先到的事务结束：
--   先到的提交 → 后到的读到结果直接返回；先到的回滚 → 后到的正常执行。
-- -----------------------------------------------------------------------------
create or replace function public._claim_request(p_request_id uuid, p_function text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
  v_fn     text;
begin
  if p_request_id is null then
    return null;
  end if;

  insert into public.request_keys (request_id, function_name)
  values (p_request_id, p_function)
  on conflict (request_id) do nothing;

  if found then
    return null;
  end if;

  select function_name, result into v_fn, v_result
  from public.request_keys where request_id = p_request_id;

  if v_fn <> p_function then
    raise exception '请求编号已被其他操作使用' using hint = 'REQUEST_ID_CONFLICT';
  end if;
  return coalesce(v_result, '{}'::jsonb) || jsonb_build_object('duplicate', true);
end;
$$;

create or replace function public._finish_request(p_request_id uuid, p_result jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_request_id is not null then
    update public.request_keys set result = p_result where request_id = p_request_id;
  end if;
  return p_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- 机身号列表规范化：去首尾空格；不能为空；列表内不能重复
-- -----------------------------------------------------------------------------
create or replace function public._normalize_serials(p_serial_nos text[])
returns text[]
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_out  text[] := '{}';
  v_s    text;
begin
  foreach v_s in array coalesce(p_serial_nos, '{}') loop
    v_s := btrim(coalesce(v_s, ''));
    if v_s = '' then
      raise exception '机身号不能为空' using hint = 'EMPTY_SERIAL';
    end if;
    if v_s = any (v_out) then
      raise exception '机身号 % 在本次清单中重复', v_s using hint = 'DUPLICATE_SERIAL_IN_LIST';
    end if;
    v_out := v_out || v_s;
  end loop;
  return v_out;
end;
$$;

-- -----------------------------------------------------------------------------
-- 内部：对已锁定、已启用的型号执行入库（调用方负责校验）
--   新机身号     → 创建单台产品，入库类型 first（首次入库）
--   已出库       → 恢复在库，入库类型 restock（重新入库），原出库与保修记录保留
--   已在库       → 拒绝，并指出是哪个机身号
-- -----------------------------------------------------------------------------
create or replace function public._do_stock_in(
  p_model_id uuid,
  p_serials  text[],
  p_note     text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_barcode   text;
  v_record_no text := public.next_doc_no('RK');
  v_now       timestamptz := now();
  v_serial    text;
  v_unit_id   uuid;
  v_status    text;
  v_type      text;
  v_items     jsonb := '[]'::jsonb;
  v_first     integer := 0;
  v_restock   integer := 0;
begin
  select barcode into v_barcode from public.product_models where id = p_model_id;

  foreach v_serial in array p_serials loop
    select id, status into v_unit_id, v_status
    from public.units
    where model_id = p_model_id and serial_no = v_serial
    for update;

    if v_unit_id is null then
      begin
        insert into public.units (model_id, barcode, serial_no, status, last_in_at)
        values (p_model_id, v_barcode, v_serial, 'in_stock', v_now)
        returning id into v_unit_id;
      exception when unique_violation then
        raise exception '机身号 % 已在库，不能重复入库', v_serial using hint = 'ALREADY_IN_STOCK';
      end;
      v_type := 'first';
      v_first := v_first + 1;
    elsif v_status = 'shipped' then
      update public.units set status = 'in_stock', last_in_at = v_now where id = v_unit_id;
      v_type := 'restock';
      v_restock := v_restock + 1;
    else
      raise exception '机身号 % 已在库，不能重复入库', v_serial using hint = 'ALREADY_IN_STOCK';
    end if;

    insert into public.stock_in_records (record_no, unit_id, model_id, barcode, serial_no, in_type, in_at, note)
    values (v_record_no, v_unit_id, p_model_id, v_barcode, v_serial, v_type, v_now, nullif(btrim(p_note), ''));

    v_items := v_items || jsonb_build_object('unit_id', v_unit_id, 'serial_no', v_serial, 'in_type', v_type);
    v_unit_id := null;
  end loop;

  return jsonb_build_object(
    'record_no', v_record_no,
    'model_id', p_model_id,
    'count', v_first + v_restock,
    'first_count', v_first,
    'restock_count', v_restock,
    'in_at', v_now,
    'items', v_items
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- create_model：创建型号；初始数量 > 0 时同时创建单台产品和首次入库记录
-- -----------------------------------------------------------------------------
create or replace function public.create_model(
  p_name         text,
  p_model        text,
  p_barcode      text,
  p_description  text    default null,
  p_photo_path   text    default null,
  p_initial_qty  integer default 0,
  p_serial_nos   text[]  default '{}',
  p_request_id   uuid    default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prev     jsonb;
  v_serials  text[];
  v_barcode  text := btrim(coalesce(p_barcode, ''));
  v_existing text;
  v_id       uuid;
  v_stock    jsonb;
begin
  v_prev := public._claim_request(p_request_id, 'create_model');
  if v_prev is not null then
    return v_prev;
  end if;

  if btrim(coalesce(p_name, '')) = '' then
    raise exception '请填写产品名称' using hint = 'NAME_REQUIRED';
  end if;
  if btrim(coalesce(p_model, '')) = '' then
    raise exception '请填写产品型号' using hint = 'MODEL_REQUIRED';
  end if;
  if v_barcode = '' then
    raise exception '请扫描或填写产品条码' using hint = 'BARCODE_REQUIRED';
  end if;
  if p_initial_qty is null or p_initial_qty < 0 then
    raise exception '初始数量必须是大于或等于 0 的整数' using hint = 'INVALID_QTY';
  end if;

  v_serials := public._normalize_serials(p_serial_nos);
  if coalesce(array_length(v_serials, 1), 0) <> p_initial_qty then
    raise exception '初始数量为 %，但录入了 % 个机身号，两者必须一致',
      p_initial_qty, coalesce(array_length(v_serials, 1), 0)
      using hint = 'QTY_MISMATCH';
  end if;

  select name || ' ' || model into v_existing from public.product_models where barcode = v_barcode;
  if v_existing is not null then
    raise exception '产品条码 % 已被型号「%」使用', v_barcode, v_existing using hint = 'DUPLICATE_BARCODE';
  end if;

  begin
    insert into public.product_models (name, model, barcode, description, photo_path)
    values (btrim(p_name), btrim(p_model), v_barcode,
            nullif(btrim(p_description), ''), nullif(btrim(p_photo_path), ''))
    returning id into v_id;
  exception when unique_violation then
    raise exception '产品条码 % 已被其他型号使用', v_barcode using hint = 'DUPLICATE_BARCODE';
  end;

  if p_initial_qty > 0 then
    v_stock := public._do_stock_in(v_id, v_serials, '初始库存');
  end if;

  return public._finish_request(p_request_id, jsonb_build_object(
    'model_id', v_id,
    'stock_in', v_stock
  ));
end;
$$;

-- -----------------------------------------------------------------------------
-- update_model：修改名称、型号、条码、照片、说明、启用状态
--   库存数量不能在这里修改（库存只随入库、出库变化）。
-- -----------------------------------------------------------------------------
create or replace function public.update_model(
  p_model_id     uuid,
  p_name         text,
  p_model        text,
  p_barcode      text,
  p_description  text,
  p_photo_path   text,
  p_active       boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_barcode  text := btrim(coalesce(p_barcode, ''));
  v_existing text;
  v_row      public.product_models;
begin
  perform 1 from public.product_models where id = p_model_id for update;
  if not found then
    raise exception '产品型号不存在' using hint = 'MODEL_NOT_FOUND';
  end if;

  if btrim(coalesce(p_name, '')) = '' then
    raise exception '请填写产品名称' using hint = 'NAME_REQUIRED';
  end if;
  if btrim(coalesce(p_model, '')) = '' then
    raise exception '请填写产品型号' using hint = 'MODEL_REQUIRED';
  end if;
  if v_barcode = '' then
    raise exception '请扫描或填写产品条码' using hint = 'BARCODE_REQUIRED';
  end if;
  if p_active is null then
    raise exception '请选择启用状态' using hint = 'ACTIVE_REQUIRED';
  end if;

  select name || ' ' || model into v_existing
  from public.product_models where barcode = v_barcode and id <> p_model_id;
  if v_existing is not null then
    raise exception '产品条码 % 已被型号「%」使用', v_barcode, v_existing using hint = 'DUPLICATE_BARCODE';
  end if;

  begin
    update public.product_models set
      name        = btrim(p_name),
      model       = btrim(p_model),
      barcode     = v_barcode,
      description = nullif(btrim(p_description), ''),
      photo_path  = nullif(btrim(p_photo_path), ''),
      active      = p_active
    where id = p_model_id
    returning * into v_row;
  exception when unique_violation then
    raise exception '产品条码 % 已被其他型号使用', v_barcode using hint = 'DUPLICATE_BARCODE';
  end;

  return to_jsonb(v_row);
end;
$$;

-- -----------------------------------------------------------------------------
-- bind_barcode：把一个未建档的产品条码绑定到已有型号（需求 5.2、8.2）
--   产品型号只有一个条码，绑定即替换该型号的产品条码。
-- -----------------------------------------------------------------------------
create or replace function public.bind_barcode(p_model_id uuid, p_barcode text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.product_models;
begin
  select * into v_row from public.product_models where id = p_model_id for update;
  if not found then
    raise exception '产品型号不存在' using hint = 'MODEL_NOT_FOUND';
  end if;
  return public.update_model(p_model_id, v_row.name, v_row.model, p_barcode,
                             v_row.description, v_row.photo_path, v_row.active);
end;
$$;

-- -----------------------------------------------------------------------------
-- set_model_active：启用 / 停用型号（停用后不能入库、出库，历史仍可查询）
-- -----------------------------------------------------------------------------
create or replace function public.set_model_active(p_model_id uuid, p_active boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.product_models;
begin
  if p_active is null then
    raise exception '请选择启用状态' using hint = 'ACTIVE_REQUIRED';
  end if;
  update public.product_models set active = p_active where id = p_model_id returning * into v_row;
  if not found then
    raise exception '产品型号不存在' using hint = 'MODEL_NOT_FOUND';
  end if;
  return to_jsonb(v_row);
end;
$$;

-- -----------------------------------------------------------------------------
-- delete_model：只有从未有出入库记录的型号可以删除
--   返回被删除型号的 photo_path，App 据此删除存储桶中的照片。
-- -----------------------------------------------------------------------------
create or replace function public.delete_model(p_model_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.product_models;
begin
  select * into v_row from public.product_models where id = p_model_id for update;
  if not found then
    raise exception '产品型号不存在' using hint = 'MODEL_NOT_FOUND';
  end if;

  if exists (select 1 from public.units where model_id = p_model_id)
     or exists (select 1 from public.stock_in_records where model_id = p_model_id)
     or exists (select 1 from public.outbound_items where model_id = p_model_id) then
    raise exception '该型号已有出入库记录，不能删除，只能停用' using hint = 'HAS_RECORDS';
  end if;

  -- 经销商价格只是配置，不属于出入库记录，随型号一起删除
  delete from public.dealer_prices where model_id = p_model_id;
  delete from public.product_models where id = p_model_id;

  return jsonb_build_object('model_id', p_model_id, 'photo_path', v_row.photo_path);
end;
$$;

-- -----------------------------------------------------------------------------
-- stock_in：首次入库与重新入库（需求 9）
--   p_planned_qty  计划入库数量，必须等于机身号数量
--   p_request_id   App 在点击确认时生成的 UUID，重试时使用同一个
-- -----------------------------------------------------------------------------
create or replace function public.stock_in(
  p_model_id     uuid,
  p_serial_nos   text[],
  p_planned_qty  integer,
  p_request_id   uuid,
  p_note         text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prev     jsonb;
  v_active   boolean;
  v_serials  text[];
  v_count    integer;
begin
  if p_request_id is null then
    raise exception '缺少请求编号' using hint = 'REQUEST_ID_REQUIRED';
  end if;

  v_prev := public._claim_request(p_request_id, 'stock_in');
  if v_prev is not null then
    return v_prev;
  end if;

  select active into v_active from public.product_models where id = p_model_id for share;
  if not found then
    raise exception '产品型号不存在' using hint = 'MODEL_NOT_FOUND';
  end if;
  if not v_active then
    raise exception '该产品型号已停用，不能入库' using hint = 'MODEL_INACTIVE';
  end if;

  if p_planned_qty is null or p_planned_qty <= 0 then
    raise exception '入库数量必须是大于 0 的整数' using hint = 'INVALID_QTY';
  end if;

  v_serials := public._normalize_serials(p_serial_nos);
  v_count := coalesce(array_length(v_serials, 1), 0);
  if v_count <> p_planned_qty then
    raise exception '实际扫描数量（%）与计划入库数量（%）不一致', v_count, p_planned_qty
      using hint = 'QTY_MISMATCH';
  end if;

  return public._finish_request(p_request_id, public._do_stock_in(p_model_id, v_serials, p_note));
end;
$$;

-- -----------------------------------------------------------------------------
-- ping：保活。更新 heartbeat 唯一一行的时间，不返回任何业务数据。
-- -----------------------------------------------------------------------------
create or replace function public.ping()
returns void
language sql
security definer
set search_path = ''
as $$
  update public.heartbeat set pinged_at = now() where id = 1;
$$;
