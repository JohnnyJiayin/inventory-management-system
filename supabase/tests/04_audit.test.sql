-- Issue #6：修改产品、经销商、地址、价格后，audit_logs 有对应记录且包含修改前后内容
begin;
create extension if not exists pgtap with schema extensions;
-- 在本事务内清空业务数据（结束时回滚），测试不受 seed.sql 或其他数据影响
truncate audit_logs, outbound_items, outbound_orders, stock_in_records, units,
         dealer_prices, dealer_addresses, dealers, product_models, request_keys, doc_counters;
select plan(16);

set local request.jwt.claims to '{"sub":"00000000-0000-0000-0000-0000000000aa","role":"authenticated"}';

-- 产品：新增 / 修改 / 修改条码
select create_model('功放', '4.4 AMP', 'BC-001') ->> 'model_id' as model_id \gset
select is(
  (select count(*)::int from audit_logs where action = 'product.create' and model_id = :'model_id'),
  1, '添加产品有记录');

select update_model(:'model_id', '功放 Pro', '4.4 AMP', 'BC-001', null, null, true);
select is(
  (select row(before ->> 'name', after ->> 'name')::text from audit_logs
    where action = 'product.update' and model_id = :'model_id'),
  '(功放,"功放 Pro")', '修改产品记录修改前后内容');

select bind_barcode(:'model_id', 'BC-NEW');
select is(
  (select row(before ->> 'barcode', after ->> 'barcode')::text from audit_logs
    where action = 'product.barcode_change' and model_id = :'model_id'),
  '(BC-001,BC-NEW)', '修改产品条码单独记录');
select is(
  (select actor::text from audit_logs where action = 'product.barcode_change'),
  '00000000-0000-0000-0000-0000000000aa', '记录操作人');

-- 没有实际变化的更新不记录
select update_model(:'model_id', '功放 Pro', '4.4 AMP', 'BC-NEW', null, null, true);
select is((select count(*)::int from audit_logs where model_id = :'model_id' and table_name = 'product_models'),
  3, '无变化的修改不产生记录');

-- 入库：首次入库 / 重新入库
select stock_in(:'model_id', array['1', '2'], 2, gen_random_uuid());
select is((select count(*)::int from audit_logs where action = 'stock_in.first'), 2, '首次入库每台一条记录');
update units set status = 'shipped' where serial_no = '1';
select stock_in(:'model_id', array['1'], 1, gen_random_uuid());
select is((select count(*)::int from audit_logs where action = 'stock_in.restock'), 1, '重新入库有记录');
select is((select result from audit_logs where action = 'stock_in.restock'), 'success', '记录操作结果');

-- 经销商、地址、价格（业务函数在 Sprint 2 实现，这里直接写表验证触发器）
insert into dealers (id, company_name, contact_name, phone)
  values ('30000000-0000-0000-0000-000000000001', '甲公司', '张三', '1');
update dealers set phone = '2' where id = '30000000-0000-0000-0000-000000000001';
select is(
  (select row(before ->> 'phone', after ->> 'phone')::text from audit_logs where action = 'dealer.update'),
  '(1,2)', '修改经销商记录修改前后内容');
select is((select count(*)::int from audit_logs where action = 'dealer.create'), 1, '添加经销商有记录');

insert into dealer_addresses (id, dealer_id, address)
  values ('31000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', '一号');
update dealer_addresses set address = '二号' where id = '31000000-0000-0000-0000-000000000001';
select is(
  (select row(before ->> 'address', after ->> 'address')::text from audit_logs where action = 'dealer_address.update'),
  '(一号,二号)', '修改地址记录修改前后内容');

insert into dealer_prices (id, dealer_id, model_id, price)
  values ('32000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', :'model_id', 100);
update dealer_prices set price = 88.5 where id = '32000000-0000-0000-0000-000000000001';
select is(
  (select row(before ->> 'price', after ->> 'price')::text from audit_logs where action = 'dealer_price.update'),
  '(100.00,88.50)', '修改价格记录修改前后内容');
select is(
  (select model_id::text from audit_logs where action = 'dealer_price.update'),
  :'model_id', '价格记录关联产品型号');

-- 订单：创建 / 运费 / 确认 / 撤销
insert into outbound_orders (id, order_no, dealer_id)
  values ('40000000-0000-0000-0000-000000000001', 'CK-T-1', '30000000-0000-0000-0000-000000000001');
update outbound_orders set shipping_fee = 10 where id = '40000000-0000-0000-0000-000000000001';
update outbound_orders set status = 'completed' where id = '40000000-0000-0000-0000-000000000001';
update outbound_orders set status = 'cancelled' where id = '40000000-0000-0000-0000-000000000001';
select is(
  (select array_agg(action order by id)::text from audit_logs where order_id = '40000000-0000-0000-0000-000000000001'),
  '{order.create,order.fee_change,order.confirm,order.cancel}', '订单操作依次记录');

-- 失败的操作整体回滚，不留下记录
select throws_ok($$select create_model('x', 'y', 'BC-NEW')$$, 'P0001', null, '重复条码被拒绝');
select is((select count(*)::int from audit_logs where action = 'product.create'), 1, '失败操作不写入记录');

select * from finish();
rollback;
