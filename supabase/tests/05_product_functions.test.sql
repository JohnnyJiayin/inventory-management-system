-- Issue #14：create_model / update_model / delete_model / 停用
begin;
create extension if not exists pgtap with schema extensions;
-- 在本事务内清空业务数据（结束时回滚），测试不受 seed.sql 或其他数据影响
truncate audit_logs, outbound_items, outbound_orders, stock_in_records, units,
         dealer_prices, dealer_addresses, dealers, product_models, request_keys, doc_counters;
select plan(20);

-- ---------------------------------------------------------------- create_model
select throws_ok(
  $$select create_model('功放', '4.4 AMP', 'BC-001', null, null, 10,
                        array['1','2','3','4','5','6','7','8','9'])$$,
  'P0001', '初始数量为 10，但录入了 9 个机身号，两者必须一致',
  '初始数量 10 但只有 9 个机身号时拒绝');
select is((select count(*)::int from product_models), 0, '拒绝后型号未创建（事务回滚）');

select throws_ok(
  $$select create_model('功放', '4.4 AMP', 'BC-001', null, null, 2, array['1', ' 1 '])$$,
  'P0001', '机身号 1 在本次清单中重复', '机身号列表内重复被拒绝');
select throws_ok($$select create_model('', '4.4 AMP', 'BC-001')$$, 'P0001', '请填写产品名称', '名称必填');
select throws_ok($$select create_model('功放', ' ', 'BC-001')$$, 'P0001', '请填写产品型号', '型号必填');
select throws_ok($$select create_model('功放', '4.4', '')$$, 'P0001', '请扫描或填写产品条码', '条码必填');
select throws_ok($$select create_model('功放', '4.4', 'X', null, null, -1, '{}')$$,
  'P0001', '初始数量必须是大于或等于 0 的整数', '负数初始数量被拒绝');

select create_model('功放', '4.4 AMP', 'BC-001', '说明', null, 10,
                    array['1','2','3','4','5','6','7','8','9','10']) ->> 'model_id' as m1 \gset
select is((select stock_qty from v_model_stock where id = :'m1'), 10, '初始数量 10 → 库存 10');
select is((select count(*)::int from stock_in_records where model_id = :'m1' and in_type = 'first'),
  10, '同时生成首次入库记录');
select is((select count(distinct record_no)::int from stock_in_records where model_id = :'m1'),
  1, '同一批次共用一个入库单号');

select create_model('无库存', 'ZERO', 'BC-000') ->> 'model_id' as m0 \gset
select is((select row(stock_qty, has_records)::text from v_model_stock where id = :'m0'),
  '(0,f)', '可以不填初始数量、不上传照片完成建档');

select throws_ok($$select create_model('别的', 'Y', 'BC-001')$$,
  'P0001', '产品条码 BC-001 已被型号「功放 4.4 AMP」使用', '重复产品条码拒绝');

-- 请求编号防重复
select create_model('防重', 'R', 'BC-R', null, null, 0, '{}', '50000000-0000-0000-0000-000000000001');
select create_model('防重', 'R', 'BC-R', null, null, 0, '{}', '50000000-0000-0000-0000-000000000001');
select is((select count(*)::int from product_models where barcode = 'BC-R'), 1, '同一请求编号只创建一次');

-- ---------------------------------------------------------------- update_model
select throws_ok(
  format($$select update_model(%L, '无库存', 'ZERO', 'BC-001', null, null, true)$$, :'m0'),
  'P0001', '产品条码 BC-001 已被型号「功放 4.4 AMP」使用', '修改为重复条码被拒绝');
select update_model(:'m0', '改名', 'ZERO-2', 'BC-000', '新说明', 'p/a.jpg', true);
select is((select row(name, model, description, photo_path)::text from product_models where id = :'m0'),
  '(改名,ZERO-2,新说明,p/a.jpg)', '可以修改名称、型号、说明、照片');

-- ---------------------------------------------------------------- 删除与停用
select throws_ok(format('select delete_model(%L)', :'m1'),
  'P0001', '该型号已有出入库记录，不能删除，只能停用', '有记录的型号删除被拒绝');

select set_model_active(:'m1', false);
select is((select active from product_models where id = :'m1'), false, '有记录的型号可以停用');
select throws_ok(format($$select stock_in(%L, array['99'], 1, gen_random_uuid())$$, :'m1'),
  'P0001', '该产品型号已停用，不能入库', '停用型号不能入库');
select is((select count(*)::int from stock_in_records where model_id = :'m1'), 10, '停用后历史仍可查询');

select delete_model(:'m0');
select is((select count(*)::int from product_models where id = :'m0'), 0, '无记录的型号可以删除');

select * from finish();
rollback;
