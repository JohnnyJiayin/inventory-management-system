#!/usr/bin/env bash
# 并发测试（pgTAP 只能在单个会话中运行，并发场景用多个 psql 进程验证）
#   1. 并发生成单号不重复（Issue #5）
#   2. 同一请求编号并发提交，库存只增加一次（Issue #15）
#   3. 不同请求同时入库同一个机身号，只有一个成功（Issue #15）
#   4. 同一请求编号并发确认出库，库存只扣一次（Issue #28）
#   5. 多张订单同时确认出库同一台产品，只有一张成功（Issue #28）
#
# 用法：
#   supabase start
#   ./supabase/tests/concurrency.sh
# 环境变量：
#   DB_URL  默认连接本地 supabase（端口见 supabase/config.toml）
#   PSQL    psql 命令，默认 psql；本机没有 psql 时可用：
#           PSQL="docker exec supabase_db_inventory-management-system psql" \
#           DB_URL=postgresql://postgres:postgres@127.0.0.1:5432/postgres ./supabase/tests/concurrency.sh
#   N       并发数，默认 20
set -euo pipefail

PSQL=${PSQL:-psql}
DB_URL=${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54422/postgres}
N=${N:-20}
FAILED=0

case "$DB_URL" in
  *@127.0.0.1:*|*@localhost:*) ;;
  *) [ "${ALLOW_REMOTE:-}" = 1 ] || { echo "只能在本地数据库上运行（会写入并删除测试数据）；确需远程运行请设置 ALLOW_REMOTE=1"; exit 2; } ;;
esac

sql() { $PSQL "$DB_URL" -X -q -t -A -v ON_ERROR_STOP=1 -c "$1"; }
check() {
  if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1 (got $2, want $3)"; FAILED=1; fi
}

TAG="conc$(date +%s)$$"
DAY="2099-01-01"
# 测试 2–5 会占用今天（北京时间）的入库 / 出库单号；结束时恢复计数，避免真实单号被跳过
TODAY=$(sql "select (now() at time zone 'Asia/Shanghai')::date")
TODAY_RK=$(sql "select coalesce((select last_no::text from doc_counters where prefix = 'RK' and day = '$TODAY'), 'none')")
TODAY_CK=$(sql "select coalesce((select last_no::text from doc_counters where prefix = 'CK' and day = '$TODAY'), 'none')")

# 恢复为“测试前的值”与“今天剩余记录的最大序号”中较大者，不会让以后的单号与已有记录重复
restore_counter() { # prefix 测试前的值 表 单号字段
  local base=0
  [ "$2" != "none" ] && base=$2
  echo "update doc_counters set last_no = greatest($base, coalesce((
      select max(split_part($4, '-', 2)::int) from $3
      where $4 like '$1' || to_char(date '$TODAY', 'YYYYMMDD') || '-%'), 0))
    where prefix = '$1' and day = '$TODAY';
    delete from doc_counters where prefix = '$1' and day = '$TODAY' and last_no = 0;"
}

cleanup() {
  ORDERS="select o.id from outbound_orders o join dealers d on d.id = o.dealer_id where d.company_name like '$TAG%'"
  DEALER_ROWS="select id from dealers where company_name like '$TAG%'
    union all select a.id from dealer_addresses a join dealers d on d.id = a.dealer_id where d.company_name like '$TAG%'
    union all select p.id from dealer_prices p join dealers d on d.id = p.dealer_id where d.company_name like '$TAG%'"
  sql "
    delete from request_keys where result ->> 'model_id' in
      (select id::text from product_models where barcode like '$TAG%');
    delete from request_keys where result ->> 'order_id' in (select id::text from ($ORDERS) x);
    delete from audit_logs where order_id in ($ORDERS) or record_id in ($DEALER_ROWS);
    delete from outbound_items where order_id in ($ORDERS);
    delete from outbound_orders where id in ($ORDERS);
    delete from dealer_prices where dealer_id in (select id from dealers where company_name like '$TAG%');
    delete from dealer_addresses where dealer_id in (select id from dealers where company_name like '$TAG%');
    delete from dealers where company_name like '$TAG%';
    delete from audit_logs where model_id in (select id from product_models where barcode like '$TAG%');
    delete from stock_in_records where model_id in (select id from product_models where barcode like '$TAG%');
    delete from units where model_id in (select id from product_models where barcode like '$TAG%');
    delete from audit_logs where table_name = 'product_models' and after ->> 'barcode' like '$TAG%';
    delete from product_models where barcode like '$TAG%';
    delete from doc_counters where day = '$DAY';
    $(restore_counter RK "$TODAY_RK" stock_in_records record_no)
    $(restore_counter CK "$TODAY_CK" outbound_orders order_no)
  " >/dev/null
}
trap cleanup EXIT

# ---------------------------------------------------------------- 1. 单号
OUT=$(mktemp)
for _ in $(seq "$N"); do
  sql "select next_doc_no('RK', '$DAY 12:00+08')" >>"$OUT" &
done
wait
check "并发生成 $N 个单号互不重复" "$(sort -u "$OUT" | wc -l | tr -d ' ')" "$N"
check "最后一个单号序号为 $N" "$(sort "$OUT" | tail -1)" "RK20990101-$(printf '%03d' "$N")"
rm -f "$OUT"

# ---------------------------------------------------------------- 2. 同一请求编号
MODEL=$(sql "select create_model('并发测试', 'C', '${TAG}A') ->> 'model_id'")
REQ=$(sql "select gen_random_uuid()")
for _ in $(seq "$N"); do
  sql "select stock_in('$MODEL', array['c1','c2'], 2, '$REQ')" >/dev/null 2>&1 &
done
wait
check "同一请求编号并发提交 $N 次，库存只增加一次" \
  "$(sql "select stock_qty from v_model_stock where id = '$MODEL'")" "2"
check "只生成一批入库流水" \
  "$(sql "select count(*) from stock_in_records where model_id = '$MODEL'")" "2"

# ---------------------------------------------------------------- 3. 同一机身号
OK=0
PIDS=()
for _ in $(seq "$N"); do
  sql "select stock_in('$MODEL', array['same'], 1, gen_random_uuid())" >/dev/null 2>&1 &
  PIDS+=($!)
done
for p in "${PIDS[@]}"; do
  if wait "$p"; then OK=$((OK + 1)); fi
done
check "同一机身号并发入库 $N 次，只有 1 次成功" "$OK" "1"
check "该机身号只有一条单台产品记录" \
  "$(sql "select count(*) from units where model_id = '$MODEL' and serial_no = 'same'")" "1"

# ---------------------------------------------------------------- 4. 同一请求编号确认出库
DEALER=$(sql "select create_dealer('${TAG}D', '张三', '1', '[{\"address\":\"上海\"}]') ->> 'dealer_id'")
MODEL2=$(sql "select create_model('并发出库', 'O', '${TAG}B', null, null, 3, array['o1','o2','o3']) ->> 'model_id'")
sql "select set_dealer_price('$DEALER', '$MODEL2', 10)" >/dev/null

new_order() { # 机身号… → 订单 id（运费 0）
  local o
  o=$(sql "select create_order('$DEALER') ->> 'order_id'")
  for s in "$@"; do sql "select add_order_item('$o', '$MODEL2', '$s')" >/dev/null; done
  sql "select update_order('$o', (select address_id from outbound_orders where id = '$o'), 0)" >/dev/null
  echo "$o"
}

ORDER=$(new_order o1 o2)
REQ=$(sql "select gen_random_uuid()")
for _ in $(seq "$N"); do
  sql "select confirm_order('$ORDER', '$REQ')" >/dev/null 2>&1 &
done
wait
check "同一请求编号并发确认 $N 次，库存只扣一次" \
  "$(sql "select stock_qty from v_model_stock where id = '$MODEL2'")" "1"
check "订单为已完成" "$(sql "select status from outbound_orders where id = '$ORDER'")" "completed"

# ---------------------------------------------------------------- 5. 多张订单同时出库同一台产品
ORDERS=()
for _ in $(seq "$N"); do ORDERS+=("$(new_order o3)"); done
OK=0
PIDS=()
for o in "${ORDERS[@]}"; do
  sql "select confirm_order('$o', gen_random_uuid())" >/dev/null 2>&1 &
  PIDS+=($!)
done
for p in "${PIDS[@]}"; do
  if wait "$p"; then OK=$((OK + 1)); fi
done
check "$N 张订单同时出库同一台产品，只有 1 张成功" "$OK" "1"
check "该产品只出库一次" \
  "$(sql "select count(*) from outbound_items i join outbound_orders o on o.id = i.order_id
          where o.status = 'completed' and i.model_id = '$MODEL2' and i.serial_no = 'o3'")" "1"
check "库存为 0" "$(sql "select stock_qty from v_model_stock where id = '$MODEL2'")" "0"

exit $FAILED
