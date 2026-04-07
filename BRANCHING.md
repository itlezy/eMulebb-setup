# Canonical Branching Strategy

This document is the source of truth for the active branching model used by the
canonical eMule workspace.

It defines the live workflow only. Historical `v0.60*` lines and `stale/*`
branches remain available as archive history, but they are not part of the
active development strategy.

## Active Branch Classes

### `main`

`main` is the only integration branch.

- all new development lands here first
- all non-trivial work should happen on short-lived branches cut from `main`
- `main` should remain buildable and reviewable

### Short-lived feature branches

Short-lived working branches are allowed and expected for meaningful work.

Recommended naming:

- `feature/<topic>`
- `fix/<topic>`
- `chore/<topic>`

Rules:

- branch from `main`
- keep them short-lived
- merge back to `main`
- do not treat them as canonical workspace branches

### Release branches

The active release lines are:

- `release/v0.72a-build`
- `release/v0.72a-bugfix`
- `release/v0.72a-broadband`

These are stabilization branches, not alternate development trunks.

Rules:

- they are promoted from reviewed commits already present on `main`
- they are used for validation, release-hardening, and comparison/oracle roles
- do not land normal feature work directly on them
- if release validation finds an issue, fix it on a short-lived branch from `main`,
  merge back to `main`, then re-promote the corrected commit

### `stale/*`

`stale/*` branches are retired historical references only.

- never use them as active development targets
- never use them as setup materialization targets
- never use them as current validation or release baselines unless a document
  explicitly calls out a historical comparison exercise

## Merge Strategy

The default merge strategy back to `main` is squash merge.

Why:

- `main` history stays curated and readable
- branch-internal cleanup does not need to be perfect
- the squash commit message becomes the canonical change summary

Normal practice:

- develop on a short-lived branch
- review the branch
- squash merge to `main`

Direct commits to `main` should be reserved for very small administrative
changes.

## History Hygiene

`main` should read like curated project history, not like a work log.

Rules:

- one `main` commit should represent one coherent outcome
- do not push `WIP`, checkpoint, or debug commits to `main`
- do not split one logical change into multiple follow-up `main` commits unless
  the split is intentionally meaningful
- do not mix unrelated behavior, docs, and hygiene work in one commit unless the
  repo sweep is explicitly intentional

Use a short-lived branch for any non-trivial change, then squash merge it back
to `main`.

Direct commits to `main` are acceptable only for very small changes such as:

- tiny administrative updates
- branch or tag housekeeping
- trivial doc fixes
- one-line metadata or policy corrections

Even for direct `main` commits:

- keep the commit single-purpose
- avoid immediate follow-up correction commits for the same logical change

If a change is only completing the previous unpushed commit, fold it in before
pushing instead of stacking another `main` commit on top.

## Promotion Strategy

Promotion flows from `main` to release branches.

The intended direction is:

- `main` -> `release/v0.72a-build`
- `main` -> `release/v0.72a-bugfix`
- `main` -> `release/v0.72a-broadband`

Promotion is a deliberate selection of a reviewed `main` commit for
stabilization. Release branches are downstream of `main`; they are not places to
start independent feature lines.

## Tags

Branches are moving stabilization lines. Official releases should be marked with
annotated tags on the chosen release-branch commit.

Recommended tag families:

- `v0.72a-build.N`
- `v0.72a-bugfix.N`
- `v0.72a-broadband.N`

Rules:

- use annotated tags
- tag the exact promoted release commit
- keep the tag family consistent once chosen

## Workspace Mapping

The canonical workspace currently materializes these app worktrees:

- `eMule-main` -> `main`
- `eMule-v0.72a-build` -> `release/v0.72a-build`
- `eMule-v0.72a-bugfix` -> `release/v0.72a-bugfix`

`release/v0.72a-broadband` is part of the active branching strategy, but it is
not materialized as a canonical worktree until setup/build orchestration is
explicitly extended to support it.

## Repo Scope

This full strategy applies to the app repo.

For the supporting repos:

- `eMule-build`
- `eMule-build-tests`
- `eMule-tooling`
- `eMule-remote`

the active branch is `main`, with short-lived feature branches allowed for work.
No long-lived release branches are part of the active model there today.
