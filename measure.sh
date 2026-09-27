#!/usr/bin/env bash
# Gate 6: measure cold start, warm latency, CloudWatch metrics, and cost per million requests.
# Sends about 125 requests to the live API. Creates no resources.
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-awsnew}"
REGION="us-east-2"
NAME="machine-failure-api"
LOG_GROUP="/aws/lambda/${NAME}"
COLD_RUNS="${COLD_RUNS:-5}"
WARM_RUNS="${WARM_RUNS:-100}"
MEMORY_GB=0.5

# On-demand prices for us-east-2, read from the AWS Pricing API on 2026-09-27.
PRICE_LAMBDA_GB_S=0.0000133334   # arm64, first 7.5B GB-s per month
PRICE_LAMBDA_REQ=0.0000002
PRICE_HTTP_API_REQ=0.000001      # first 300M requests per month
PRICE_LOGS_GB=0.50               # CloudWatch Logs ingestion

cd "$(dirname "$0")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

aws --version >/dev/null 2>&1 || { echo "The aws CLI at $(command -v aws) does not run." >&2; exit 1; }
aws sts get-caller-identity --region "$REGION" >/dev/null || { echo "Credentials expired. Run: aws login" >&2; exit 1; }

API_ID="$(aws apigatewayv2 get-apis --region "$REGION" --query "Items[?Name=='${NAME}'].ApiId | [0]" --output text)"
URL="$(aws apigatewayv2 get-api --region "$REGION" --api-id "$API_ID" --query ApiEndpoint --output text)/predict"
START_EPOCH="$(date +%s)"

VALID='{"type":"M","air_temp_k":298.1,"process_temp_k":308.6,"rotational_speed_rpm":1551,"torque_nm":42.8,"tool_wear_min":0}'
STRESSED='{"type":"L","air_temp_k":301.0,"process_temp_k":310.5,"rotational_speed_rpm":1380,"torque_nm":65.0,"tool_wear_min":220}'
INVALID='{"type":"M","air_temp_k":298.1,"process_temp_k":308.6,"rotational_speed_rpm":1551,"torque_nm":500,"tool_wear_min":0}'

post() {  # prints "<http status> <total seconds>"
  curl -sS -o /dev/null -w '%{http_code} %{time_total}\n' -X POST "$URL" -H 'content-type: application/json' -d "$1"
}

# Any configuration change makes Lambda discard its warm environments, so the next request is a cold start.
echo "==> ${COLD_RUNS} forced cold starts"
for i in $(seq 1 "$COLD_RUNS"); do
  aws lambda update-function-configuration --region "$REGION" --function-name "$NAME" \
    --environment "Variables={MEASURE_NONCE=${START_EPOCH}-${i}}" >/dev/null
  aws lambda wait function-updated-v2 --region "$REGION" --function-name "$NAME"
  post "$VALID" | tee -a "$WORK/cold.txt"
done
aws lambda update-function-configuration --region "$REGION" --function-name "$NAME" \
  --environment "Variables={}" >/dev/null
aws lambda wait function-updated-v2 --region "$REGION" --function-name "$NAME"
post "$VALID" >/dev/null  # absorb the cold start caused by the reset

# Stay under the stage throttle of 10 requests per second.
echo "==> ${WARM_RUNS} warm requests plus 10 stressed and 10 invalid"
for i in $(seq 1 "$WARM_RUNS"); do post "$VALID" >> "$WORK/warm.txt"; sleep 0.15; done
for i in $(seq 1 10); do post "$STRESSED" >> "$WORK/stressed.txt"; sleep 0.15; done
for i in $(seq 1 10); do post "$INVALID" >> "$WORK/invalid.txt"; sleep 0.15; done
END_EPOCH="$(date +%s)"

python3 - "$WORK" <<'PY'
import sys, pathlib, statistics
work = pathlib.Path(sys.argv[1])
def pct(xs, p):
    xs = sorted(xs); k = (len(xs) - 1) * p / 100; f = int(k)
    return xs[f] + (xs[min(f + 1, len(xs) - 1)] - xs[f]) * (k - f)
for name in ["cold", "warm", "stressed", "invalid"]:
    rows = [line.split() for line in (work / f"{name}.txt").read_text().split("\n") if line]
    codes = sorted({r[0] for r in rows}); ms = [float(r[1]) * 1000 for r in rows]
    print(f"client {name:<8} n={len(ms):<3} status={','.join(codes)} p50={pct(ms,50):7.1f} ms  p95={pct(ms,95):7.1f} ms  max={max(ms):7.1f} ms")
PY

# Lambda writes one REPORT line per invocation. Logs Insights turns those lines into queryable fields.
echo "==> waiting 30 s for logs to be indexed"
sleep 30
insights() {
  local qid
  qid="$(aws logs start-query --region "$REGION" --log-group-name "$LOG_GROUP" \
    --start-time "$START_EPOCH" --end-time "$((END_EPOCH + 60))" --query-string "$1" --query queryId --output text)"
  for _ in $(seq 1 30); do
    status="$(aws logs get-query-results --region "$REGION" --query-id "$qid" --query status --output text)"
    [[ "$status" == "Complete" ]] && break
    sleep 2
  done
  aws logs get-query-results --region "$REGION" --query-id "$qid" --query results --output json
}

echo "==> Lambda REPORT statistics (Logs Insights)"
insights 'filter @type = "REPORT"
  | fields ispresent(@initDuration) as cold
  | stats count(*) as n, avg(@initDuration) as init_avg, max(@initDuration) as init_max,
          avg(@duration) as dur_avg, pct(@duration, 50) as dur_p50, pct(@duration, 99) as dur_p99,
          avg(@billedDuration) as billed_avg, max(@maxMemoryUsed) / 1000000 as mem_max_mb by cold' > "$WORK/report.json"
insights 'stats count(*) as events, sum(strlen(@message)) as bytes' > "$WORK/logbytes.json"

python3 - "$WORK" "$MEMORY_GB" "$PRICE_LAMBDA_GB_S" "$PRICE_LAMBDA_REQ" "$PRICE_HTTP_API_REQ" "$PRICE_LOGS_GB" <<'PY'
import json, sys, pathlib
work = pathlib.Path(sys.argv[1]); mem_gb, p_gbs, p_req, p_api, p_logs = map(float, sys.argv[2:])
rows = [{c["field"]: c["value"] for c in r} for r in json.loads((work / "report.json").read_text())]
f = lambda v: float(v) if v not in (None, "") else float("nan")
stats = {}
for r in rows:
    kind = "cold" if r["cold"] == "1" else "warm"; stats[kind] = r
    line = (f"lambda {kind}: n={r['n']} duration avg={f(r['dur_avg']):.2f} ms p50={f(r['dur_p50']):.2f} ms "
            f"p99={f(r['dur_p99']):.2f} ms billed avg={f(r['billed_avg']):.2f} ms max memory={f(r['mem_max_mb']):.0f} MB")
    if kind == "cold":
        line += f" init avg={f(r['init_avg']):.0f} ms init max={f(r['init_max']):.0f} ms"
    print(line)

logs = {c["field"]: c["value"] for c in json.loads((work / "logbytes.json").read_text())[0]}
invocations = sum(int(r["n"]) for r in rows)
bytes_per_req = float(logs["bytes"]) / invocations
print(f"log volume: {logs['events']} events, {float(logs['bytes']):.0f} bytes, {bytes_per_req:.0f} bytes per invocation")

warm_billed_s = f(stats["warm"]["billed_avg"]) / 1000
per_million = {
    "API Gateway HTTP API requests": 1e6 * p_api,
    "Lambda requests": 1e6 * p_req,
    "Lambda duration (warm, 512 MB)": 1e6 * warm_billed_s * mem_gb * p_gbs,
    "CloudWatch Logs ingestion": 1e6 * bytes_per_req / 1e9 * p_logs,
}
print("cost per million warm requests (USD, before free tier):")
for k, v in per_million.items():
    print(f"  {k:<32} {v:8.4f}")
print(f"  {'total':<32} {sum(per_million.values()):8.4f}")
if "cold" in stats:
    cold_s = f(stats["cold"]["billed_avg"]) / 1000
    print(f"one cold start bills {cold_s * 1000:.0f} ms, which costs {cold_s * mem_gb * p_gbs:.8f} USD")
PY

echo "==> CloudWatch metrics over the measurement window"
cat > "$WORK/queries.json" <<JSON
[
  {"Id": "predictions", "MetricStat": {"Metric": {"Namespace": "MachineFailureApi", "MetricName": "Predictions", "Dimensions": [{"Name": "service", "Value": "${NAME}"}]}, "Period": 3600, "Stat": "Sum"}},
  {"Id": "flagged", "MetricStat": {"Metric": {"Namespace": "MachineFailureApi", "MetricName": "FailuresFlagged", "Dimensions": [{"Name": "service", "Value": "${NAME}"}]}, "Period": 3600, "Stat": "Sum"}},
  {"Id": "invalid", "MetricStat": {"Metric": {"Namespace": "MachineFailureApi", "MetricName": "InvalidReadings", "Dimensions": [{"Name": "service", "Value": "${NAME}"}]}, "Period": 3600, "Stat": "Sum"}},
  {"Id": "inference_p99_ms", "MetricStat": {"Metric": {"Namespace": "MachineFailureApi", "MetricName": "InferenceLatency", "Dimensions": [{"Name": "service", "Value": "${NAME}"}]}, "Period": 3600, "Stat": "p99"}},
  {"Id": "lambda_invocations", "MetricStat": {"Metric": {"Namespace": "AWS/Lambda", "MetricName": "Invocations", "Dimensions": [{"Name": "FunctionName", "Value": "${NAME}"}]}, "Period": 3600, "Stat": "Sum"}},
  {"Id": "lambda_errors", "MetricStat": {"Metric": {"Namespace": "AWS/Lambda", "MetricName": "Errors", "Dimensions": [{"Name": "FunctionName", "Value": "${NAME}"}]}, "Period": 3600, "Stat": "Sum"}},
  {"Id": "lambda_throttles", "MetricStat": {"Metric": {"Namespace": "AWS/Lambda", "MetricName": "Throttles", "Dimensions": [{"Name": "FunctionName", "Value": "${NAME}"}]}, "Period": 3600, "Stat": "Sum"}},
  {"Id": "api_count", "MetricStat": {"Metric": {"Namespace": "AWS/ApiGateway", "MetricName": "Count", "Dimensions": [{"Name": "ApiId", "Value": "${API_ID}"}, {"Name": "Stage", "Value": "\$default"}]}, "Period": 3600, "Stat": "Sum"}},
  {"Id": "api_4xx", "MetricStat": {"Metric": {"Namespace": "AWS/ApiGateway", "MetricName": "4xx", "Dimensions": [{"Name": "ApiId", "Value": "${API_ID}"}, {"Name": "Stage", "Value": "\$default"}]}, "Period": 3600, "Stat": "Sum"}},
  {"Id": "api_5xx", "MetricStat": {"Metric": {"Namespace": "AWS/ApiGateway", "MetricName": "5xx", "Dimensions": [{"Name": "ApiId", "Value": "${API_ID}"}, {"Name": "Stage", "Value": "\$default"}]}, "Period": 3600, "Stat": "Sum"}},
  {"Id": "api_latency_p50_ms", "MetricStat": {"Metric": {"Namespace": "AWS/ApiGateway", "MetricName": "Latency", "Dimensions": [{"Name": "ApiId", "Value": "${API_ID}"}, {"Name": "Stage", "Value": "\$default"}]}, "Period": 3600, "Stat": "p50"}},
  {"Id": "api_integration_p50_ms", "MetricStat": {"Metric": {"Namespace": "AWS/ApiGateway", "MetricName": "IntegrationLatency", "Dimensions": [{"Name": "ApiId", "Value": "${API_ID}"}, {"Name": "Stage", "Value": "\$default"}]}, "Period": 3600, "Stat": "p50"}}
]
JSON
# Metrics need a minute or two to land. Poll until the custom metric count covers the warm traffic.
for _ in $(seq 1 12); do
  aws cloudwatch get-metric-data --region "$REGION" --metric-data-queries "file://$WORK/queries.json" \
    --start-time "$(date -u -r "$((START_EPOCH - 3600))" +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time "$(date -u -r "$((END_EPOCH + 3600))" +%Y-%m-%dT%H:%M:%SZ)" \
    --query 'MetricDataResults[].[Id, sum(Values)]' --output text > "$WORK/metrics.txt"
  predictions="$(awk '$1=="predictions"{print int($2)}' "$WORK/metrics.txt")"
  [[ "${predictions:-0}" -ge "$WARM_RUNS" ]] && break
  sleep 15
done
column -t "$WORK/metrics.txt"
echo "(sums cover every request in the hour buckets that overlap this run, including earlier gates)"
