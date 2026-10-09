-- =============================================================================
-- 建立全部表和约束（Issue #3）
-- 对应：需求 6 数据结构、架构设计 5
--
-- 约定：
--   * 所有时间字段使用 timestamptz；“日期”一律按北京时间（Asia/Shanghai）计算。
--   * 金额字段 numeric(12,2) + CHECK (>= 0)。
--   * 外键 ON DELETE RESTRICT：有业务记录的数据不能物理删除。
--   * 库存数量不单独存储，由视图 v_model_stock 按单台产品状态实时统计。
-- =============================================================================

-- 数据库默认时区设为北京时间（业务函数内部仍显式指定时区，不依赖会话设置）
do $$
begin
  execute format('alter database %I set timezone to %L', current_database(), 'Asia/Shanghai');
end
$$;

-- 通用：自动维护 updated_at
create or replace function public.tg_set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- 6.1 产品型号
-- -----------------------------------------------------------------------------
create table public.product_models (
  id           uuid primary key default gen_random_uuid(),
  name         text not null check (btrim(name) <> ''),
  model        text not null check (btrim(model) <> ''),
  barcode      text not null check (btrim(barcode) <> ''),
  photo_path   text,
  description  text,
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint product_models_barcode_key unique (barcode)
);
comment on table public.product_models is '产品型号；产品条码唯一';

create trigger product_models_updated_at
  before update on public.product_models
  for each row execute function public.tg_set_updated_at();

-- -----------------------------------------------------------------------------
-- 6.2 单台产品
-- -----------------------------------------------------------------------------
create table public.units (
  id           uuid primary key default gen_random_uuid(),
  model_id     uuid not null references public.product_models (id) on delete restrict,
  barcode      text not null,                      -- 录入时的产品条码
  serial_no    text not null check (btrim(serial_no) <> ''),
  status       text not null default 'in_stock'
               check (status in ('in_stock', 'shipped')),   -- 在库 / 已出库
  last_in_at   timestamptz,
  last_out_at  timestamptz,
  note         text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint units_model_serial_key unique (model_id, serial_no)
);
comment on table public.units is '单台产品；（型号, 机身号）唯一';
create index units_model_status_idx on public.units (model_id, status);
create index units_serial_idx on public.units (serial_no);

create trigger units_updated_at
  before update on public.units
  for each row execute function public.tg_set_updated_at();

-- -----------------------------------------------------------------------------
-- 6.6 入库记录（每台每次入库一条；同一批次共用一个入库单号）
-- -----------------------------------------------------------------------------
create table public.stock_in_records (
  id           uuid primary key default gen_random_uuid(),
  record_no    text not null,                      -- RK20260927-001
  unit_id      uuid not null references public.units (id) on delete restrict,
  model_id     uuid not null references public.product_models (id) on delete restrict,
  barcode      text not null,
  serial_no    text not null,
  in_type      text not null check (in_type in ('first', 'restock')),  -- 首次入库 / 重新入库
  in_at        timestamptz not null default now(),
  note         text,
  created_at   timestamptz not null default now()
);
create index stock_in_records_record_no_idx on public.stock_in_records (record_no);
create index stock_in_records_unit_idx on public.stock_in_records (unit_id);
create index stock_in_records_model_in_at_idx on public.stock_in_records (model_id, in_at);

-- -----------------------------------------------------------------------------
-- 6.3 经销商
-- -----------------------------------------------------------------------------
create table public.dealers (
  id            uuid primary key default gen_random_uuid(),
  company_name  text not null check (btrim(company_name) <> ''),
  contact_name  text not null check (btrim(contact_name) <> ''),
  phone         text not null check (btrim(phone) <> ''),
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint dealers_company_name_key unique (company_name)
);

create trigger dealers_updated_at
  before update on public.dealers
  for each row execute function public.tg_set_updated_at();

-- -----------------------------------------------------------------------------
-- 6.4 经销商地址（每个经销商最多一个默认地址）
-- -----------------------------------------------------------------------------
create table public.dealer_addresses (
  id          uuid primary key default gen_random_uuid(),
  dealer_id   uuid not null references public.dealers (id) on delete restrict,
  label       text,                                -- 公司 / 仓库 / 门店
  address     text not null check (btrim(address) <> ''),
  is_default  boolean not null default false,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index dealer_addresses_one_default_idx
  on public.dealer_addresses (dealer_id) where is_default;
create index dealer_addresses_dealer_idx on public.dealer_addresses (dealer_id);

create trigger dealer_addresses_updated_at
  before update on public.dealer_addresses
  for each row execute function public.tg_set_updated_at();

-- -----------------------------------------------------------------------------
-- 6.5 经销商产品价格（经销商 + 型号只有一个有效价格）
-- -----------------------------------------------------------------------------
create table public.dealer_prices (
  id          uuid primary key default gen_random_uuid(),
  dealer_id   uuid not null references public.dealers (id) on delete restrict,
  model_id    uuid not null references public.product_models (id) on delete restrict,
  price       numeric(12,2) not null check (price >= 0),
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index dealer_prices_one_active_idx
  on public.dealer_prices (dealer_id, model_id) where active;
create index dealer_prices_model_idx on public.dealer_prices (model_id);

create trigger dealer_prices_updated_at
  before update on public.dealer_prices
  for each row execute function public.tg_set_updated_at();

-- -----------------------------------------------------------------------------
-- 6.7 出库订单（含经销商 / 联系人 / 电话 / 地址快照）
-- -----------------------------------------------------------------------------
create table public.outbound_orders (
  id                uuid primary key default gen_random_uuid(),
  order_no          text not null,                 -- CK20260927-001
  dealer_id         uuid not null references public.dealers (id) on delete restrict,
  address_id        uuid references public.dealer_addresses (id) on delete restrict,
  dealer_name       text,                          -- 快照
  contact_name      text,                          -- 快照
  phone             text,                          -- 快照
  address_text      text,                          -- 快照
  shipping_fee      numeric(12,2) check (shipping_fee >= 0),       -- 确认时必填，可为 0
  products_amount   numeric(12,2) check (products_amount >= 0),
  total_amount      numeric(12,2) check (total_amount >= 0),
  status            text not null default 'draft'
                    check (status in ('draft', 'completed', 'cancelled')),  -- 编辑中 / 已完成 / 已撤销
  shipped_at        timestamptz,
  completed_at      timestamptz,
  cancelled_at      timestamptz,
  cancel_reason     text,
  note              text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint outbound_orders_order_no_key unique (order_no)
);
create index outbound_orders_dealer_idx on public.outbound_orders (dealer_id);
create index outbound_orders_status_shipped_idx on public.outbound_orders (status, shipped_at);

create trigger outbound_orders_updated_at
  before update on public.outbound_orders
  for each row execute function public.tg_set_updated_at();

-- -----------------------------------------------------------------------------
-- 6.8 出库订单明细（兼作保修记录）
-- -----------------------------------------------------------------------------
create table public.outbound_items (
  id              uuid primary key default gen_random_uuid(),
  order_id        uuid not null references public.outbound_orders (id) on delete restrict,
  unit_id         uuid not null references public.units (id) on delete restrict,
  model_id        uuid not null references public.product_models (id) on delete restrict,
  barcode         text not null,
  serial_no       text not null,
  default_price   numeric(12,2) not null check (default_price >= 0),
  actual_price    numeric(12,2) not null check (actual_price >= 0),
  warranty_start  timestamptz,                     -- 订单出库时间
  warranty_end    date,                            -- 出库日期（北京时间）加一年
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint outbound_items_order_unit_key unique (order_id, unit_id)
);
create index outbound_items_unit_idx on public.outbound_items (unit_id);
create index outbound_items_model_idx on public.outbound_items (model_id);

create trigger outbound_items_updated_at
  before update on public.outbound_items
  for each row execute function public.tg_set_updated_at();

-- -----------------------------------------------------------------------------
-- 18 操作记录
-- -----------------------------------------------------------------------------
create table public.audit_logs (
  id          bigint generated always as identity primary key,
  action      text not null,                       -- 例如 product.create / stock_in.first
  table_name  text not null,
  record_id   uuid,
  model_id    uuid,                                -- 相关产品型号
  order_id    uuid,                                -- 相关订单
  before      jsonb,
  after       jsonb,
  result      text not null default 'success',
  actor       uuid,                                -- auth.uid()
  created_at  timestamptz not null default now()
);
create index audit_logs_created_idx on public.audit_logs (created_at desc);
create index audit_logs_model_idx on public.audit_logs (model_id);
create index audit_logs_order_idx on public.audit_logs (order_id);

-- -----------------------------------------------------------------------------
-- 17 防重复提交：记录已处理的请求编号及其结果
-- -----------------------------------------------------------------------------
create table public.request_keys (
  request_id     uuid primary key,
  function_name  text not null,
  result         jsonb,
  created_at     timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- 单号计数器（按前缀 + 北京时间日期）
-- -----------------------------------------------------------------------------
create table public.doc_counters (
  prefix   text not null,
  day      date not null,
  last_no  integer not null,
  primary key (prefix, day)
);

-- -----------------------------------------------------------------------------
-- 保活：只有一行
-- -----------------------------------------------------------------------------
create table public.heartbeat (
  id         smallint primary key default 1 check (id = 1),
  pinged_at  timestamptz not null default now()
);
insert into public.heartbeat (id) values (1);
