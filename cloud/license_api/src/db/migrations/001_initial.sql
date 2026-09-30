CREATE TABLE customers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_name TEXT NOT NULL CHECK(length(trim(business_name)) > 0),
  contact_email TEXT, contact_phone TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE plans (
  id TEXT PRIMARY KEY, edition TEXT NOT NULL, display_name TEXT NOT NULL,
  default_max_devices INT NOT NULL CHECK(default_max_devices > 0)
);
INSERT INTO plans VALUES ('non_bir','non_bir','Non-BIR',1);
INSERT INTO plans VALUES ('bir_ready','bir_ready','BIR-ready',1);
CREATE TABLE licenses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id UUID NOT NULL REFERENCES customers(id),
  plan_id TEXT NOT NULL REFERENCES plans(id),
  activation_key_hash TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL DEFAULT 'unactivated' CHECK(status IN ('unactivated','active','revoked')),
  max_devices INT NOT NULL CHECK(max_devices > 0),
  max_reactivations INT NOT NULL DEFAULT 3 CHECK(max_reactivations >= 0),
  reactivations_used INT NOT NULL DEFAULT 0 CHECK(reactivations_used >= 0),
  issued_at TIMESTAMPTZ NOT NULL DEFAULT now(), expires_at TIMESTAMPTZ,
  revoked_at TIMESTAMPTZ
);
CREATE TABLE devices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  license_id UUID NOT NULL REFERENCES licenses(id),
  device_fingerprint TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','deactivated')),
  activated_at TIMESTAMPTZ NOT NULL DEFAULT now(), deactivated_at TIMESTAMPTZ,
  UNIQUE(license_id,device_fingerprint)
);
CREATE INDEX devices_by_license ON devices(license_id,status);
CREATE TABLE activation_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  license_id UUID REFERENCES licenses(id), device_id UUID REFERENCES devices(id),
  event_type TEXT NOT NULL, reason TEXT, created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX activation_events_by_time ON activation_events(created_at DESC);
CREATE TABLE admin_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), actor TEXT NOT NULL,
  action TEXT NOT NULL, target_id UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
