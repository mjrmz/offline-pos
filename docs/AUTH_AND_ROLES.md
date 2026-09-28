# Offline Authentication & Roles

All authentication is local — checked against the on-device SQLite database.
No internet connection is required to log in, ever.

## Login methods

- **Cashier**: fast PIN entry (4-6 digits) + select their name from a list.
  Optimized for quick shift handoff at a busy till.
- **Admin / Owner**: full password login, not PIN — these accounts can void,
  refund, adjust inventory, and change settings, so they warrant stronger
  auth.
- **Quick-swap**: allow locking the register and switching cashiers without
  closing the whole app.

## Roles & permissions

| Role | Can do |
|---|---|
| Cashier | Sell, reprint receipts, view own transactions |
| Manager | Everything Cashier can, plus: void, refund, adjust inventory, view reports |
| Owner / Admin | Everything Manager can, plus: manage users, settings, backup, restore, full reports |

## Password / PIN storage

- Hash all credentials locally (bcrypt or Argon2). Never store plaintext.
- PINs are still hashed, not stored in the clear, even though they're short.

## Account lockout

- Lock out after a reasonable number of failed attempts to prevent
  brute-forcing the till.
- Don't lock out so aggressively that a fumbling cashier can brick the
  register mid-shift — pair short lockouts with an admin override.

## Offline password recovery

This is the hard case: no internet means no "reset link via email." Design
one of:

- Security questions configured during initial setup.
- A recovery code generated at activation time, tied to the signed license,
  that can unlock a password reset locally.

Without one of these, a forgotten admin password on an offline device has no
recovery path at all.

## Audit logging

Every login, logout, and failed attempt is written to `AuditLogs` — who,
when, from which role — regardless of connectivity. This is what resolves
disputes later ("who voided this sale," "who was logged in during the
shortfall").
