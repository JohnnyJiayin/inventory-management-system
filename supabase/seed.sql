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

insert into public.dealers (id, company_name, contact_name, phone)
values ('d0000000-0000-0000-0000-000000000001', '演示经销商', '张三', '13800000000');
insert into public.dealer_addresses (dealer_id, label, address, is_default)
values ('d0000000-0000-0000-0000-000000000001', '公司', '上海市演示路 1 号', true);

-- 模拟一张已完成的出库订单（出库业务函数在 Sprint 2 实现）
insert into public.outbound_orders (id, order_no, dealer_id, dealer_name, contact_name, phone, address_text,
                                    shipping_fee, products_amount, total_amount, status, shipped_at, completed_at)
values ('0d000000-0000-0000-0000-000000000001', public.next_doc_no('CK'), 'd0000000-0000-0000-0000-000000000001',
        '演示经销商', '张三', '13800000000', '上海市演示路 1 号', 10, 100, 110, 'completed', now(), now());
insert into public.outbound_items (order_id, unit_id, model_id, barcode, serial_no, default_price, actual_price,
                                   warranty_start, warranty_end)
select '0d000000-0000-0000-0000-000000000001', u.id, u.model_id, u.barcode, u.serial_no, 100, 100,
       now(), ((now() at time zone 'Asia/Shanghai')::date + interval '1 year')::date
from public.units u join public.product_models m on m.id = u.model_id
where m.barcode = 'DEMO-RESTOCK' and u.serial_no = 'R1';
update public.units set status = 'shipped', last_out_at = now()
where serial_no = 'R1' and model_id = (select id from public.product_models where barcode = 'DEMO-RESTOCK');
