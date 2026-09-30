INSERT INTO plans(id, edition, display_name, default_max_devices)
VALUES ('bir_ready', 'bir_ready', 'BIR-ready', 1)
ON CONFLICT (id) DO NOTHING;
