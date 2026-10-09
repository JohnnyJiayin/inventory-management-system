-- Issue #37：保修查询
begin;
create extension if not exists pgtap with schema extensions;
-- 在本事务内清空业务数据（结束时回滚），测试不受 seed.sql 或其他数据影响
truncate audit_logs, outbound_items, outbound_orders, stock_in_records, units,
         dealer_prices, dealer_addresses, dealers, product_models, request_keys, doc_counters;
select plan(19);

-- ---------------------------------------------------------------- 状态计算（北京时间日期）
select is(warranty_status('2027-09-27', 'completed', '2027-09-27'), 'in_warranty', '截止日当天显示保修中');
select is(warranty_status('2027-09-27', 'completed', '2027-09-28'), 'expired', '截止日次日显示已过保');
select is(warranty_status('2027-09-27', 'cancelled', '2027-01-01'), 'void', '已撤销订单的保修失效');
select is(beijing_today(), (now() at time zone 'Asia/Shanghai')::date, '“今天”按北京时间计算');
select is((('2028-02-29'::date + interval '1 year')::date), '2029-02-28'::date, '闰日出库，截止日为次年 2 月 28 日');

-- ---------------------------------------------------------------- 准备：出库一台
select create_model('功放', '4.4 AMP', 'BC-A', null, null, 2, array['187', '188']) ->> 'model_id' as m \gset
select create_dealer('甲公司', '张三', '138', '[{"address":"上海市"}]') ->> 'dealer_id' as d \gset
select set_dealer_price(:'d', :'m', 100);

create temp table t_ship (n int, order_id uuid);
create function pg_temp.ship(p_serial text) returns uuid language plpgsql as $$
declare v_o uuid;
begin
  v_o := create_order((select id from dealers where company_name = '甲公司')) ->> 'order_id';
  perform add_order_item(v_o, (select id from product_models where barcode = 'BC-A'), p_serial);
  perform update_order(v_o, (select address_id from outbound_orders where id = v_o), 0);
  perform confirm_order(v_o, gen_random_uuid());
  return v_o;
end $$;

select pg_temp.ship('187') as o1 \gset
select is((select row(warranty_status, is_current, days_left)::text from v_warranty where order_id = :'o1'),
  format('(in_warranty,t,%s)', (beijing_today() + interval '1 year')::date - beijing_today()),
  '出库后自动开始一年保修，为当前保修');
select is((select dealer_name from v_warranty where order_id = :'o1'), '甲公司', '保修记录显示经销商');

-- ---------------------------------------------------------------- 即将过保 / 已过保（把出库时间调到过去）
update outbound_items set warranty_end = beijing_today() where order_id = :'o1';
select is((select row(warranty_status, expiring_soon, days_left)::text from v_warranty where order_id = :'o1'),
  '(in_warranty,t,0)', '截止日为今天：保修中、即将过保');
update outbound_items set warranty_end = beijing_today() + 30 where order_id = :'o1';
select is((select expiring_soon from v_warranty where order_id = :'o1'), true, '30 天内到期为即将过保');
update outbound_items set warranty_end = beijing_today() + 31 where order_id = :'o1';
select is((select expiring_soon from v_warranty where order_id = :'o1'), false, '31 天后到期不算即将过保');
update outbound_items set warranty_end = beijing_today() - 1 where order_id = :'o1';
select is((select row(warranty_status, expiring_soon)::text from v_warranty where order_id = :'o1'),
  '(expired,f)', '截止日已过：已过保');

-- ---------------------------------------------------------------- 重新入库再出库
update outbound_orders set shipped_at = now() - interval '400 days' where id = :'o1';
select stock_in(:'m', array['187'], 1, gen_random_uuid());
select pg_temp.ship('187') as o2 \gset
select is((select count(*)::int from v_warranty where serial_no = '187'), 2, '历次保修记录均可以查询');
select is((select order_id::text from v_warranty where serial_no = '187' and is_current), :'o2',
  '当前保修以最近一次有效出库为准');
select is((select warranty_end from v_warranty where order_id = :'o2'), (beijing_today() + interval '1 year')::date,
  '重新入库后再次出库，按新出库日重新计算一年');
select is((select warranty_status from v_warranty where order_id = :'o1'), 'expired', '旧保修记录仍可查');

-- ---------------------------------------------------------------- 撤销后失效
select pg_temp.ship('188') as o3 \gset
select cancel_order(:'o3', '错单');
select is((select row(warranty_status, is_current, expiring_soon)::text from v_warranty where order_id = :'o3'),
  '(void,f,f)', '撤销后本次保修失效，但记录仍在');

-- 撤销最近一次出库后，当前保修回到上一次有效出库
select cancel_order(:'o2', '错单');
select is((select order_id::text from v_warranty where serial_no = '187' and is_current), :'o1',
  '撤销最近一次出库后，当前保修为上一次有效出库');

-- ---------------------------------------------------------------- 权限
select ok(not has_table_privilege('anon', 'public.v_warranty', 'select')
          and has_table_privilege('authenticated', 'public.v_warranty', 'select'),
  '保修视图只开放给已登录用户');

set local role authenticated;
set local request.jwt.claims to '{"sub":"00000000-0000-0000-0000-0000000000aa","role":"authenticated"}';
select is((select count(*)::int from v_warranty), 3, '登录后可以查询保修');
reset role;

select * from finish();
rollback;
