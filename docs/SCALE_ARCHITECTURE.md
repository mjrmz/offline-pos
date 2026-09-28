# System Architecture — Scaling to Millions of Installs

## The reframe

A cloud SaaS scales by handling more concurrent requests against shared
infrastructure. modern-offline-pos scales differently: **every install is an
independent, isolated system**. "Millions of users" here means millions of
autonomous devices, each running the full app locally, most of which will
never make a network request after activation.

This means the usual scaling concerns (load balancers, read replicas,
horizontal pod autoscaling for the app itself) don't apply to the client at
all. What actually needs "production-grade, handles volume" engineering:

## 1. The client app — correctness at volume, not throughput

At 1,000 installs, a rare bug affects a few customers. At 1,000,000, the same
bug affects thousands simultaneously, with no telemetry unless you built for
it. The engineering bar is:

- **Every schema migration must be forward-safe and tested against real
  aged databases**, not just fresh installs — a store on version 1.2 with
  three years of sales history must migrate as reliably as a brand new
  install.
- **Every write is transactional** (see docs/DATABASE_SCHEMA.md) — this
  doesn't change with scale, it just means a rollback bug that appears at
  low frequency in testing becomes a routine occurrence at volume.
- **Local telemetry, opt-in and privacy-respecting**: a lightweight,
  non-blocking crash/error report queued locally and sent only when the
  device happens to have internet (e.g. during a license check or update
  check) — the only way to know a bug exists across a fleet you otherwise
  never hear from.
- **Update distribution**: staged rollout capability (see `UPDATE_STRATEGY`
  section below) so a bad release doesn't hit 100% of installs before
  you notice.

## 2. The License API — the one real multi-tenant backend

This is a genuine cloud service that needs standard backend scaling
practice, because it does get concurrent load — every activation,
reactivation, and (optionally) periodic license refresh hits it.

```
                     ┌─────────────────────────┐
                     │   Load Balancer          │
                     └────────────┬─────────────┘
                                  │
             ┌────────────────────┼────────────────────┐
             ▼                    ▼                     ▼
     ┌───────────────┐   ┌───────────────┐    ┌───────────────┐
     │ License API    │   │ License API    │    │ License API    │
     │ instance       │   │ instance       │    │ instance       │
     └───────┬────────┘   └───────┬────────┘    └───────┬────────┘
             │                    │                     │
             └────────────────────┼────────────────────┘
                                  ▼
                     ┌─────────────────────────┐
                     │  PostgreSQL (primary +   │
                     │  read replica for        │
                     │  admin dashboard reads)  │
                     └─────────────────────────┘
```

- **Stateless API instances** behind a load balancer — horizontally
  scalable by design, since activation requests are independent and
  short-lived.
- **PostgreSQL with a read replica** once volume justifies it — admin
  dashboard analytics (customer counts, activation trends) read from the
  replica, never competing with live activation writes.
- **Rate limiting per device ID and per IP** on the activation endpoint —
  this is a low-traffic-per-device but high-total-volume endpoint;
  protect it from abuse without punishing legitimate customers.
- **This service being down never affects an already-activated device** —
  the core offline guarantee. Scaling this service is about handling
  *growth* in new activations, not about keeping existing customers'
  tills running.

## 3. Update strategy at volume

- Staged rollout: new version flagged as available to a percentage of
  devices first (via a simple version-check response from a lightweight
  endpoint), full rollout only after a soak period
- Devices check for updates opportunistically (e.g. on app start, if
  online) and never block normal operation on the check succeeding
- Each platform's native distribution (Play Store staged rollout, direct
  `.exe` installer versioning) layered on top of this for the actual
  binary delivery

## What does NOT need to scale here

- There is no shared application server for the POS app itself
- There is no shared database for business data (sales, inventory) — by
  design, this never becomes a bottleneck because it doesn't exist
- There is no "concurrent user" limit to worry about for checkout
  performance — each till only ever talks to its own local SQLite file
