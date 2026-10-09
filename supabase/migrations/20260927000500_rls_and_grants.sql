-- =============================================================================
-- 行级权限（RLS）与执行权限（Issue #4）
-- 对应：架构设计 9.2
--
--   * 所有表开启 RLS。
--   * 只有已登录用户（authenticated）可以读取业务数据；anon 读不到任何业务数据。
--   * 业务表禁止 App 直接 insert / update / delete，写操作只能通过业务函数
--     （security definer）完成。
--   * ping() 单独开放给 anon。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 表：开启 RLS，收回 anon / authenticated 的全部表权限
-- -----------------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array[
    'product_models', 'units', 'stock_in_records',
    'dealers', 'dealer_addresses', 'dealer_prices',
    'outbound_orders', 'outbound_items',
    'audit_logs', 'request_keys', 'doc_counters', 'heartbeat'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from anon, authenticated, public', t);
  end loop;
end
$$;

-- 业务数据：已登录用户只读
do $$
declare
  t text;
begin
  foreach t in array array[
    'product_models', 'units', 'stock_in_records',
    'dealers', 'dealer_addresses', 'dealer_prices',
    'outbound_orders', 'outbound_items',
    'audit_logs'
  ] loop
    execute format('grant select on table public.%I to authenticated', t);
    execute format(
      'create policy %I on public.%I for select to authenticated using (true)',
      t || '_select_authenticated', t);
  end loop;
end
$$;
-- request_keys / doc_counters / heartbeat：不开放给任何 App 角色（只由函数内部访问）

-- 视图：只给已登录用户（security_invoker，底层表 RLS 仍然生效）
revoke all on public.v_model_stock from anon, authenticated, public;
grant select on public.v_model_stock to authenticated;

-- 以后新建的表 / 视图 / 函数默认不开放给 anon、authenticated，需要显式授权
alter default privileges in schema public revoke all on tables from anon, authenticated, public;
alter default privileges in schema public revoke all on sequences from anon, authenticated, public;
alter default privileges in schema public revoke execute on functions from anon, authenticated, public;

-- -----------------------------------------------------------------------------
-- 函数：先全部收回，再逐个授权
-- -----------------------------------------------------------------------------
revoke execute on all functions in schema public from anon, authenticated, public;

grant execute on function public.create_model(text, text, text, text, text, integer, text[], uuid) to authenticated;
grant execute on function public.update_model(uuid, text, text, text, text, text, boolean)         to authenticated;
grant execute on function public.bind_barcode(uuid, text)                                         to authenticated;
grant execute on function public.set_model_active(uuid, boolean)                                  to authenticated;
grant execute on function public.delete_model(uuid)                                               to authenticated;
grant execute on function public.stock_in(uuid, text[], integer, uuid, text)                      to authenticated;

-- 保活：anon 只能调用 ping()
grant execute on function public.ping() to anon, authenticated;

-- -----------------------------------------------------------------------------
-- 产品照片：私有存储桶 product-photos，仅已登录用户可读写
-- （线上项目也可以在后台手动创建；这里保证任何新项目执行迁移后都存在且为私有）
-- -----------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-photos', 'product-photos', false, 2097152,
        array['image/jpeg', 'image/png', 'image/heic'])
on conflict (id) do update set public = false;

create policy "product_photos_select_authenticated" on storage.objects
  for select to authenticated using (bucket_id = 'product-photos');
create policy "product_photos_insert_authenticated" on storage.objects
  for insert to authenticated with check (bucket_id = 'product-photos');
create policy "product_photos_update_authenticated" on storage.objects
  for update to authenticated using (bucket_id = 'product-photos');
create policy "product_photos_delete_authenticated" on storage.objects
  for delete to authenticated using (bucket_id = 'product-photos');
