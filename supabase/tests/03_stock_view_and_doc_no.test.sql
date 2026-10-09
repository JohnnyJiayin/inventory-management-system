-- Issue #5：库存视图与单号生成；Issue #8：ping() 更新 heartbeat
begin;
create extension if not exists pgtap with schema extensions;
-- 在本事务内清空业务数据（结束时回滚），测试不受 seed.sql 或其他数据影响
truncate audit_logs, outbound_items, outbound_orders, stock_in_records, units,
         dealer_prices, dealer_addresses, dealers, product_models, request_keys, doc_counters;
select plan(14);

-- ---------------------------------------------------------------- 单号
select is(next_doc_no('RK', '2026-09-27 10:00+08'), 'RK20260927-001', '入库单号当日从 001 开始');
select is(next_doc_no('RK', '2026-09-27 23:59+08'), 'RK20260927-002', '入库单号当日递增');
select is(next_doc_no('CK', '2026-09-27 10:00+08'), 'CK20260927-001', '出库单号独立计数');
select is(next_doc_no('RK', '2026-09-28 00:00+08'), 'RK20260928-001', '跨日从 001 重新开始');
-- 北京时间 9/28 00:30 = UTC 9/27 16:30，日期必须按北京时间
select is(next_doc_no('CK', '2026-09-27 16:30+00'), 'CK20260928-001', '日期按北京时间计算');
update doc_counters set last_no = 999 where prefix = 'RK' and day = '2026-09-28';
select is(next_doc_no('RK', '2026-09-28 12:00+08'), 'RK20260928-1000', '超过 999 不截断');
select throws_ok($$select next_doc_no('XX')$$, 'P0001', null, '未知前缀被拒绝');

-- ---------------------------------------------------------------- 库存视图
insert into product_models (id, name, model, barcode) values
  ('10000000-0000-0000-0000-000000000001', '功放', '4.4 AMP', 'BC-001'),
  ('10000000-0000-0000-0000-000000000002', '功放', '6.6 AMP', 'BC-002');

select is(
  (select row(stock_qty, total_in, total_out, has_records)::text from v_model_stock
    where id = '10000000-0000-0000-0000-000000000001'),
  '(0,0,0,f)', '新型号库存为 0，无记录');

select stock_in('10000000-0000-0000-0000-000000000001', array['1', '2', '3'], 3, gen_random_uuid());

-- 模拟一次已完成的出库（出库业务函数在 Sprint 2 实现）
insert into dealers (id, company_name, contact_name, phone)
  values ('30000000-0000-0000-0000-000000000001', '甲公司', '张三', '1');
insert into outbound_orders (id, order_no, dealer_id, status, shipped_at)
  values ('40000000-0000-0000-0000-000000000001', 'CK-T-1', '30000000-0000-0000-0000-000000000001',
          'completed', '2026-09-30 10:00+08');
insert into outbound_items (order_id, unit_id, model_id, barcode, serial_no, default_price, actual_price)
  select '40000000-0000-0000-0000-000000000001', id, model_id, barcode, serial_no, 1, 1
  from units where serial_no = '1';
update units set status = 'shipped' where serial_no = '1';

-- 已撤销订单不计入累计出库
insert into outbound_orders (id, order_no, dealer_id, status, shipped_at)
  values ('40000000-0000-0000-0000-000000000002', 'CK-T-2', '30000000-0000-0000-0000-000000000001',
          'cancelled', '2026-10-01 10:00+08');
insert into outbound_items (order_id, unit_id, model_id, barcode, serial_no, default_price, actual_price)
  select '40000000-0000-0000-0000-000000000002', id, model_id, barcode, serial_no, 1, 1
  from units where serial_no = '2';

select is(
  (select row(stock_qty, total_in, total_out, has_records)::text from v_model_stock
    where id = '10000000-0000-0000-0000-000000000001'),
  '(2,3,1,t)', '在库 2、累计入库 3、累计有效出库 1');
select is(
  (select last_out_at from v_model_stock where id = '10000000-0000-0000-0000-000000000001'),
  '2026-09-30 10:00+08'::timestamptz, '最近出库时间只算有效订单');
select ok(
  (select last_in_at is not null from v_model_stock where id = '10000000-0000-0000-0000-000000000001'),
  '最近入库时间有值');
select is(
  (select bool_and(v.stock_qty = (select count(*) from units u where u.model_id = v.id and u.status = 'in_stock'))
     from v_model_stock v),
  true, '库存数量始终等于在库单台产品数量');

-- ---------------------------------------------------------------- ping
update heartbeat set pinged_at = '2000-01-01';
select ping();
select ok((select pinged_at > now() - interval '1 minute' from heartbeat), 'ping() 更新 heartbeat 时间');
select is((select count(*)::int from heartbeat), 1, 'heartbeat 只有一行');

select * from finish();
rollback;
