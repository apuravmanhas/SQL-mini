"""
VerityTick — Performance Engineering & Workload Benchmark Tool

Measures reproducible latency percentiles (p50, p95, p99) and throughput (ops/sec)
for core database workloads:
1. Sequential order placement & balance reservation
2. Order matching & double-entry settlement
3. Available balance retrieval
4. Recursive CTE circular transfer detection
5. Incremental OHLCV candlestick aggregation
"""

import os
import sys
import time
import statistics
import psycopg2

def load_env():
    env_path = os.path.join(os.path.dirname(os.path.dirname(__file__)), '.env')
    if os.path.exists(env_path):
        with open(env_path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    k, _, v = line.partition('=')
                    if v.strip():
                        os.environ.setdefault(k.strip(), v.strip())

load_env()

TENANT_APEX = 'a0000000-0000-0000-0000-000000000001'
ACCT_ALICE = 'e0000000-0000-0000-0000-000000000001'
ACCT_BOB = 'e0000000-0000-0000-0000-000000000003'
MARKET_ACME = 'd0000000-0000-0000-0000-000000000001'
ASSET_USDX = 'c0000000-0000-0000-0000-000000000001'
ASSET_ACME = 'c0000000-0000-0000-0000-000000000002'

def get_connection():
    return psycopg2.connect(
        host=os.environ.get('VT_DB_HOST', 'localhost'),
        port=int(os.environ.get('VT_DB_PORT', 5432)),
        user=os.environ.get('VT_DB_USER', 'postgres'),
        password=os.environ.get('VT_DB_PASSWORD', ''),
        dbname=os.environ.get('VT_DB_NAME', 'veritytick'),
    )

def compute_stats(latencies_ms):
    latencies_ms.sort()
    n = len(latencies_ms)
    total_time = sum(latencies_ms) / 1000.0
    throughput = n / total_time if total_time > 0 else 0
    p50 = statistics.median(latencies_ms)
    p95 = latencies_ms[int(n * 0.95)] if n > 0 else 0
    p99 = latencies_ms[int(n * 0.99)] if n > 0 else 0
    return {
        'total_ops': n,
        'throughput_ops_sec': round(throughput, 2),
        'p50_ms': round(p50, 3),
        'p95_ms': round(p95, 3),
        'p99_ms': round(p99, 3),
    }

def benchmark_order_placement(conn, iterations=100):
    print(f"[*] Running Order Placement benchmark ({iterations} ops)...")
    cur = conn.cursor()
    # Ensure ample funds for Alice
    cur.execute("SELECT ledger.deposit(%s, %s, %s, %s)",
                (TENANT_APEX, ACCT_ALICE, ASSET_USDX, 1000000))
    conn.commit()

    latencies = []
    for i in range(iterations):
        t0 = time.perf_counter()
        cur.execute("""
            SELECT trading.place_order(%s, %s, %s, 'buy', %s, 1.0)
        """, (TENANT_APEX, ACCT_ALICE, MARKET_ACME, 10.0 + (i * 0.01)))
        conn.commit()
        t1 = time.perf_counter()
        latencies.append((t1 - t0) * 1000.0)

    cur.close()
    return compute_stats(latencies)

def benchmark_order_matching(conn, iterations=100):
    print(f"[*] Running Order Matching benchmark ({iterations} ops)...")
    cur = conn.cursor()
    cur.execute("SELECT ledger.deposit(%s, %s, %s, %s)",
                (TENANT_APEX, ACCT_BOB, ASSET_ACME, 100000))
    conn.commit()

    latencies = []
    for i in range(iterations):
        # Match against Alice's resting orders
        t0 = time.perf_counter()
        cur.execute("""
            SELECT trading.place_order(%s, %s, %s, 'sell', %s, 1.0)
        """, (TENANT_APEX, ACCT_BOB, MARKET_ACME, 10.0 + (i * 0.01)))
        conn.commit()
        t1 = time.perf_counter()
        latencies.append((t1 - t0) * 1000.0)

    cur.close()
    return compute_stats(latencies)

def benchmark_balance_lookup(conn, iterations=200):
    print(f"[*] Running Balance Lookup benchmark ({iterations} ops)...")
    cur = conn.cursor()
    latencies = []
    for _ in range(iterations):
        t0 = time.perf_counter()
        cur.execute("SELECT ledger.available_balance(%s, %s)",
                    (ACCT_ALICE, ASSET_USDX))
        cur.fetchone()
        t1 = time.perf_counter()
        latencies.append((t1 - t0) * 1000.0)

    cur.close()
    return compute_stats(latencies)

def benchmark_fraud_detection(conn, iterations=10):
    print(f"[*] Running Recursive Fraud Cycle Detection benchmark ({iterations} ops)...")
    cur = conn.cursor()
    latencies = []
    for _ in range(iterations):
        t0 = time.perf_counter()
        cur.execute("""
            SELECT COUNT(*) FROM risk.detect_cycles(
                %s, now() - INTERVAL '1 day', now() + INTERVAL '1 day', 6, 0
            )
        """, (TENANT_APEX,))
        cur.fetchone()
        t1 = time.perf_counter()
        latencies.append((t1 - t0) * 1000.0)

    cur.close()
    return compute_stats(latencies)

def benchmark_candle_refresh(conn, iterations=10):
    print(f"[*] Running Candlestick Aggregation benchmark ({iterations} ops)...")
    cur = conn.cursor()
    latencies = []
    for _ in range(iterations):
        t0 = time.perf_counter()
        cur.execute("""
            SELECT * FROM market_data.refresh_candles(
                %s, now() - INTERVAL '2 hours', now() + INTERVAL '2 hours'
            )
        """, (MARKET_ACME,))
        cur.fetchall()
        t1 = time.perf_counter()
        latencies.append((t1 - t0) * 1000.0)

    cur.close()
    return compute_stats(latencies)

def run_all_benchmarks():
    print("=" * 60)
    print(" VerityTick Benchmark Suite (PostgreSQL 18)")
    print("=" * 60)

    conn = get_connection()
    try:
        results = {
            'Order Placement': benchmark_order_placement(conn, 100),
            'Order Matching': benchmark_order_matching(conn, 100),
            'Balance Lookup': benchmark_balance_lookup(conn, 200),
            'Fraud Cycle Detection': benchmark_fraud_detection(conn, 10),
            'Candlestick Refresh': benchmark_candle_refresh(conn, 10),
        }

        print("\n" + "=" * 60)
        print(" Benchmark Results Summary")
        print("=" * 60)
        print(f"{'Workload':<25} | {'Throughput':<12} | {'p50 (ms)':<9} | {'p95 (ms)':<9} | {'p99 (ms)':<9}")
        print("-" * 72)
        for name, stats in results.items():
            print(f"{name:<25} | {str(stats['throughput_ops_sec']) + ' ops/s':<12} | {stats['p50_ms']:<9} | {stats['p95_ms']:<9} | {stats['p99_ms']:<9}")
        print("=" * 60)

    finally:
        conn.close()

if __name__ == '__main__':
    run_all_benchmarks()
