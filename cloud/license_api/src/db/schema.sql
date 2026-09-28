-- cloud/license_api/src/db/schema.sql
--
-- PostgreSQL schema for the License API. This database holds licensing
-- metadata ONLY — no customer business data (sales, inventory, products)
-- ever touches this database. See docs/LICENSING.md.

CREATE TABLE customers (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_name TEXT NOT NULL,
    contact_email TEXT,
    contact_phone TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE plans (
    id               TEXT PRIMARY KEY, -- 'non_bir' | 'bir_ready'
    display_name     TEXT NOT NULL,
    max_devices      INT NOT NULL,
    price_cents      INT NOT NULL
);

INSERT INTO plans (id, display_name, max_devices, price_cents) VALUES
    ('non_bir', 'Non-BIR', 1, 2500000),
    ('bir_ready', 'BIR-Ready', 1, 3500000);

CREATE TABLE licenses (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id     UUID NOT NULL REFERENCES customers(id),
    plan_id         TEXT NOT NULL REFERENCES plans(id),
    activation_key  TEXT NOT NULL UNIQUE,
    status          TEXT NOT NULL DEFAULT 'unactivated', -- unactivated | active | revoked
    max_devices     INT NOT NULL,
    issued_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at      TIMESTAMPTZ -- null = perpetual
);

CREATE INDEX idx_licenses_activation_key ON licenses(activation_key);

CREATE TABLE devices (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    license_id        UUID NOT NULL REFERENCES licenses(id),
    device_fingerprint TEXT NOT NULL,
    status            TEXT NOT NULL DEFAULT 'active', -- active | deactivated
    activated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    deactivated_at    TIMESTAMPTZ,
    UNIQUE (license_id, device_fingerprint)
);

CREATE INDEX idx_devices_license_id ON devices(license_id);

CREATE TABLE activation_events (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    license_id    UUID REFERENCES licenses(id),
    device_id     UUID REFERENCES devices(id),
    event_type    TEXT NOT NULL, -- 'activate' | 'reactivate' | 'deactivate' | 'reject'
    reason        TEXT,
    ip_address    INET,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_activation_events_license_id ON activation_events(license_id);
CREATE INDEX idx_activation_events_created_at ON activation_events(created_at);
