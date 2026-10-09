-- Issue #43：统计函数
begin;
create extension if not exists pgtap with schema extensions;
-- 在本事务内清空业务数据（结束时回滚），测试不受 seed.sql 或其他数据影响
truncate audit_logs, outbound_items, outbound_orders, stock_in_records, units,
         dealer_prices, dealer_addresses, dealers, product_models, request_keys, doc_counters;
select plan(27);

-- ---------------------------------------------------------------- 准备
-- 功放 A：8 台；音箱 B：3 台。经销商甲、乙。
select create_model('功放', 'AMP', 'BC-A', null, null, 8, array['a1','a2','a3','a4','a5','a6','a7','a8']) ->> 'model_id' as ma \gset
select create_model('音箱', 'SPK', 'BC-B', null, null, 3, array['b1','b2','b3']) ->> 'model_id' as mb \gset
select create_dealer('甲公司', '张三', '138', '[{"address":"上海市"}]') ->> 'dealer_id' as d1 \gset
select create_dealer('乙公司', '李四', '139', '[{"address":"北京市"}]') ->> 'dealer_id' as d2 \gset
select set_dealer_price(:'d1', :'ma', 100);
select set_dealer_price(:'d1', :'mb', 50);
select set_dealer_price(:'d2', :'ma', 120);
-- 入库时间：9 月入库
update stock_in_records set in_at = '2026-09-10 10:00:00+08';

create function pg_temp.ship(p_dealer uuid, p_fee numeric, p_items text[], p_at timestamptz) returns uuid
language plpgsql as $$
declare v_o uuid; v_s text;
begin
  v_o := create_order(p_dealer) ->> 'order_id';
  foreach v_s in array p_items loop
    perform add_order_item(v_o, (select model_id from units where serial_no = v_s), v_s);
  end loop;
  perform update_order(v_o, (select address_id from outbound_orders where id = v_o), p_fee);
  perform confirm_order(v_o, gen_random_uuid());
  update outbound_orders set shipped_at = p_at where id = v_o;
  return v_o;
end $$;

-- 订单 1：甲，5 台 A + 1 台 B，运费 30，9 月
select pg_temp.ship(:'d1', 30, array['a1','a2','a3','a4','a5','b1'], '2026-09-15 10:00:00+08') as o1 \gset
-- 订单 2：乙，1 台 A，运费 15。UTC 9 月 30 日 17:00 = 北京时间 10 月 1 日 01:00 → 算 10 月
select pg_temp.ship(:'d2', 15, array['a6'], '2026-09-30 17:00:00+00') as o2 \gset
-- 订单 3：甲，1 台 B，运费 0，10 月
select pg_temp.ship(:'d1', 0, array['b2'], '2026-10-05 10:00:00+08') as o3 \gset

-- ---------------------------------------------------------------- 月度统计
select is((select row(in_qty, out_qty, order_count, products_amount, shipping_fee, total_amount)::text
           from report_monthly() where month = '2026-09-01'),
  '(11,6,1,550.00,30.00,580.00)', '9 月：入库 11、出库 6、1 张订单，金额与运费正确');
select is((select shipping_fee from report_monthly('2026-09-01', '2026-09-30')),
  30.00::numeric, '一张 6 台的订单，运费只统计一次');
select is((select row(out_qty, order_count, products_amount, shipping_fee)::text
           from report_monthly() where month = '2026-10-01'),
  '(2,2,170.00,15.00)', '10 月按北京时间：UTC 9 月 30 日 17:00 的订单算 10 月');
select is((select count(*)::int from report_monthly()), 2, '每个有数据的月份一行');
select is((select in_warranty_qty from report_monthly() where month = '2026-09-01'), 6,
  '保修中数量按当前保修计算');

-- 组合筛选：经销商、型号
select is((select row(out_qty, order_count, products_amount, shipping_fee, total_amount)::text
           from report_monthly(p_dealer_id => :'d1', p_model_id => :'mb') where month = '2026-09-01'),
  '(1,1,50.00,30.00,80.00)', '按型号筛选：销售金额只算该型号，订单运费仍计一次');
select is((select in_qty from report_monthly(p_dealer_id => :'d2') where month = '2026-09-01'), 11,
  '入库数量不受经销商筛选影响');
select is((select row(out_qty, products_amount)::text from report_monthly(p_serial_no => ' a6 ') where month = '2026-10-01'),
  '(1,120.00)', '按机身号筛选');

-- ---------------------------------------------------------------- 经销商统计
select is((select row(order_count, item_count, products_amount, shipping_fee, total_amount)::text
           from report_dealers() where dealer_id = :'d1'),
  '(2,7,600.00,30.00,630.00)', '经销商甲：订单数、产品数、金额、运费');
select is((select models from report_dealers() where dealer_id = :'d1'),
  jsonb_build_array(
    jsonb_build_object('model_id', :'ma', 'model_name', '功放', 'model', 'AMP', 'qty', 5),
    jsonb_build_object('model_id', :'mb', 'model_name', '音箱', 'model', 'SPK', 'qty', 2)),
  '经销商甲：各型号出库数量');
select is((select dealer_id::text from report_dealers() limit 1), :'d1', '按订单总金额倒序');
select is((select count(*)::int from report_dealers('2026-10-01', '2026-10-31')), 2, '按日期范围筛选');

-- ---------------------------------------------------------------- 产品型号统计
select is((select row(in_qty, out_qty, stock_qty, dealer_count, products_amount)::text
           from report_models() where model_id = :'ma'),
  '(8,6,2,2,620.00)', '功放：入库、出库、库存、涉及经销商、销售金额');
select is((select row(in_qty, out_qty, stock_qty)::text
           from report_models('2026-10-01', '2026-10-31') where model_id = :'mb'),
  '(0,1,1)', '库存是当前库存，不受日期筛选影响');

-- ---------------------------------------------------------------- 运费统计
select is((select count(*)::int from report_shipping()), 3, '每张订单一行');
select is((select row(month, item_count, products_amount, shipping_fee, total_amount)::text
           from report_shipping() where order_id = :'o1'),
  '(2026-09-01,6,550.00,30.00,580.00)', '运费明细：月份、产品数量、金额、运费');
select is((select order_id::text from report_shipping() limit 1), :'o3', '按出库时间倒序');

-- ---------------------------------------------------------------- 保修统计（与保修查询页一致）
update outbound_items set warranty_end = beijing_today() + 10 where order_id = :'o3';
update outbound_items set warranty_end = beijing_today() - 1 where order_id = :'o2';
select is((select row(in_warranty_qty, expiring_qty, expired_qty, void_qty)::text from report_warranty()),
  '(7,1,1,0)', '保修中、即将过保、已过保数量');
select is((select in_warranty_qty from report_warranty()),
  (select count(*)::int from v_warranty where is_current and warranty_status = 'in_warranty'),
  '保修中数量与保修查询页一致');
select is((select out_qty from report_monthly(p_warranty_status => 'expiring') where month = '2026-10-01'), 1,
  '按保修状态筛选');

-- ---------------------------------------------------------------- 撤销订单后数字相应减少
select cancel_order(:'o1', '退单');
select is((select row(out_qty, order_count, products_amount, shipping_fee)::text
           from report_monthly() where month = '2026-09-01'),
  '(0,0,0,0)', '撤销后金额与运费不计入');
select is((select count(*)::int from report_shipping()), 2, '已撤销订单不出现在运费统计中');
select is((select row(order_count, shipping_fee)::text from report_dealers(p_order_status => 'cancelled')),
  '(1,30.00)', '筛选已撤销订单时可以单独查看');
select is((select void_qty from report_warranty(p_order_status => 'cancelled')), 6, '已撤销订单的保修为已失效');

-- ---------------------------------------------------------------- 首页
select is((dashboard_summary() ->> 'stock_qty')::int, 9, '首页：当前库存总数');
select is((dashboard_summary() ->> 'model_count')::int, 2, '首页：型号数量');

-- ---------------------------------------------------------------- 权限
select ok(
  not has_function_privilege('anon', 'public.report_monthly(date, date, uuid, uuid, text, text, text)', 'execute')
  and has_function_privilege('authenticated', 'public.report_monthly(date, date, uuid, uuid, text, text, text)', 'execute')
  and has_function_privilege('authenticated', 'public.dashboard_summary()', 'execute')
  and not has_function_privilege('anon', 'public.dashboard_summary()', 'execute')
  and not has_table_privilege('anon', 'public.v_report_items', 'select'),
  '统计函数只开放给已登录用户');

select * from finish();
rollback;
