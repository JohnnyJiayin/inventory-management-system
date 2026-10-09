-- Issue #23：经销商、地址、价格
begin;
create extension if not exists pgtap with schema extensions;
-- 在本事务内清空业务数据（结束时回滚），测试不受 seed.sql 或其他数据影响
truncate audit_logs, outbound_items, outbound_orders, stock_in_records, units,
         dealer_prices, dealer_addresses, dealers, product_models, request_keys, doc_counters;
select plan(34);

-- ---------------------------------------------------------------- 新增经销商
select throws_ok($$select create_dealer('', '张三', '1', '[{"address":"a"}]')$$,
  'P0001', '请填写公司名称', '公司名称必填');
select throws_ok($$select create_dealer('甲公司', ' ', '1', '[{"address":"a"}]')$$,
  'P0001', '请填写联系人', '联系人必填');
select throws_ok($$select create_dealer('甲公司', '张三', '', '[{"address":"a"}]')$$,
  'P0001', '请填写电话号码', '电话必填');
select throws_ok($$select create_dealer('甲公司', '张三', '1', '[]')$$,
  'P0001', '请至少填写一个地址', '新增时至少一个地址');
select throws_ok($$select create_dealer('甲公司', '张三', '1', '[{"address":" "}]')$$,
  'P0001', '请填写详细地址', '地址不能为空');
select throws_ok(
  $$select create_dealer('甲公司', '张三', '1', '[{"address":"a","is_default":true},{"address":"b","is_default":true}]')$$,
  'P0001', '每个经销商最多只能有一个默认地址', '不能标记多个默认地址');

select create_dealer(' 甲公司 ', '张三', '13800000000',
  '[{"label":"公司","address":"上海市 1 号"},{"label":"仓库","address":"上海市 2 号"}]') ->> 'dealer_id' as d \gset
select is((select company_name from dealers where id = :'d'), '甲公司', '公司名称去除首尾空格');
select is((select count(*)::int from dealer_addresses where dealer_id = :'d'), 2, '一个经销商可以保存多个地址');
select is((select address from dealer_addresses where dealer_id = :'d' and is_default), '上海市 1 号',
  '没有指定默认地址时第一个地址为默认');

select throws_ok($$select create_dealer('甲公司', '李四', '2', '[{"address":"x"}]')$$,
  'P0001', '公司名称「甲公司」已存在', '公司名称重复被拒绝');

-- 同一请求编号重复提交只创建一次
select create_dealer('乙公司', '李四', '2', '[{"address":"x"}]', '80000000-0000-0000-0000-000000000001');
select create_dealer('乙公司', '李四', '2', '[{"address":"x"}]', '80000000-0000-0000-0000-000000000001');
select is((select count(*)::int from dealers where company_name = '乙公司'), 1, '重复提交只创建一个经销商');

-- ---------------------------------------------------------------- 修改经销商
select update_dealer(:'d', '甲公司（新）', '王五', '139', true);
select is((select row(company_name, contact_name, phone)::text from dealers where id = :'d'),
  '(甲公司（新）,王五,139)', '可以修改公司名称、联系人、电话');
select throws_ok(format($$select update_dealer(%L, '乙公司', '王五', '139', true)$$, :'d'),
  'P0001', '公司名称「乙公司」已存在', '修改为重复的公司名称被拒绝');
select is((select count(*)::int from audit_logs where action = 'dealer.update' and record_id = :'d'), 1,
  '修改经销商写入操作记录');
select set_dealer_active(:'d', false);
select is((select active from dealers where id = :'d'), false, '可以停用经销商');
select set_dealer_active(:'d', true);

-- ---------------------------------------------------------------- 地址
select id as a1 from dealer_addresses where dealer_id = :'d' and address = '上海市 1 号' \gset
select id as a2 from dealer_addresses where dealer_id = :'d' and address = '上海市 2 号' \gset

select set_default_address(:'a2');
select is((select array_agg(address order by address)::text from dealer_addresses where dealer_id = :'d' and is_default),
  '{"上海市 2 号"}', '设新默认地址后，原默认地址自动取消');

select add_dealer_address(:'d', '门店', '上海市 3 号', true) ->> 'id' as a3 \gset
select is((select count(*)::int from dealer_addresses where dealer_id = :'d' and is_default), 1,
  '新增默认地址后仍只有一个默认地址');
select is((select is_default from dealer_addresses where id = :'a3'), true, '新增的地址成为默认');

select add_dealer_address(:'d', null, '上海市 4 号') ->> 'id' as a4 \gset
select is((select is_default from dealer_addresses where id = :'a4'), false, '不勾选默认时不改变默认地址');

select update_dealer_address(:'a3', '门店', '上海市 3 号 B 座', false);
select is((select row(address, active, is_default)::text from dealer_addresses where id = :'a3'),
  '("上海市 3 号 B 座",f,f)', '停用默认地址时同时取消默认');
select throws_ok(format($$select set_default_address(%L)$$, :'a3'),
  'P0001', '停用的地址不能设为默认地址', '停用的地址不能设为默认');
select is((select count(*)::int from audit_logs where action = 'dealer_address.update' and record_id = :'a3'
             and before ->> 'address' = '上海市 3 号' and after ->> 'address' = '上海市 3 号 B 座'), 1,
  '修改地址写入操作记录（修改前后）');

-- 至少保留一个有效地址
select create_dealer('丙公司', '赵六', '3', '[{"address":"only"}]') ->> 'dealer_id' as d3 \gset
select throws_ok(
  format($$select update_dealer_address((select id from dealer_addresses where dealer_id = %L), null, 'only', false)$$, :'d3'),
  'P0001', '每个经销商至少要保留一个有效地址', '不能停用最后一个有效地址');

-- 唯一默认地址由数据库约束保证
select set_default_address(:'a4');
select throws_ok(format($$update dealer_addresses set is_default = true where id = %L$$, :'a2'),
  '23505', null, '数据库约束：每个经销商最多一个默认地址');

-- ---------------------------------------------------------------- 价格
select create_model('功放', '4.4 AMP', 'BC-001') ->> 'model_id' as m \gset

select throws_ok(format($$select set_dealer_price(%L, %L, -1)$$, :'d', :'m'),
  'P0001', '单价不能为负数', '单价不能为负');
select throws_ok(format($$select set_dealer_price(%L, %L, 1.005)$$, :'d', :'m'),
  'P0001', '单价最多保留两位小数', '单价最多两位小数');
select throws_ok(format($$select set_dealer_price(%L, %L, null)$$, :'d', :'m'),
  'P0001', '请填写单价', '单价必填');

select set_dealer_price(:'d', :'m', 100) ->> 'id' as p1 \gset
select set_dealer_price(:'d', :'m', 120.5);
select is((select array_agg(price)::text from dealer_prices where dealer_id = :'d' and model_id = :'m'),
  '{120.50}', '修改价格不产生第二条有效价格');
select is(
  (select row(before ->> 'price', after ->> 'price')::text from audit_logs
    where action = 'dealer_price.update' and record_id = :'p1'),
  '(100.00,120.50)', '修改价格写入操作记录（修改前后）');

select set_dealer_price(:'d', :'m', 0);
select is((select price from dealer_prices where id = :'p1'), 0.00::numeric, '价格可以为 0');

select deactivate_dealer_price(:'p1');
select is((select count(*)::int from dealer_prices where dealer_id = :'d' and model_id = :'m' and active), 0,
  '可以停用价格');
select set_dealer_price(:'d', :'m', 99);
select is((select count(*)::int from dealer_prices where dealer_id = :'d' and model_id = :'m' and active), 1,
  '停用后可以重新设置价格');

-- ---------------------------------------------------------------- 权限
select ok(
  not has_function_privilege('anon', 'public.create_dealer(text, text, text, jsonb, uuid)', 'execute')
  and not has_function_privilege('anon', 'public.set_dealer_price(uuid, uuid, numeric)', 'execute')
  and has_function_privilege('authenticated', 'public.create_dealer(text, text, text, jsonb, uuid)', 'execute')
  and not has_function_privilege('authenticated', 'public._make_default_address(uuid, uuid)', 'execute'),
  '经销商函数只开放给已登录用户，内部函数不开放');
select is(
  (select array_agg(p.proname::text order by p.proname) from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.proname <> 'ping'
      and (has_function_privilege('anon', p.oid, 'execute')
           or aclcontains(coalesce(p.proacl, acldefault('f', p.proowner)), makeaclitem(0, p.proowner, 'EXECUTE', false)))),
  null, '除 ping() 外，anon 和 PUBLIC 不能执行 public 中的任何函数');

select * from finish();
rollback;
