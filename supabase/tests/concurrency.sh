#!/usr/bin/env bash
# 并发测试（pgTAP 只能在单个会话中运行，并发场景用多个 psql 进程验证）
#   1. 并发生成单号不重复（Issue #5）
#   2. 同一请求编号并发提交，库存只增加一次（Issue #15）
#   3. 不同请求同时入库同一个机身号，只有一个成功（Issue #15）
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

sql() { $PSQL "$DB_URL" -X -q -t -A -v ON_ERROR_STOP=1 -c "$1"; }
check() {
  if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1 (got $2, want $3)"; FAILED=1; fi
}

TAG="conc$(date +%s)$$"
DAY="2099-01-01"

cleanup() {
  sql "
    delete from audit_logs where model_id in (select id from product_models where barcode like '$TAG%');
    delete from stock_in_records where model_id in (select id from product_models where barcode like '$TAG%');
    delete from units where model_id in (select id from product_models where barcode like '$TAG%');
    delete from audit_logs where table_name = 'product_models' and after ->> 'barcode' like '$TAG%';
    delete from product_models where barcode like '$TAG%';
    delete from doc_counters where day = '$DAY';
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

exit $FAILED
