-- Issue #27 出库订单编辑、#28 确认出库、#29 撤销出库
begin;
create extension if not exists pgtap with schema extensions;
-- 在本事务内清空业务数据（结束时回滚），测试不受 seed.sql 或其他数据影响
truncate audit_logs, outbound_items, outbound_orders, stock_in_records, units,
         dealer_prices, dealer_addresses, dealers, product_models, request_keys, doc_counters;
select plan(73);

-- 准备：两个型号各 5 台在库；经销商甲有两个地址、两个型号的价格
select create_model('功放', '4.4 AMP', 'BC-A', null, null, 5, array['1','2','3','4','5']) ->> 'model_id' as ma \gset
select create_model('音箱', 'SPK', 'BC-B', null, null, 5, array['1','2','3','4','5']) ->> 'model_id' as mb \gset
select create_model('耳机', 'HP', 'BC-C', null, null, 1, array['9']) ->> 'model_id' as mc \gset
select create_dealer('甲公司', '张三', '138',
  '[{"label":"公司","address":"上海市 1 号","is_default":true},{"label":"仓库","address":"上海市 2 号"}]') ->> 'dealer_id' as d \gset
select id as addr1 from dealer_addresses where dealer_id = :'d' and is_default \gset
select id as addr2 from dealer_addresses where dealer_id = :'d' and not is_default \gset
select set_dealer_price(:'d', :'ma', 100);
select set_dealer_price(:'d', :'mb', 50.5);
select create_dealer('乙公司', '李四', '139', '[{"address":"北京市"}]') ->> 'dealer_id' as d2 \gset
select id as d2addr from dealer_addresses where dealer_id = :'d2' \gset

-- ================================================================ create_order
select set_dealer_active(:'d2', false);
select throws_ok(format($$select create_order(%L)$$, :'d2'),
  'P0001', '经销商「乙公司」已停用，不能新建出库订单', '停用的经销商不能新建订单');
select set_dealer_active(:'d2', true);
select throws_ok(format($$select create_order(%L, %L)$$, :'d', :'d2addr'),
  'P0001', '收货地址不属于该经销商', '地址必须属于该经销商');

select create_order(:'d') as r \gset
select :'r'::jsonb ->> 'order_id' as o \gset
select ok((:'r'::jsonb ->> 'order_no') ~ '^CK\d{8}-\d{3,}$', '生成出库单号');
select is((select status from outbound_orders where id = :'o'), 'draft', '新订单状态为编辑中');
select is((select address_id::text from outbound_orders where id = :'o'), :'addr1', '自动选择默认地址');

select create_order(:'d', :'addr2') ->> 'order_id' as o_addr2 \gset
select is((select address_id::text from outbound_orders where id = :'o_addr2'), :'addr2', '可以选择其他有效地址');

select create_order(:'d', null, '81000000-0000-0000-0000-000000000001');
select create_order(:'d', null, '81000000-0000-0000-0000-000000000001');
select is((select count(*)::int from request_keys where request_id = '81000000-0000-0000-0000-000000000001'), 1,
  '同一请求编号只创建一张订单');

-- ================================================================ add_order_item
select add_order_item(:'o', :'ma', '1') ->> 'id' as i1 \gset
select is((select row(default_price, actual_price)::text from outbound_items where id = :'i1'),
  '(100.00,100.00)', '扫描后自动填写经销商单价（默认单价 = 实际单价）');
select is((select barcode from outbound_items where id = :'i1'), 'BC-A', '明细保存产品条码');

select throws_ok(format($$select add_order_item(%L, %L, '1')$$, :'o', :'ma'),
  'P0001', '机身号 1 已在本订单中', '同一机身号不能在一张订单中重复出现');
select throws_ok(format($$select add_order_item(%L, %L, '99')$$, :'o', :'ma'),
  'P0001', '「功放 4.4 AMP」下没有机身号 99 的产品，请先入库', '机身号不存在');
select throws_ok(format($$select add_order_item(%L, %L, '9')$$, :'o', :'ma'),
  'P0001', '机身号 9 不属于「功放 4.4 AMP」，请确认扫描的产品条码是否正确', '型号与机身号必须匹配');
select throws_ok(format($$select add_order_item(%L, %L, '9')$$, :'o', :'mc'),
  'P0001', '当前经销商尚未设置该型号的价格，请先填写单价', '经销商没有该型号价格时返回明确提示');
select throws_ok(format($$select add_order_item(%L, %L, ' ')$$, :'o', :'ma'),
  'P0001', '机身号不能为空', '机身号不能为空');

select set_model_active(:'mc', false);
select set_dealer_price(:'d', :'mc', 1);
select throws_ok(format($$select add_order_item(%L, %L, '9')$$, :'o', :'mc'),
  'P0001', '「耳机 HP」已停用，不能出库', '停用的型号不能出库');
select set_model_active(:'mc', true);

-- 多台相同和不同型号
select add_order_item(:'o', :'ma', '2');
select add_order_item(:'o', :'mb', '1') ->> 'id' as ib1 \gset
select is((select count(*)::int from outbound_items where order_id = :'o'), 3, '一张订单可以扫入多台相同和不同型号');
select is((select products_amount from v_order_summary where id = :'o'), 250.50::numeric, '编辑中订单实时计算金额');

-- ================================================================ 删除明细不改运费
select update_order(:'o', :'addr1', 15);
select remove_order_item(:'ib1');
select is((select count(*)::int from outbound_items where order_id = :'o'), 2, '可以删除单条明细');
select is((select shipping_fee from outbound_orders where id = :'o'), 15.00::numeric, '删除产品不改运费');

-- ================================================================ update_order
select throws_ok(format($$select update_order(%L, %L, -1)$$, :'o', :'addr1'),
  'P0001', '运费不能为负数', '运费不能为负');
select throws_ok(format($$select update_order(%L, %L, 1.234)$$, :'o', :'addr1'),
  'P0001', '运费最多保留两位小数', '运费最多两位小数');
select throws_ok(format($$select update_order(%L, %L, 1)$$, :'o', :'d2addr'),
  'P0001', '收货地址不属于该经销商', '只能改为该经销商的地址');
select update_order(:'o', :'addr2', 20, ' 备注 ');
select is((select row(address_id, shipping_fee, note)::text from outbound_orders where id = :'o'),
  format('(%s,20.00,备注)', :'addr2'), '可以修改地址、运费、备注');
select is((select count(*)::int from audit_logs where action = 'order.fee_change' and order_id = :'o'), 2,
  '修改运费写入操作记录');

-- ================================================================ 改价规则
select throws_ok(format($$select set_order_item_price(%L, 0)$$, :'i1'),
  'P0001', '多台订单不能修改实际单价', '2 台以上的订单改价被拒绝');

select create_order(:'d') ->> 'order_id' as os \gset
select add_order_item(:'os', :'ma', '3') ->> 'id' as is1 \gset
select set_order_item_price(:'is1', 0);
select is((select row(default_price, actual_price)::text from outbound_items where id = :'is1'),
  '(100.00,0.00)', '单台订单可以把实际单价改为 0');
select is((select price from dealer_prices where dealer_id = :'d' and model_id = :'ma' and active), 100.00::numeric,
  '改价不影响经销商默认价格');
select is((select count(*)::int from audit_logs where action = 'order.price_change' and order_id = :'os'), 1,
  '修改订单价格写入操作记录');
select throws_ok(format($$select set_order_item_price(%L, -1)$$, :'is1'),
  'P0001', '实际单价不能为负数', '实际单价不能为负');

select throws_ok(format($$select add_order_item(%L, %L, '4')$$, :'os', :'ma'),
  'P0001', '多台订单不能改价，已改的价格将恢复为默认单价', '已改价的单台订单加入第 2 台需要确认');
select add_order_item(:'os', :'ma', '4', true);
select is((select array_agg(actual_price order by serial_no)::text from outbound_items where order_id = :'os'),
  '{100.00,100.00}', '确认后加入第 2 台，已改价格恢复为默认单价');

-- 绕过函数直接改坏价格：confirm_order 再次校验
update outbound_items set actual_price = 1 where id = :'is1';
update outbound_orders set shipping_fee = 0 where id = :'os';
select throws_ok(format($$select confirm_order(%L, gen_random_uuid())$$, :'os'),
  'P0001', '多台订单不能改价，实际单价必须等于默认单价', 'confirm_order 再次校验多台订单单价');
update outbound_items set actual_price = default_price where id = :'is1';

-- ================================================================ confirm_order 校验
select create_order(:'d') ->> 'order_id' as oe \gset
select throws_ok(format($$select confirm_order(%L, gen_random_uuid())$$, :'oe'),
  'P0001', '订单中至少要有一台产品', '至少一台产品');
select add_order_item(:'oe', :'mb', '2');
select throws_ok(format($$select confirm_order(%L, gen_random_uuid())$$, :'oe'),
  'P0001', '请填写运费（没有运费填 0）', '运费留空时不能确认出库');
select throws_ok(format($$select confirm_order(%L, null)$$, :'oe'),
  'P0001', '缺少请求编号', '必须提供请求编号');

-- ================================================================ confirm_order 成功
select stock_qty as qa_before from v_model_stock where id = :'ma' \gset
select confirm_order(:'o', '82000000-0000-0000-0000-000000000001') as c1 \gset
select is((select status from outbound_orders where id = :'o'), 'completed', '确认后订单为已完成');
select is((select stock_qty from v_model_stock where id = :'ma'), :qa_before - 2, '确认后库存正确扣减');
select is((select array_agg(status order by serial_no)::text from units where model_id = :'ma' and serial_no in ('1','2')),
  '{shipped,shipped}', '产品状态改为已出库');
select is((select row(products_amount, shipping_fee, total_amount)::text from outbound_orders where id = :'o'),
  '(200.00,20.00,220.00)', '保存产品金额合计、运费、订单总金额');
select is((select row(dealer_name, contact_name, phone, address_text)::text from outbound_orders where id = :'o'),
  '(甲公司,张三,138,"上海市 2 号")', '保存经销商、联系人、电话、地址快照');
select is((select count(*)::int from outbound_items
            where order_id = :'o' and warranty_start = (select shipped_at from outbound_orders where id = :'o')
              and warranty_end = ((warranty_start at time zone 'Asia/Shanghai')::date + interval '1 year')::date),
  2, '每台产品写入保修起止时间（出库日加一年）');
select is((select last_out_at from units where model_id = :'ma' and serial_no = '1'),
  (select shipped_at from outbound_orders where id = :'o'), '记录产品最近出库时间');
select is((select count(*)::int from audit_logs where action = 'order.confirm' and order_id = :'o'), 1,
  '确认出库写入操作记录');

-- 同一请求编号再次提交：返回上次结果，库存不再扣减
select confirm_order(:'o', '82000000-0000-0000-0000-000000000001') as c2 \gset
select is(:'c2'::jsonb ->> 'order_no', :'c1'::jsonb ->> 'order_no', '同一请求编号返回上次结果');
select is((:'c2'::jsonb ->> 'duplicate')::boolean, true, '标记为重复请求');
select is((select stock_qty from v_model_stock where id = :'ma'), :qa_before - 2, '同一请求编号提交两次，库存只扣一次');
select throws_ok(format($$select confirm_order(%L, gen_random_uuid())$$, :'o'),
  'P0001', format('订单 %s 已确认出库，不能修改', :'c1'::jsonb ->> 'order_no'), '已完成订单不能再次确认');
select throws_ok(format($$select add_order_item(%L, %L, '5')$$, :'o', :'ma'),
  'P0001', format('订单 %s 已确认出库，不能修改', :'c1'::jsonb ->> 'order_no'), '已完成订单不能修改');

-- 修改经销商资料和地址后，已完成订单不变
select update_dealer(:'d', '甲公司（改名）', '王五', '000', true);
select update_dealer_address(:'addr2', '仓库', '上海市 2 号（已搬迁）', true);
select set_dealer_price(:'d', :'ma', 999);
select is((select row(dealer_name, contact_name, phone, address_text)::text from v_order_summary where id = :'o'),
  '(甲公司,张三,138,"上海市 2 号")', '修改经销商地址后，已完成订单的地址不变');
select is((select total_amount from v_order_summary where id = :'o'), 220.00::numeric, '修改价格后，历史订单金额不变');

-- ================================================================ 已出库产品不能加入订单
select throws_ok(format($$select add_order_item(%L, %L, '1')$$, :'oe', :'ma'),
  'P0001', format('机身号 1 已出库（订单 %s），不能重复出库', :'c1'::jsonb ->> 'order_no'), '已出库产品不能加入订单');

-- ================================================================ 任一产品不在库：整张订单失败，库存不变
-- 两张草稿订单含同一台产品：先确认的成功，后确认的整单失败
select create_order(:'d') ->> 'order_id' as ox \gset
select create_order(:'d') ->> 'order_id' as oy \gset
select add_order_item(:'ox', :'mb', '3');
select add_order_item(:'oy', :'mb', '4');
select add_order_item(:'oy', :'mb', '3');
select update_order(:'ox', :'addr1', 0);
select update_order(:'oy', :'addr1', 0);
select confirm_order(:'ox', gen_random_uuid());
select stock_qty as qb_before from v_model_stock where id = :'mb' \gset
select throws_ok(format($$select confirm_order(%L, gen_random_uuid())$$, :'oy'),
  'P0001', '以下产品不能出库：机身号 3（音箱 SPK）已出库', '失败时指出哪台产品、什么问题');
select is((select stock_qty from v_model_stock where id = :'mb'), :qb_before, '任一产品不在库时，库存完全不变');
select is((select status from units where model_id = :'mb' and serial_no = '4'), 'in_stock', '订单中其他产品仍在库');
select is((select status from outbound_orders where id = :'oy'), 'draft', '失败的订单仍为编辑中，可以继续修改');

-- ================================================================ 单台改价为 0 后确认，保修正常
select create_order(:'d') ->> 'order_id' as oz \gset
select add_order_item(:'oz', :'mb', '5') ->> 'id' as iz \gset
select set_order_item_price(:'iz', 0);
select update_order(:'oz', :'addr1', 0);
select confirm_order(:'oz', gen_random_uuid());
select is((select row(products_amount, total_amount)::text from outbound_orders where id = :'oz'),
  '(0.00,0.00)', '单台订单改为 0 后可以确认出库');
select ok((select warranty_end is not null from outbound_items where id = :'iz'), '补发产品保修正常计算');

-- ================================================================ cancel_order
select throws_ok(format($$select cancel_order(%L, ' ')$$, :'o'),
  'P0001', '请填写撤销原因', '撤销原因必填');
select cancel_order(:'o', '经销商退单', '83000000-0000-0000-0000-000000000001');
select is((select row(status, cancel_reason, cancelled_at is not null)::text from outbound_orders where id = :'o'),
  '(cancelled,经销商退单,t)', '订单为已撤销，记录撤销时间和原因');
select is((select stock_qty from v_model_stock where id = :'ma'), :qa_before, '撤销后库存恢复');
select is((select last_out_at from units where model_id = :'ma' and serial_no = '1'), null, '撤销后最近出库时间恢复');
select is((select row(products_amount, shipping_fee, total_amount)::text from outbound_orders where id = :'o'),
  '(200.00,20.00,220.00)', '订单仍在历史中，金额和运费保留');
select is((select count(*)::int from audit_logs where action = 'order.cancel' and order_id = :'o'), 1,
  '撤销写入操作记录');
select cancel_order(:'o', '经销商退单', '83000000-0000-0000-0000-000000000001');
select is((select stock_qty from v_model_stock where id = :'ma'), :qa_before, '同一请求编号重复撤销，库存只恢复一次');
select throws_ok(format($$select cancel_order(%L, 'x')$$, :'o'),
  'P0001', format('订单 %s 已撤销', :'c1'::jsonb ->> 'order_no'), '已撤销订单不能再次撤销');

-- 重新入库之后不能撤销原订单（否则库存会被重复恢复）
select stock_in(:'mb', array['3'], 1, gen_random_uuid());
select throws_ok(format($$select cancel_order(%L, 'x')$$, :'ox'),
  'P0001', '机身号 3 在本次出库之后已重新入库，不能撤销该订单', '产品已重新入库时不能撤销');
-- 重新入库后又被另一张订单出库：产品状态又是已出库，原订单仍不能撤销
select create_order(:'d') ->> 'order_id' as ow \gset
select add_order_item(:'ow', :'mb', '3');
select update_order(:'ow', :'addr1', 0);
select confirm_order(:'ow', gen_random_uuid());
select is((select last_out_order_id::text from units where model_id = :'mb' and serial_no = '3'), :'ow',
  '记录最近一次出库的订单');
select throws_ok(format($$select cancel_order(%L, 'x')$$, :'ox'),
  'P0001', '机身号 3 在本次出库之后已重新入库，不能撤销该订单', '重新入库后被其他订单出库，原订单仍不能撤销');
select cancel_order(:'ow', '测试');
select is((select row(status, last_out_order_id)::text from units where model_id = :'mb' and serial_no = '3'),
  '(in_stock,)', '撤销最近的订单后产品恢复在库');

-- 金额合计超出范围：给出业务错误而不是数据库溢出
select set_dealer_price(:'d', :'mb', 6000000000);
select create_order(:'d') ->> 'order_id' as obig \gset
select add_order_item(:'obig', :'mb', '3');
select add_order_item(:'obig', :'mb', '1');
select update_order(:'obig', :'addr1', 0);
select throws_ok(format($$select confirm_order(%L, gen_random_uuid())$$, :'obig'),
  'P0001', '订单金额合计超出范围', '订单金额合计超出范围时不能确认');

-- 编辑中的订单可以作废，不影响库存
select stock_qty as qb2 from v_model_stock where id = :'mb' \gset
select cancel_order(:'oy', '录错了');
select is((select status from outbound_orders where id = :'oy'), 'cancelled', '编辑中的订单可以作废');
select is((select stock_qty from v_model_stock where id = :'mb'), :qb2, '作废编辑中的订单不影响库存');

-- ================================================================ 权限
select ok(
  not has_function_privilege('anon', 'public.confirm_order(uuid, uuid)', 'execute')
  and not has_function_privilege('anon', 'public.cancel_order(uuid, text, uuid)', 'execute')
  and has_function_privilege('authenticated', 'public.confirm_order(uuid, uuid)', 'execute')
  and not has_function_privilege('authenticated', 'public._lock_draft_order(uuid)', 'execute')
  and not has_table_privilege('anon', 'public.v_order_summary', 'select')
  and has_table_privilege('authenticated', 'public.v_order_summary', 'select'),
  '订单函数和视图只开放给已登录用户');

select * from finish();
rollback;
