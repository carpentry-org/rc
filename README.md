# rc

`rc` is a standalone Carp library that provides macro-generated reference-counted
types with weak references:

- strong handles (`RcX`)
- weak handles (`RcXWeak`)
- structural sharing by pointer identity
- explicit ownership semantics through generated `copy`/`delete` behavior

The entrypoint is `Rc.define`, which generates a concrete pair of managed types
for one payload type.

## Status

Current status:

- feature complete for single-threaded reference counting
- includes strong + weak refs
- includes sanitizers and fuzz harnesses in `test/`
- not atomic/thread-safe
- fail-fast runtime guards for refcount overflow/underflow and cross-thread use
- matches Rust-style `Rc`/`Weak` cycle behavior (no automatic cycle collection)

Important semantic note:

- payload is dropped when the strong count reaches zero
- the control block remains while weak refs exist
- allocation free still happens when both strong and weak counts reach zero

This matches Rust `Rc`/`Weak` lifetime behavior.

## Layout

Project structure:

- `rc.carp`: library source
- `README.md`: usage and API docs
- `test/fuzz_harness.carp`: generic fuzz runner/env helpers
- `test/rc.carp`: functional + lifecycle tests
- `test/rc_fuzz.carp`: state-machine fuzz tests for `RcString`
- `test/rc_fuzz_array_string.carp`: state-machine fuzz tests for `RcArrayString`
- `test/rc_fuzz_probe.carp`: state-machine fuzz tests for `RcProbe`
- `docs/design.md`: implementation internals and invariants
- `docs/testing.md`: test matrix and fuzzing guidance

## Installation

Load from a git source in Carp's standard library-loading style:

```clojure
(load "git@github.com:carpentry-org/rc@0.1.0")
```

Use release tags when possible for reproducible builds.

## Quick Start

Instantiate one specialization:

```clojure
(Rc.define RcString String)
```

This generates:

- type `RcString`
- type `RcStringWeak`
- module `RcString`
- module `RcStringWeak`
- managed `copy`/`delete` implementations for both types

Minimal example:

```clojure
(Rc.define RcString String)

(let [a (RcString.new @"hello")
      b (RcString.clone &a)]
  (do
    (IO.println &(RcString.str &a))
    (IO.println &(str (RcString.get &b)))
    (IO.println &(Long.str (RcString.strong-count &a)))))
```

Weak example:

```clojure
(Rc.define RcString String)

(let [a (RcString.new @"hello")
      w (RcString.downgrade &a)]
  (match (RcStringWeak.upgrade &w)
    (Maybe.Just a2) (IO.println &(RcString.str &a2))
    (Maybe.Nothing) (IO.println @"expired")))
```

## Mental Model

Each allocation stores:

- `strong : Long`
- `weak : Long`
- `value : (Ptr T)` (cleared when strong reaches zero)
- `owner-thread : Long` (thread affinity guard for single-threaded usage)
- `magic : Long` (control-block integrity guard)

Behavior:

- cloning/copying strong handles increments `strong`
- downgrading increments `weak`
- upgrading weak to strong increments `strong` only if `strong > 0`
- strong deletion decrements `strong`
- weak deletion decrements `weak`
- payload drop happens at `strong=0`
- final control-block free happens when both reach zero

This gives pointer-stable sharing and cheap cloning, with semantics explicit
through value ownership.

## API Reference

Assume:

```clojure
(Rc.define RcT T)
```

Generated strong module: `RcT`

- `new : (Fn [T] RcT)`
  - allocates a new cell with `strong=1, weak=0`
- `copy : (Fn [(Ref RcT q)] RcT)`
  - increments strong count and returns same pointer
  - called implicitly by `@&x` patterns where needed
- `clone : (Fn [(Ref RcT q)] RcT)`
  - alias of `copy`
- `delete : (Fn [RcT] ())`
  - decrements strong count
  - drops payload at `strong=0`
  - frees control block when resulting `strong=0` and `weak=0`
- `strong-count : (Fn [(Ref RcT q)] Long)`
  - returns current strong count (0 for null)
- `weak-count : (Fn [(Ref RcT q)] Long)`
  - returns current weak count (0 for null)
- `unique? : (Fn [(Ref RcT q)] Bool)`
  - true iff `strong-count == 1`
- `ptr-eq : (Fn [(Ref RcT q) (Ref RcT r)] Bool)`
  - pointer identity comparison
- `get : (Fn [(Ref RcT q)] T)`
  - returns `value` by copy semantics
  - may trigger payload copy for managed payloads
- `try-unwrap : (Fn [RcT] (Result T RcT))`
  - success when uniquely owned
  - on success, moves payload out without payload-delete
  - error returns original `RcT` unchanged when shared
- `unwrap : (Fn [RcT] T)`
  - success path of `try-unwrap`
  - moves payload out on success
  - aborts on shared value
- `unwrap-or-clone : (Fn [RcT] T)`
  - unwraps when unique
  - otherwise copies payload through `get`
- `make-unique : (Fn [RcT] RcT)`
  - returns input unchanged when unique
  - otherwise detaches by cloning payload into a new cell and decrementing old
- `downgrade : (Fn [(Ref RcT q)] RcTWeak)`
  - creates weak handle to same cell
- `str : (Fn [(Ref RcT q)] String)`
  - diagnostic format with counts

Generated weak module: `RcTWeak`

- `new : (Fn [] RcTWeak)`
  - creates an empty/expired weak handle (no allocation, no refcount change)
- `copy : (Fn [(Ref RcTWeak q)] RcTWeak)`
  - increments weak count and returns same pointer
- `clone : (Fn [(Ref RcTWeak q)] RcTWeak)`
  - alias of `copy`
- `delete : (Fn [RcTWeak] ())`
  - decrements weak count
  - frees control block if resulting `weak=0` and `strong=0`
- `strong-count : (Fn [(Ref RcTWeak q)] Long)`
  - reads strong count via weak
- `weak-count : (Fn [(Ref RcTWeak q)] Long)`
  - reads weak count
- `expired? : (Fn [(Ref RcTWeak q)] Bool)`
  - true iff `strong-count == 0`
- `alive? : (Fn [(Ref RcTWeak q)] Bool)`
  - true iff `strong-count > 0`
- `upgrade : (Fn [(Ref RcTWeak q)] (Maybe RcT))`
  - `Maybe.Just` when `strong > 0`, incrementing strong
  - `Maybe.Nothing` when expired
- `ptr-eq : (Fn [(Ref RcTWeak q) (Ref RcTWeak r)] Bool)`
  - pointer identity comparison
- `str : (Fn [(Ref RcTWeak q)] String)`
  - diagnostic format with counts

## Ownership Notes

`Rc` has value-like handles, so these are important:

- `get` returns by value and may copy payload data
- `try-unwrap`/`unwrap` move payload out on the unique-success path
- `unwrap-or-clone` may copy payload when shared
- `make-unique` decrements old strong then allocates a new cell when shared
- `Weak.upgrade` returns a fresh strong handle with incremented strong count

Null paths:

- internals defensively handle null pointers for counters and upgrade
- user code should still treat handles as valid managed values, not nullable raw pointers

## Structural Sharing Patterns

Typical usage:

- persistent linked nodes as `Rc Node`
- trees with shared subtrees via `Rc`
- parent pointers as `Weak` to avoid strong cycles in DAG-like structures

Example persistent node:

```clojure
(deftype Node [value Int next (Maybe RcNode)])
(Rc.define RcNode Node)
```

With this pattern, cloning head pointers is cheap and preserves sharing.

## Threading and Safety

Current implementation is explicitly:

- non-atomic
- single-threaded
- not safe for concurrent shared mutation across threads
- guarded: using one control block from a different thread aborts immediately

Do not use these handles concurrently without an external synchronization and
threading story in Carp runtime.

## Known Limitations

- alpha quality (`0.1.0`): API and behavior may still change
- non-atomic and single-threaded only (not thread-safe)
- no allocator pluggability yet
- weak API is intentionally minimal: `new`, counts, `expired?`/`alive?`, `upgrade`, and pointer equality
- forged handles created with `Unsafe.coerce` are out of contract; public APIs abort on invalid control-block magic/thread-owner mismatches

## Testing

Functional tests:

```sh
carp -x test/rc.carp
```

Fuzz tests:

```sh
carp -x test/rc_fuzz.carp
carp -x test/rc_fuzz_array_string.carp
carp -x test/rc_fuzz_probe.carp
```

The test harness enables:

- `-fsanitize=address`
- `-fsanitize=undefined`
- `-fno-sanitize-recover=all`
- memory-balance assertions via `Debug.memory-balance`

See generated testing docs at `docs/Testing.html` and detailed markdown notes in
`docs/testing.md`.

Build/test flags can be controlled by environment variables:

- `RC_OPT_LEVEL` accepts `O0|O1|O2|O3` (default `O1`)
- `RC_SANITIZE` accepts `1|true|yes` or `0|false|no` (default enabled)

## Fuzz Configuration

All fuzz suites support runtime knobs:

- `RC_FUZZ_RUNS` default `12`
- `RC_FUZZ_STEPS` default `400`
- `RC_FUZZ_RC_SLOTS` default `8`
- `RC_FUZZ_WEAK_SLOTS` default `8`
- `RC_FUZZ_BASE_SEED` default `1001.0`
- `RC_FUZZ_SEED_STRIDE` default `9973.0`
- `RC_FUZZ_RANDOM_SEED` set to `1|true|yes` to seed from `System.nanotime`

Example long soak:

```sh
RC_FUZZ_RUNS=200 RC_FUZZ_STEPS=2000 RC_FUZZ_RANDOM_SEED=1 \
  carp -x test/rc_fuzz.carp
```

Example array payload soak:

```sh
RC_FUZZ_RUNS=200 RC_FUZZ_STEPS=2000 RC_FUZZ_RANDOM_SEED=1 \
  carp -x test/rc_fuzz_array_string.carp
```

Example probe payload soak:

```sh
RC_FUZZ_RUNS=200 RC_FUZZ_STEPS=2000 RC_FUZZ_RANDOM_SEED=1 \
  carp -x test/rc_fuzz_probe.carp
```

## Validation Script

Run the full validation matrix from `doing/rc`:

```sh
./scripts/validate.sh
```

`validate.sh` runs `test/rc.carp` plus all fuzz suites in each lane.

Matrix lanes:

- sanitized `O1`
- unsanitized `O2`
- optional unsanitized `O3` (`RC_VALIDATE_RUN_O3=0` to disable)

Useful overrides:

- `RC_VALIDATE_PROFILE=quick|ci|soak`
- `RC_FUZZ_RUNS`, `RC_FUZZ_STEPS`, `RC_FUZZ_RC_SLOTS`, `RC_FUZZ_WEAK_SLOTS`
- `RC_VALIDATE_RANDOM_SEED=1` for non-deterministic exploration
- `CARP_BIN` to choose a specific `carp` executable
- `CARP_DIR` to point at the Carp core directory (defaults to `../../carp`)

Example deterministic reproduction:

```sh
RC_FUZZ_RUNS=80 RC_FUZZ_STEPS=1500 RC_FUZZ_BASE_SEED=4242.0 RC_FUZZ_SEED_STRIDE=37.0 \
  carp -x test/rc_fuzz.carp
```

The same fuzz env vars apply to `test/rc_fuzz_array_string.carp` and
`test/rc_fuzz_probe.carp`.

## Design and Testing Docs

Generated docs:

- API module: `docs/Rc.html`
- design overview: `docs/Design.html`
- testing overview: `docs/Testing.html`
- docs index: `docs/rc_index.html`

Extended markdown docs:

- implementation internals: `docs/design.md`
- testing and fuzzing details: `docs/testing.md`

## API Docs Generation

This library follows the standard Carp doc-generation workflow via
`gendocs.carp`:

```sh
CARP_DIR=/path/to/carp/compiler-repo carp -x gendocs.carp
```

That regenerates:

- `docs/Rc.html`
- `docs/Design.html`
- `docs/Testing.html`
- `docs/rc_index.html`

<hr/>

Have fun!
