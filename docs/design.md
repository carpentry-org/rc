# rc Design Notes

This document explains the implementation details of `rc.carp` and the
tradeoffs behind its current semantics.

## Overview

`Rc.define` is a macro that generates concrete strong/weak handle types for one
payload type:

```clojure
(Rc.define RcString String)
```

This expansion creates:

- opaque handle type `RcString` (`void*`)
- opaque handle type `RcStringWeak` (`void*`)
- internal cell type `RcStringCell`
- module `RcString` with strong-handle functions
- module `RcStringWeak` with weak-handle functions

Each handle points to the same heap cell.

## Internal Cell Layout

For payload type `T`, the generated cell shape is:

```clojure
(deftype RcTCell
  [strong Long
   weak Long
   value (Ptr T)
   owner-thread Long
   magic Long])
```

Meaning:

- `strong`: number of live strong handles
- `weak`: number of live weak handles
- `value`: payload pointer, cleared after payload drop
- `owner-thread`: thread id captured at allocation; used for single-thread guardrails
- `magic`: integrity tag used to reject forged/corrupt control blocks

## Handle Representation

Both `RcT` and `RcTWeak` are registered as `void*` and cast through helper
functions:

- `from-ref`: converts `&RcT` / `&RcTWeak` into handle value
- `cell-ptr`: obtains typed pointer to `RcTCell`

The library uses controlled `Unsafe.coerce` and `Pointer.to-ref`/`to-value`
casts around these opaque pointers.

The generated cell type and low-level helpers are hidden/private implementation
details and are not part of the public API.

## Operation Semantics

### Strong operations

- `new`
  - allocates one cell
  - initializes counts to `strong=1`, `weak=0`
- `copy` / `clone`
  - increments `strong`
  - returns same pointer
- `delete`
  - decrements `strong`
  - if resulting `strong=0`:
    - payload is dropped immediately
    - free cell immediately if `weak=0`
    - otherwise keep control block alive with `strong=0`

### Weak operations

- `new`
  - creates an empty/expired weak handle (`NULL` internal pointer)
  - no allocation and no refcount changes
- `downgrade`
  - increments `weak`
  - returns same pointer as `RcTWeak`
- `copy` / `clone`
  - increments `weak`
- `alive?`
  - convenience predicate for `strong > 0`
- `upgrade`
  - if `strong>0`, increments `strong` and returns `Maybe.Just RcT`
  - if `strong=0`, returns `Maybe.Nothing`
- `delete`
  - decrements `weak`
  - if resulting `weak=0` and `strong=0`, frees the cell

## Lifetime Behavior

Current behavior:

- payload is dropped at strong-zero
- control block remains while weak refs exist
- control block free happens only when both counts hit zero

This matches Rust-style `Rc`/`Weak` lifetime behavior.

## Invariants

Core runtime invariants:

- `strong >= 0`
- `weak >= 0`
- `magic == Rc.cell-magic-live` while the control block is alive
- all public operations on non-null handles must run on `owner-thread`
- upgraded weak must observe `strong > 0` before incrementing
- if `strong == 0` and `weak == 0`, cell must be freed exactly once
- no operation may decrement below zero

Test/fuzz invariants mirror this:

- strong handles always report `strong > 0`
- `unique?` iff `strong == 1`
- weak handles report `weak >= 1` when they point to a live control block
- `Weak.new` reports `strong=0`, `weak=0`, `expired?=true`, `alive?=false`
- `expired?` iff `strong == 0`
- `alive?` iff `not expired?`
- successful `upgrade` returns pointer-equal strong handle

## Complexity

Time complexity:

- O(1): `copy`, `clone`, `delete`, `downgrade`, `upgrade`, counters, `ptr-eq`
- O(size(T)) potential copy: `get`, `unwrap-or-clone`
- O(1) move on success: `try-unwrap`, `unwrap`
- O(size(T)) + allocation: `make-unique` when shared

Space:

- one cell per root allocation
- extra weak/strong handles are pointer copies + refcount updates

## Safety and Non-Goals

Current non-goals:

- no thread-safety or atomic counters
- no cycle collection
- no lock-free semantics

Because counters are non-atomic, this implementation is only valid in a
single-threaded context. Runtime checks enforce this by aborting on
cross-thread access to a live control block.

Handle validity contract:

- public APIs assume handles were created by `Rc.new`, `Rc.clone`, `Rc.downgrade`,
  or `Weak.upgrade`
- forging handles with `Unsafe.coerce` is out of contract
- invalid/forged pointers are rejected by control-block magic checks when readable
- refcount overflow/underflow aborts immediately via fail-fast guards

Important for any future atomic/thread-safe port:

- current strong-drop/free checks rely on single-threaded sequencing
- do not mechanically replace counters with atomics without redesigning
  strong/weak zero transitions and free ownership

## Why Macro-Generated Concrete Types

Benefits:

- each specialization has concrete signatures
- no runtime type tags or boxed existential values
- easy to integrate with Carp managed `copy`/`delete` behavior
- straightforward C emission and sanitizer visibility

Tradeoff:

- code generation size grows with number of instantiations

## Extension Points

Potential future work:

- optional thread-safe atomic mode
- configurable allocator hooks
- debug counters / tracing hooks
- cycle-breaking helpers for common graph patterns
