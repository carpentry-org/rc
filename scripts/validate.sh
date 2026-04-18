#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CARP_BIN="${CARP_BIN:-carp}"
CARP_DIR_ROOT="${CARP_DIR:-$(cd "$ROOT/../../carp" && pwd)}"
RC_TEST="$ROOT/test/rc.carp"
RC_FUZZ_TEST_STRING="$ROOT/test/rc_fuzz.carp"
RC_FUZZ_TEST_ARRAY_STRING="$ROOT/test/rc_fuzz_array_string.carp"
RC_FUZZ_TEST_PROBE="$ROOT/test/rc_fuzz_probe.carp"

if ! command -v "$CARP_BIN" >/dev/null 2>&1; then
  echo "carp executable not found in PATH: $CARP_BIN" >&2
  exit 1
fi

PROFILE="${RC_VALIDATE_PROFILE:-ci}"
RUN_O3="${RC_VALIDATE_RUN_O3:-1}"
BASE_SEED="${RC_VALIDATE_BASE_SEED:-1001.0}"
BASE_SEED_O2="${RC_VALIDATE_BASE_SEED_O2:-2001.0}"
BASE_SEED_O3="${RC_VALIDATE_BASE_SEED_O3:-3001.0}"
SEED_STRIDE="${RC_VALIDATE_SEED_STRIDE:-9973.0}"
RANDOM_SEED="${RC_VALIDATE_RANDOM_SEED:-0}"

case "$PROFILE" in
  quick)
    DEFAULT_RUNS=16
    DEFAULT_STEPS=800
    DEFAULT_RC_SLOTS=12
    DEFAULT_WEAK_SLOTS=12
    ;;
  ci)
    DEFAULT_RUNS=80
    DEFAULT_STEPS=1500
    DEFAULT_RC_SLOTS=16
    DEFAULT_WEAK_SLOTS=16
    ;;
  soak)
    DEFAULT_RUNS=300
    DEFAULT_STEPS=4000
    DEFAULT_RC_SLOTS=24
    DEFAULT_WEAK_SLOTS=24
    ;;
  *)
    echo "invalid RC_VALIDATE_PROFILE '$PROFILE' (expected quick|ci|soak)" >&2
    exit 1
    ;;
esac

FUZZ_RUNS="${RC_FUZZ_RUNS:-$DEFAULT_RUNS}"
FUZZ_STEPS="${RC_FUZZ_STEPS:-$DEFAULT_STEPS}"
FUZZ_RC_SLOTS="${RC_FUZZ_RC_SLOTS:-$DEFAULT_RC_SLOTS}"
FUZZ_WEAK_SLOTS="${RC_FUZZ_WEAK_SLOTS:-$DEFAULT_WEAK_SLOTS}"

run_lane() {
  local lane_name="$1"
  local opt_level="$2"
  local sanitize="$3"
  local lane_base_seed="$4"

  echo ""
  echo "==> $lane_name (RC_OPT_LEVEL=$opt_level RC_SANITIZE=$sanitize)"

  CARP_DIR="$CARP_DIR_ROOT" \
  RC_OPT_LEVEL="$opt_level" \
  RC_SANITIZE="$sanitize" \
  "$CARP_BIN" "$RC_TEST" -x --log-memory --no-profile

  for fuzz_target in "$RC_FUZZ_TEST_STRING" "$RC_FUZZ_TEST_ARRAY_STRING" "$RC_FUZZ_TEST_PROBE"; do
    echo "--> fuzz target: $(basename "$fuzz_target")"
    CARP_DIR="$CARP_DIR_ROOT" \
    RC_OPT_LEVEL="$opt_level" \
    RC_SANITIZE="$sanitize" \
    RC_FUZZ_RUNS="$FUZZ_RUNS" \
    RC_FUZZ_STEPS="$FUZZ_STEPS" \
    RC_FUZZ_RC_SLOTS="$FUZZ_RC_SLOTS" \
    RC_FUZZ_WEAK_SLOTS="$FUZZ_WEAK_SLOTS" \
    RC_FUZZ_BASE_SEED="$lane_base_seed" \
    RC_FUZZ_SEED_STRIDE="$SEED_STRIDE" \
    RC_FUZZ_RANDOM_SEED="$RANDOM_SEED" \
    "$CARP_BIN" "$fuzz_target" -x --log-memory --no-profile
  done
}

echo "Running rc validation matrix"
echo "profile=$PROFILE runs=$FUZZ_RUNS steps=$FUZZ_STEPS rc_slots=$FUZZ_RC_SLOTS weak_slots=$FUZZ_WEAK_SLOTS"

run_lane "sanitized lane" "O1" "1" "$BASE_SEED"
run_lane "release lane" "O2" "0" "$BASE_SEED_O2"

if [[ "$RUN_O3" == "1" || "$RUN_O3" == "true" || "$RUN_O3" == "yes" ]]; then
  run_lane "optimizer-stress lane" "O3" "0" "$BASE_SEED_O3"
fi

echo ""
echo "rc validation matrix passed"
