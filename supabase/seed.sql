-- =============================================================================
-- 本地开发 / UI 测试数据（只在本地 supabase start / supabase db reset 时执行，
-- 不会推送到线上项目）
-- =============================================================================

-- 本地测试账号：owner@example.com / test-pass-123
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change
) values (
  '00000000-0000-0000-0000-000000000000', 'a0000000-0000-0000-0000-000000000001',
  'authenticated', 'authenticated', 'owner@example.com',
  extensions.crypt('test-pass-123', extensions.gen_salt('bf')), now(),
  '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', ''
);
insert into auth.identities (id, user_id, provider_id, identity_data, provider, created_at, updated_at, last_sign_in_at)
values (
  gen_random_uuid(), 'a0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001',
  '{"sub":"a0000000-0000-0000-0000-000000000001","email":"owner@example.com"}', 'email', now(), now(), now()
);

-- 演示型号：有 1 台已出库产品（机身号 R1），用于测试重新入库
select public.create_model('演示功放', '4.4 AMP', 'DEMO-RESTOCK', '本地演示数据', null, 2, array['R1', 'R2']);

-- 演示经销商（两个地址）与价格；一张已完成的出库订单（R1 已出库，用于测试重新入库）；
-- 出库 UI 测试用的演示音箱 5 台在库（O1–O5），演示经销商单价 200
do $$
declare
  v_dealer  uuid;
  v_order   uuid;
  v_amp     uuid := (select id from public.product_models where barcode = 'DEMO-RESTOCK');
  v_spk     uuid;
begin
  v_dealer := public.create_dealer('演示经销商', '张三', '13800000000',
    '[{"label": "公司", "address": "上海市演示路 1 号", "is_default": true},
      {"label": "仓库", "address": "上海市仓储路 8 号"}]') ->> 'dealer_id';
  perform public.set_dealer_price(v_dealer, v_amp, 100);

  v_order := public.create_order(v_dealer) ->> 'order_id';
  perform public.add_order_item(v_order, v_amp, 'R1');
  perform public.update_order(v_order, (select address_id from public.outbound_orders where id = v_order), 10);
  perform public.confirm_order(v_order, gen_random_uuid());

  v_spk := public.create_model('演示音箱', 'SPK-1', 'DEMO-OUT', '本地演示数据', null, 5,
    array['O1', 'O2', 'O3', 'O4', 'O5']) ->> 'model_id';
  perform public.set_dealer_price(v_dealer, v_spk, 200);
end
$$;
