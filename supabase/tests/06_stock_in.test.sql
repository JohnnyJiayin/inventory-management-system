-- Issue #15：stock_in（首次入库与重新入库）
begin;
create extension if not exists pgtap with schema extensions;
-- 在本事务内清空业务数据（结束时回滚），测试不受 seed.sql 或其他数据影响
truncate audit_logs, outbound_items, outbound_orders, stock_in_records, units,
         dealer_prices, dealer_addresses, dealers, product_models, request_keys, doc_counters;
select plan(19);

select create_model('功放', '4.4 AMP', 'BC-001') ->> 'model_id' as m \gset

-- ---------------------------------------------------------------- 参数校验
select throws_ok(format($$select stock_in(%L, array['1'], 0, gen_random_uuid())$$, :'m'),
  'P0001', '入库数量必须是大于 0 的整数', '计划数量必须为正整数');
select throws_ok(format($$select stock_in(%L, array['1','2'], 3, gen_random_uuid())$$, :'m'),
  'P0001', '实际扫描数量（2）与计划入库数量（3）不一致', '实际数量必须等于计划数量');
select throws_ok(format($$select stock_in(%L, array['1','1'], 2, gen_random_uuid())$$, :'m'),
  'P0001', '机身号 1 在本次清单中重复', '列表内机身号不能重复');
select throws_ok(format($$select stock_in(%L, array['1'], 1, null)$$, :'m'),
  'P0001', '缺少请求编号', '必须提供请求编号');
select throws_ok($$select stock_in(gen_random_uuid(), array['1'], 1, gen_random_uuid())$$,
  'P0001', '产品型号不存在', '型号必须存在');

-- ---------------------------------------------------------------- 首次入库
select stock_in(:'m', array['1','2','3'], 3, '60000000-0000-0000-0000-000000000001') as r1 \gset
select is((:'r1'::jsonb ->> 'first_count')::int, 3, '新机身号为首次入库');
select is((select stock_qty from v_model_stock where id = :'m'), 3, '入库 3 台后库存增加 3');
select ok((:'r1'::jsonb ->> 'record_no') ~ '^RK\d{8}-\d{3,}$', '生成入库单号');

-- 同一请求编号重复提交，库存只增加一次
select stock_in(:'m', array['1','2','3'], 3, '60000000-0000-0000-0000-000000000001') as r2 \gset
select is((select stock_qty from v_model_stock where id = :'m'), 3, '重复提交库存只增加一次');
select is(:'r2'::jsonb ->> 'record_no', :'r1'::jsonb ->> 'record_no', '重复提交返回上次结果');

-- ---------------------------------------------------------------- 已在库拒绝，且整批不入库
select throws_ok(format($$select stock_in(%L, array['4','2','5'], 3, gen_random_uuid())$$, :'m'),
  'P0001', '机身号 2 已在库，不能重复入库', '已在库的机身号被拒绝并指出机身号');
select is((select count(*)::int from units where model_id = :'m'), 3, '任何一个不合格，整批都不入库');

-- ---------------------------------------------------------------- 重新入库
insert into dealers (id, company_name, contact_name, phone)
  values ('30000000-0000-0000-0000-000000000001', '甲公司', '张三', '1');
insert into outbound_orders (id, order_no, dealer_id, status, shipped_at)
  values ('40000000-0000-0000-0000-000000000001', 'CK-T-1', '30000000-0000-0000-0000-000000000001',
          'completed', now());
insert into outbound_items (order_id, unit_id, model_id, barcode, serial_no, default_price, actual_price,
                            warranty_start, warranty_end)
  select '40000000-0000-0000-0000-000000000001', id, model_id, barcode, serial_no, 1, 1, now(), current_date + 365
  from units where model_id = :'m' and serial_no = '1';
update units set status = 'shipped', last_out_at = now() where model_id = :'m' and serial_no = '1';

select stock_in(:'m', array['1','6'], 2, gen_random_uuid()) as r3 \gset
select is((:'r3'::jsonb ->> 'restock_count')::int, 1, '已出库机身号为重新入库');
select is((:'r3'::jsonb ->> 'first_count')::int, 1, '同批次的新机身号为首次入库');
select is((select status from units where model_id = :'m' and serial_no = '1'), 'in_stock', '恢复在库');
select is((select stock_qty from v_model_stock where id = :'m'), 4, '库存 2 → 4（重新入库 +1、首次入库 +1）');
select is((select count(*)::int from outbound_items i join units u on u.id = i.unit_id
            where u.model_id = :'m' and u.serial_no = '1' and i.warranty_end is not null),
  1, '重新入库后原出库与保修记录仍在');
select is((select array_agg(in_type order by record_no)::text from stock_in_records
            where model_id = :'m' and serial_no = '1'),
  '{first,restock}', '入库流水保留每一次入库');

-- ---------------------------------------------------------------- request_keys 清理
insert into request_keys (request_id, function_name, result, created_at)
  values ('70000000-0000-0000-0000-000000000001', 'stock_in', '{}', now() - interval '31 days');
select stock_in(:'m', array['7'], 1, gen_random_uuid());
select is((select count(*)::int from request_keys where request_id = '70000000-0000-0000-0000-000000000001'),
  0, '30 天前的请求编号被自动清理');

select * from finish();
rollback;
