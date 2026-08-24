---
status: draft
---

# Swarm implementation plan

<!--
  This file is the hand-off from planning to the autonomous DV swarm.

  Workflow:
    1. Fill in the sections below with the change to build (do this WITH your
       planning session — get the requirement and approach nailed down first).
    2. When it is ready to implement, set `status: ready` in the front-matter above.
    3. Push it to `main`.  The "Plan swarm" workflow
       (.github/workflows/plan-swarm.yml) then runs the DV swarm, which implements
       this plan, gets `make regress` green (coverage >= 85%), and opens a PR.
    4. Review and merge that PR.  Set `status` back to `draft` for the next cycle.

  `status: draft` is ignored; only `status: ready` triggers implementation on a
  push to main.  You can also run it on demand from the Actions "Run workflow"
  button regardless of status.  See docs/DOCKER.md -> "Plan-driven swarm".
-->

## Goal

_What to build — the requirement, in a few sentences._

## Scope & files

_Which RTL / testbench / DV / other files to add or change, and roughly how._

## Acceptance

_How we know it is done: which DV environments must be green, coverage floor,
and any specific behavioral checks or assertions the swarm must satisfy._

## Notes / constraints

_Anything the swarm must respect — interfaces to keep stable, things NOT to
touch, spec references, risky areas to flag rather than guess._
