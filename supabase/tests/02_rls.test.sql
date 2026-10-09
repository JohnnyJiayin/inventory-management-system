-- Issue #4：行级权限；Issue #8：anon 只能调用 ping()
begin;
create extension if not exists pgtap with schema extensions;
-- 在本事务内清空业务数据（结束时回滚），测试不受 seed.sql 或其他数据影响
truncate audit_logs, outbound_items, outbound_orders, stock_in_records, units,
         dealer_prices, dealer_addresses, dealers, product_models, request_keys, doc_counters;
select plan(21);

insert into product_models (id, name, model, barcode) values
  ('10000000-0000-0000-0000-000000000001', '功放', '4.4 AMP', 'BC-001');
insert into units (id, model_id, barcode, serial_no) values
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'BC-001', '187');
insert into dealers (company_name, contact_name, phone) values ('甲公司', '张三', '1');

-- 所有表都开启 RLS
select is(
  (select count(*)::int from pg_tables
    where schemaname = 'public' and not rowsecurity),
  0, '所有 public 表都开启了 RLS');

-- ---------------------------------------------------------------- 未登录（anon）
set local role anon;
set local request.jwt.claims to '{"role":"anon"}';

select throws_ok($$select * from product_models$$, '42501', null, 'anon 读不到 product_models');
select throws_ok($$select * from units$$, '42501', null, 'anon 读不到 units');
select throws_ok($$select * from dealers$$, '42501', null, 'anon 读不到 dealers');
select throws_ok($$select * from v_model_stock$$, '42501', null, 'anon 读不到 v_model_stock');
select throws_ok($$select * from audit_logs$$, '42501', null, 'anon 读不到 audit_logs');
select throws_ok($$select * from heartbeat$$, '42501', null, 'anon 读不到 heartbeat');
-- 注意：本地镜像 supabase/postgres 17.6.1.106 在调用无权限函数时会崩溃（镜像缺陷），
-- 因此这里用 has_function_privilege 检查权限，而不是直接调用。
select ok(
  not has_function_privilege('anon', 'public.create_model(text, text, text, text, text, integer, text[], uuid)', 'execute')
  and not has_function_privilege('anon', 'public.stock_in(uuid, text[], integer, uuid, text)', 'execute')
  and not has_function_privilege('anon', 'public.next_doc_no(text, timestamptz)', 'execute'),
  'anon 不能调用业务函数');
select lives_ok($$select ping()$$, 'anon 可以调用 ping()');

reset role;

-- ---------------------------------------------------------------- 已登录（authenticated）
set local role authenticated;
set local request.jwt.claims to '{"sub":"00000000-0000-0000-0000-0000000000aa","role":"authenticated"}';

select is((select count(*)::int from product_models), 1, '登录后可以读取 product_models');
select is((select count(*)::int from units), 1, '登录后可以读取 units');
select is((select stock_qty from v_model_stock where barcode = 'BC-001'), 1, '登录后可以读取 v_model_stock');

select throws_ok(
  $$update units set status = 'shipped' where id = '20000000-0000-0000-0000-000000000001'$$,
  '42501', null, '登录后直接修改库存状态被拒绝');
select throws_ok(
  $$insert into units (model_id, barcode, serial_no) values ('10000000-0000-0000-0000-000000000001', 'BC-001', '999')$$,
  '42501', null, '登录后直接插入单台产品被拒绝');
select throws_ok(
  $$delete from product_models where id = '10000000-0000-0000-0000-000000000001'$$,
  '42501', null, '登录后直接删除型号被拒绝');
select throws_ok(
  $$update product_models set name = 'x'$$,
  '42501', null, '登录后直接修改型号被拒绝');
select throws_ok(
  $$insert into audit_logs (action, table_name) values ('x', 'y')$$,
  '42501', null, '登录后不能伪造操作记录');
select throws_ok($$select * from request_keys$$, '42501', null, '登录后读不到 request_keys');
select ok(
  (select bool_and(not has_function_privilege('authenticated', p.oid, 'execute'))
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and (p.proname like '\_%' or p.proname in ('next_doc_no', 'tg_audit', 'tg_set_updated_at'))),
  '登录后不能调用内部函数');

select lives_ok(
  $$select stock_in('10000000-0000-0000-0000-000000000001', array['188'], 1, gen_random_uuid())$$,
  '登录后可以通过业务函数入库');

reset role;

select is(
  (select stock_qty from v_model_stock where barcode = 'BC-001'), 2,
  '业务函数写入成功');

select * from finish();
rollback;
