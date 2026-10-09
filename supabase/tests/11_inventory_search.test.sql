-- Issue #40：库存多条件查询
begin;
create extension if not exists pgtap with schema extensions;
-- 在本事务内清空业务数据（结束时回滚），测试不受 seed.sql 或其他数据影响
truncate audit_logs, outbound_items, outbound_orders, stock_in_records, units,
         dealer_prices, dealer_addresses, dealers, product_models, request_keys, doc_counters;
select plan(13);

select create_model('功放', 'AMP', 'BC-A', null, null, 3, array['a1','a2','a3']) ->> 'model_id' as ma \gset
select create_model('音箱', 'SPK', 'BC-B', null, null, 2, array['b1','b2']) ->> 'model_id' as mb \gset
select create_model('耳机', 'HP', 'BC-C', null, null, 0, array[]::text[]) ->> 'model_id' as mc \gset
select create_dealer('甲公司', '张三', '138', '[{"address":"上海市"}]') ->> 'dealer_id' as d1 \gset
select create_dealer('乙公司', '李四', '139', '[{"address":"北京市"}]') ->> 'dealer_id' as d2 \gset
select set_dealer_price(:'d1', :'ma', 100);
select set_dealer_price(:'d2', :'mb', 50);
update stock_in_records set in_at = '2026-08-10 10:00:00+08' where model_id = :'mb';

create function pg_temp.ship(p_dealer uuid, p_serial text, p_at timestamptz) returns uuid
language plpgsql as $$
declare v_o uuid;
begin
  v_o := create_order(p_dealer) ->> 'order_id';
  perform add_order_item(v_o, (select model_id from units where serial_no = p_serial), p_serial);
  perform update_order(v_o, (select address_id from outbound_orders where id = v_o), 0);
  perform confirm_order(v_o, gen_random_uuid());
  update outbound_orders set shipped_at = p_at where id = v_o;
  return v_o;
end $$;

select pg_temp.ship(:'d1', 'a1', '2026-09-15 10:00:00+08') as o1 \gset
select pg_temp.ship(:'d2', 'b1', '2026-10-05 10:00:00+08') as o2 \gset

select is((select count(*)::int from search_models()), 3, '不带条件：所有型号（含尚未入库的型号）');
select is((select array_agg(name order by name) from search_models(p_query => 'bc-')), array['功放','耳机','音箱'],
  '按条码搜索，不区分大小写');
select is((select array_agg(name) from search_models(p_query => 'SPK')), array['音箱'], '按型号搜索');
select is((select array_agg(name) from search_models(p_serial_no => 'a2')), array['功放'], '按机身号搜索');
select is((select array_agg(name order by name) from search_models(p_unit_status => 'shipped')), array['功放','音箱'],
  '按库存状态：有已出库产品的型号');
select is((select array_agg(name) from search_models(p_dealer_id => :'d2')), array['音箱'], '按经销商');
select is((select array_agg(name) from search_models(p_out_from => '2026-09-01', p_out_to => '2026-09-30')),
  array['功放'], '按出库日期');
select is((select array_agg(name) from search_models(p_in_from => '2026-08-01', p_in_to => '2026-08-31')),
  array['音箱'], '按入库日期（北京时间）');

update outbound_items set warranty_end = beijing_today() - 1 where order_id = :'o1';
select is((select array_agg(name) from search_models(p_warranty_status => 'expired')), array['功放'], '按保修状态');
select is((select array_agg(name) from search_models(p_warranty_status => 'in_warranty')), array['音箱'],
  '保修中只看当前保修');

-- 组合条件：针对同一台产品
select is((select count(*)::int from search_models(p_serial_no => 'a2', p_unit_status => 'shipped')), 0,
  '机身号 a2 在库，组合“已出库”查不到');
select is((select count(*)::int from search_models(p_dealer_id => :'d1', p_warranty_status => 'in_warranty')), 0,
  '出库给甲的产品已过保，组合“保修中”查不到');

select ok(
  has_function_privilege('authenticated', 'public.search_models(text, text, text, date, date, uuid, date, date, text)', 'execute')
  and not has_function_privilege('anon', 'public.search_models(text, text, text, date, date, uuid, date, date, text)', 'execute'),
  '查询函数只开放给已登录用户');

select * from finish();
rollback;
