#!/usr/bin/env bash
set -euo pipefail

trap 'echo -e "\nCaught SIGINT. Exiting..."; exit 130' INT

# Smoke-test all fuzz targets in two phases:
# 1) Build image explicitly (must succeed).
# 2) Run container without rebuilding (bounded by timeout).
#
# Since many targets fuzz indefinitely, run timeout is considered success.

BUILD_TIMEOUT="${BUILD_TIMEOUT:-1800}"
RUN_TIMEOUT="${RUN_TIMEOUT:-120}"
KEEP_GOING="${KEEP_GOING:-1}"
LOG_DIR="${LOG_DIR:-/tmp/bitcoinfuzz-target-logs}"

mkdir -p "$LOG_DIR"

if ! command -v just >/dev/null 2>&1; then
  echo "Error: 'just' is required but was not found in PATH." >&2
  exit 1
fi

if ! command -v timeout >/dev/null 2>&1; then
  echo "Error: 'timeout' is required but was not found in PATH." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: 'jq' is required but was not found in PATH." >&2
  exit 1
fi

compose_config="$(docker compose config --format=json)"

if [[ "$#" -gt 0 ]]; then
  targets=("$@")
else
  mapfile -t targets < <(just list-targets | sed '/^$/d')
fi

if [[ "${#targets[@]}" -eq 0 ]]; then
  echo "No targets found."
  exit 1
fi

pass=0
fail=0

for target in "${targets[@]}"; do
  unset run_rc
  build_log="$LOG_DIR/${target}.build.log"
  run_log="$LOG_DIR/${target}.run.log"
  echo ""
  echo "==> Testing target: $target"
  echo "    build log: $build_log"
  echo "    run log:   $run_log"

  # Always clean up the service/container from any previous run.
  docker compose rm -sf "$target" >/dev/null 2>&1 || true

  set +e
  timeout --foreground "${BUILD_TIMEOUT}s" just docker-build "$target" >"$build_log" 2>&1
  build_rc=$?
  set -e

  if [[ "$build_rc" -ne 0 ]]; then
    if [[ "$build_rc" -eq 130 ]]; then
      echo "Interrupted."
      exit 130
    elif [[ "$build_rc" -eq 124 ]]; then
      echo "FAIL: $target (build timeout rc=$build_rc)"
    else
      echo "FAIL: $target (build rc=$build_rc)"
    fi
    echo "      log: $build_log"
    ((fail+=1))
  else
    service_image="$(jq -r --arg target "$target" '.services[$target].image // (.name + "-" + $target + ":latest")' <<<"$compose_config")"

    # Match the image name that Compose will look for during the no-build run phase.
    if [[ "$service_image" != "bitcoinfuzz:${target}" ]]; then
      docker tag "bitcoinfuzz:${target}" "$service_image"
    fi

    set +e
    timeout --foreground "${RUN_TIMEOUT}s" docker compose up "$target" --force-recreate --no-build >"$run_log" 2>&1
    run_rc=$?
    set -e

    # 0: target completed; 124: timeout after startup.
    if [[ "$run_rc" -eq 130 ]]; then
      echo "Interrupted."
      exit 130
    elif [[ "$run_rc" -eq 0 || "$run_rc" -eq 124 ]]; then
      echo "PASS: $target (run rc=$run_rc)"
      ((pass+=1))
    else
      echo "FAIL: $target (run rc=$run_rc)"
      echo "      log: $run_log"
      ((fail+=1))
    fi
  fi

  # Ensure no target remains attached/running before next iteration.
  docker compose rm -sf "$target" >/dev/null 2>&1 || true

  if [[ "$KEEP_GOING" != "1" && ( "$build_rc" -ne 0 || ( "${run_rc:-0}" -ne 0 && "${run_rc:-0}" -ne 124 ) ) ]]; then
    break
  fi

done

echo ""
echo "Summary: pass=$pass fail=$fail total=$((pass + fail))"

if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
