# rc Testing Guide

This document covers validation strategy for `rc`, including deterministic
tests, sanitizer configuration, and fuzzing workflows.

## Test Suites

The library ships with these test suites:

- `test/rc.carp`
  - focused behavior tests for strong/weak operations
  - lifecycle and memory-balance checks
  - guardrail checks for forged-handle rejection (`assert-signal` on abort path)
  - explicit regression checks that payload drops at `strong=0` even if weak refs remain
- `test/rc_fuzz.carp`
  - state-machine fuzzing across strong/weak operation mixes for `RcString`
  - invariant checks on every step
  - memory-balance validation
- `test/rc_fuzz_array_string.carp`
  - state-machine fuzzing for `RcArrayString`
  - invariant checks on every step
  - memory-balance validation
- `test/rc_fuzz_probe.carp`
  - state-machine fuzzing for `RcProbe` (`DropProbe` payload)
  - invariant checks on every step
  - memory-balance validation
- `test/fuzz_harness.carp`
  - reusable fuzz helpers used by all fuzz suites
  - env parsing + deterministic seed progression + generic run loops

## Sanitizers

All suites enable:

- AddressSanitizer: `-fsanitize=address`
- UndefinedBehaviorSanitizer: `-fsanitize=undefined`
- hard fail on sanitizer issue: `-fno-sanitize-recover=all`
- stable stack traces: `-fno-omit-frame-pointer`

This setup is intentional. It catches:

- use-after-free
- invalid frees
- out-of-bounds access
- undefined integer/ptr behavior captured by UBSan

Build flags are configurable:

- `RC_OPT_LEVEL`: `O0|O1|O2|O3` (default `O1`)
- `RC_SANITIZE`: `1|true|yes` to enable sanitizers, `0|false|no` to disable (default enabled)

## Running Tests

From the `doing/rc` directory:

```sh
carp -x test/rc.carp
carp -x test/rc_fuzz.carp
carp -x test/rc_fuzz_array_string.carp
carp -x test/rc_fuzz_probe.carp
```

Full matrix run (from `doing/rc`):

```sh
./scripts/validate.sh
```

`validate.sh` runs `test/rc.carp` and all three fuzz suites in each lane.

Optional script overrides:

- `CARP_BIN` to select a specific `carp` executable
- `CARP_DIR` to select the Carp core directory

Use `--check` for compile-only validation.

## Memory-Balance Assertions

Tests use:

- `Debug.reset-memory-balance!`
- `Debug.memory-balance`

Expected behavior:

- balanced scenarios must end at `0l`
- known leak scenarios should be modeled explicitly when testing negative cases

For `rc`, all lifecycle tests in shipped suites are expected to end balanced.

## Fuzz Harness Model

Each fuzz suite models pools of:

- `Maybe Rc*` strong slots
- `Maybe Rc*Weak` weak slots

Random operations include:

- create/clone/drop strong refs
- create empty weak refs (`Weak.new`)
- create/clone/drop weak refs
- upgrade weak refs
- `make-unique`
- `try-unwrap`
- unique-gated `unwrap` probes
- `unwrap-or-clone` probes
- pointer-equality probes
- burst cloning/downgrading
- full pool clears

After every operation, invariants are checked.
These include `alive? == (not expired?)` for weak handles.

## Fuzz Runtime Parameters

Set with environment variables:

- `RC_FUZZ_RUNS`
- `RC_FUZZ_STEPS`
- `RC_FUZZ_RC_SLOTS`
- `RC_FUZZ_WEAK_SLOTS`
- `RC_FUZZ_BASE_SEED`
- `RC_FUZZ_SEED_STRIDE`
- `RC_FUZZ_RANDOM_SEED`

Defaults are encoded in each fuzz suite.

Numeric fuzz knobs are clamped in-harness to avoid accidental extreme runs from
typos:

- `RC_FUZZ_RUNS <= 100000`
- `RC_FUZZ_STEPS <= 200000`
- `RC_FUZZ_RC_SLOTS <= 10000`
- `RC_FUZZ_WEAK_SLOTS <= 10000`

## Recommended Profiles

Quick pre-commit smoke:

```sh
RC_FUZZ_RUNS=20 RC_FUZZ_STEPS=600 carp -x test/rc_fuzz.carp
```

```sh
RC_FUZZ_RUNS=20 RC_FUZZ_STEPS=600 carp -x test/rc_fuzz_array_string.carp
```

```sh
RC_FUZZ_RUNS=20 RC_FUZZ_STEPS=600 carp -x test/rc_fuzz_probe.carp
```

CI-grade stress:

```sh
RC_FUZZ_RUNS=80 RC_FUZZ_STEPS=1500 RC_FUZZ_RC_SLOTS=16 RC_FUZZ_WEAK_SLOTS=16 \
  carp -x test/rc_fuzz.carp
```

```sh
RC_FUZZ_RUNS=80 RC_FUZZ_STEPS=1500 RC_FUZZ_RC_SLOTS=16 RC_FUZZ_WEAK_SLOTS=16 \
  carp -x test/rc_fuzz_array_string.carp
```

```sh
RC_FUZZ_RUNS=80 RC_FUZZ_STEPS=1500 RC_FUZZ_RC_SLOTS=16 RC_FUZZ_WEAK_SLOTS=16 \
  carp -x test/rc_fuzz_probe.carp
```

Long soak:

```sh
RC_FUZZ_RUNS=300 RC_FUZZ_STEPS=3000 RC_FUZZ_RC_SLOTS=32 RC_FUZZ_WEAK_SLOTS=32 \
RC_FUZZ_RANDOM_SEED=1 carp -x test/rc_fuzz.carp
```

```sh
RC_FUZZ_RUNS=300 RC_FUZZ_STEPS=3000 RC_FUZZ_RC_SLOTS=32 RC_FUZZ_WEAK_SLOTS=32 \
RC_FUZZ_RANDOM_SEED=1 carp -x test/rc_fuzz_array_string.carp
```

```sh
RC_FUZZ_RUNS=300 RC_FUZZ_STEPS=3000 RC_FUZZ_RC_SLOTS=32 RC_FUZZ_WEAK_SLOTS=32 \
RC_FUZZ_RANDOM_SEED=1 carp -x test/rc_fuzz_probe.carp
```

Deterministic reproduction of a failure:

```sh
RC_FUZZ_RUNS=1 RC_FUZZ_STEPS=50000 RC_FUZZ_BASE_SEED=12345.0 RC_FUZZ_SEED_STRIDE=1.0 \
  carp -x test/rc_fuzz.carp
```

```sh
RC_FUZZ_RUNS=1 RC_FUZZ_STEPS=50000 RC_FUZZ_BASE_SEED=12345.0 RC_FUZZ_SEED_STRIDE=1.0 \
  carp -x test/rc_fuzz_array_string.carp
```

```sh
RC_FUZZ_RUNS=1 RC_FUZZ_STEPS=50000 RC_FUZZ_BASE_SEED=12345.0 RC_FUZZ_SEED_STRIDE=1.0 \
  carp -x test/rc_fuzz_probe.carp
```

## Reproducibility Notes

For reproducible runs:

- keep `RC_FUZZ_RANDOM_SEED` unset
- pin `RC_FUZZ_BASE_SEED` and `RC_FUZZ_SEED_STRIDE`
- record these values in failure logs

For broad exploration:

- set `RC_FUZZ_RANDOM_SEED=1`
- increase runs/steps/slot counts

## Known Harness Caveat

When using `./scripts/carp.sh` in the Carp compiler repository, avoid launching
multiple test binaries in parallel that share the same `out/main.c` output path.

Parallel invocations can overwrite generated C and produce confusing compile
errors unrelated to library correctness.

Use sequential execution for reliable results.

## Suggested CI Strategy

A pragmatic matrix:

- sanitized lane at `-O1` (`RC_SANITIZE=1`)
- release lane at `-O2` (`RC_SANITIZE=0`)
- optional optimizer-stress lane at `-O3` (`RC_SANITIZE=0`)
- nightly long-soak profile with random seed
- fail hard on any sanitizer warning

This combination gives strong regression coverage without making every PR slow.
