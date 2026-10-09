-- Issue #3：违反每一条唯一约束的插入都会被拒绝
begin;
create extension if not exists pgtap with schema extensions;
-- 在本事务内清空业务数据（结束时回滚），测试不受 seed.sql 或其他数据影响
truncate audit_logs, outbound_items, outbound_orders, stock_in_records, units,
         dealer_prices, dealer_addresses, dealers, product_models, request_keys, doc_counters;
select plan(17);

-- 准备数据
insert into product_models (id, name, model, barcode) values
  ('10000000-0000-0000-0000-000000000001', '功放', '4.4 AMP', 'BC-001'),
  ('10000000-0000-0000-0000-000000000002', '功放', '6.6 AMP', 'BC-002');
insert into units (id, model_id, barcode, serial_no) values
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'BC-001', '187');
insert into dealers (id, company_name, contact_name, phone) values
  ('30000000-0000-0000-0000-000000000001', '甲公司', '张三', '13800000000');
insert into dealer_addresses (dealer_id, address, is_default) values
  ('30000000-0000-0000-0000-000000000001', '上海市一号', true);
insert into dealer_prices (dealer_id, model_id, price) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 100.00);
insert into outbound_orders (id, order_no, dealer_id) values
  ('40000000-0000-0000-0000-000000000001', 'CK20260927-001', '30000000-0000-0000-0000-000000000001');
insert into outbound_items (order_id, unit_id, model_id, barcode, serial_no, default_price, actual_price) values
  ('40000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-000000000001', 'BC-001', '187', 100, 100);

-- 产品条码唯一
select throws_ok(
  $$insert into product_models (name, model, barcode) values ('x', 'y', 'BC-001')$$,
  '23505', null, '重复产品条码被拒绝');

-- （型号, 机身号）唯一；不同型号可以有相同机身号
select throws_ok(
  $$insert into units (model_id, barcode, serial_no) values ('10000000-0000-0000-0000-000000000001', 'BC-001', '187')$$,
  '23505', null, '同型号重复机身号被拒绝');
select lives_ok(
  $$insert into units (model_id, barcode, serial_no) values ('10000000-0000-0000-0000-000000000002', 'BC-002', '187')$$,
  '不同型号可以使用相同机身号');

-- 经销商公司名称唯一
select throws_ok(
  $$insert into dealers (company_name, contact_name, phone) values ('甲公司', '李四', '1')$$,
  '23505', null, '重复经销商公司名称被拒绝');

-- 每个经销商最多一个默认地址
select throws_ok(
  $$insert into dealer_addresses (dealer_id, address, is_default) values ('30000000-0000-0000-0000-000000000001', '二号', true)$$,
  '23505', null, '第二个默认地址被拒绝');
select lives_ok(
  $$insert into dealer_addresses (dealer_id, address, is_default) values ('30000000-0000-0000-0000-000000000001', '三号', false)$$,
  '可以有多个非默认地址');

-- （经销商, 型号）只有一个有效价格
select throws_ok(
  $$insert into dealer_prices (dealer_id, model_id, price) values ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 120)$$,
  '23505', null, '第二个有效价格被拒绝');
select lives_ok(
  $$insert into dealer_prices (dealer_id, model_id, price, active) values ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 90, false)$$,
  '停用的历史价格可以保留多条');

-- （订单, 产品）唯一
select throws_ok(
  $$insert into outbound_items (order_id, unit_id, model_id, barcode, serial_no, default_price, actual_price)
    values ('40000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
            '10000000-0000-0000-0000-000000000001', 'BC-001', '187', 100, 100)$$,
  '23505', null, '同一订单重复机身号被拒绝');

-- 出库单号唯一
select throws_ok(
  $$insert into outbound_orders (order_no, dealer_id) values ('CK20260927-001', '30000000-0000-0000-0000-000000000001')$$,
  '23505', null, '重复出库单号被拒绝');

-- 金额不能为负
select throws_ok(
  $$insert into dealer_prices (dealer_id, model_id, price) values ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002', -1)$$,
  '23514', null, '负数单价被拒绝');
select throws_ok(
  $$update outbound_orders set shipping_fee = -0.01 where id = '40000000-0000-0000-0000-000000000001'$$,
  '23514', null, '负数运费被拒绝');

-- 金额两位小数
select is(
  (select price from dealer_prices where active and model_id = '10000000-0000-0000-0000-000000000001'),
  100.00::numeric(12,2), '金额保存为两位小数');
select is(
  (select numeric_scale from information_schema.columns
    where table_name = 'outbound_orders' and column_name = 'shipping_fee')::int,
  2, '运费为 numeric(12,2)');

-- 有业务记录的数据不能物理删除
select throws_ok(
  $$delete from product_models where id = '10000000-0000-0000-0000-000000000001'$$,
  '23503', null, '有单台产品的型号不能物理删除');
select throws_ok(
  $$delete from units where id = '20000000-0000-0000-0000-000000000001'$$,
  '23503', null, '有出库明细的单台产品不能物理删除');

-- 数据库时区
select is(current_setting('timezone'), 'Asia/Shanghai', '数据库时区为 Asia/Shanghai');

select * from finish();
rollback;
