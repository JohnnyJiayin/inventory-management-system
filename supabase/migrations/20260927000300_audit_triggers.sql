-- =============================================================================
-- 操作记录触发器（Issue #6）
-- 对应：需求 18 操作记录、架构设计 9.3
--
-- 由数据库自动记录，App 忘记写也不会漏。触发器与业务操作在同一事务内：
-- 业务失败回滚时操作记录也一并回滚，因此写入的记录 result 均为 'success'。
--
-- 操作类型（action）：
--   product.create / product.update / product.barcode_change / product.delete
--   dealer.create / dealer.update
--   dealer_address.create / dealer_address.update
--   dealer_price.create / dealer_price.update
--   stock_in.first / stock_in.restock
--   order.create / order.update / order.fee_change / order.confirm / order.cancel
--   order.item_add / order.item_remove / order.price_change
-- =============================================================================

create or replace function public.tg_audit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_before   jsonb;
  v_after    jsonb;
  v_action   text;
  v_entity   text := tg_argv[0];
  v_record   uuid;
  v_model    uuid;
  v_order    uuid;
begin
  if tg_op in ('UPDATE', 'DELETE') then
    v_before := to_jsonb(old);
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    v_after := to_jsonb(new);
  end if;

  -- 只改了 updated_at 等无实际内容的更新不记录
  if tg_op = 'UPDATE' and (v_before - 'updated_at') = (v_after - 'updated_at') then
    return new;
  end if;

  v_record := coalesce(v_after ->> 'id', v_before ->> 'id')::uuid;

  case tg_table_name
    when 'product_models' then
      v_model := v_record;
      v_action := case tg_op
        when 'INSERT' then 'product.create'
        when 'DELETE' then 'product.delete'
        else case when old.barcode is distinct from new.barcode
                  then 'product.barcode_change' else 'product.update' end
      end;

    when 'stock_in_records' then
      v_model := (v_after ->> 'model_id')::uuid;
      v_action := 'stock_in.' || (v_after ->> 'in_type');

    when 'outbound_orders' then
      v_order := v_record;
      v_action := case
        when tg_op = 'INSERT' then 'order.create'
        when old.status = 'draft' and new.status = 'completed' then 'order.confirm'
        when old.status <> 'cancelled' and new.status = 'cancelled' then 'order.cancel'
        when old.shipping_fee is distinct from new.shipping_fee then 'order.fee_change'
        else 'order.update'
      end;

    when 'outbound_items' then
      v_order := coalesce(v_after ->> 'order_id', v_before ->> 'order_id')::uuid;
      v_model := coalesce(v_after ->> 'model_id', v_before ->> 'model_id')::uuid;
      v_action := case tg_op
        when 'INSERT' then 'order.item_add'
        when 'DELETE' then 'order.item_remove'
        else case when old.actual_price is distinct from new.actual_price
                  then 'order.price_change' else null end
      end;
      -- 确认出库时写入保修起止时间不单独记录（已由 order.confirm 记录）
      if v_action is null then
        return new;
      end if;

    when 'dealer_prices' then
      v_model := (v_after ->> 'model_id')::uuid;
      v_action := v_entity || case tg_op when 'INSERT' then '.create' else '.update' end;

    else
      v_action := v_entity || case tg_op
        when 'INSERT' then '.create'
        when 'DELETE' then '.delete'
        else '.update' end;
  end case;

  insert into public.audit_logs (action, table_name, record_id, model_id, order_id, before, after, result, actor)
  values (v_action, tg_table_name, v_record, v_model, v_order, v_before, v_after, 'success', auth.uid());

  return coalesce(new, old);
end;
$$;

create trigger audit_product_models
  after insert or update or delete on public.product_models
  for each row execute function public.tg_audit('product');

create trigger audit_stock_in_records
  after insert on public.stock_in_records
  for each row execute function public.tg_audit('stock_in');

create trigger audit_dealers
  after insert or update on public.dealers
  for each row execute function public.tg_audit('dealer');

create trigger audit_dealer_addresses
  after insert or update on public.dealer_addresses
  for each row execute function public.tg_audit('dealer_address');

create trigger audit_dealer_prices
  after insert or update on public.dealer_prices
  for each row execute function public.tg_audit('dealer_price');

create trigger audit_outbound_orders
  after insert or update on public.outbound_orders
  for each row execute function public.tg_audit('order');

create trigger audit_outbound_items
  after insert or update or delete on public.outbound_items
  for each row execute function public.tg_audit('order_item');
