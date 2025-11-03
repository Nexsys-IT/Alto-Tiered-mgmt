-- Alto Tiered Storage Management - Core PostgreSQL Schema
-- Version: 1.0
-- Architecture: Hybrid approach (immutable scan snapshots + mutable current state)
--
-- This schema supports:
-- - Initial filesystem scans (CSV/Parquet import)
-- - LucidLink audit log monitoring for last_accessed updates
-- - Multi-tenant isolation via Row-Level Security (RLS)
-- - Warming event tracking for stubbed files
--

-- ============================================================================
-- CORE TABLES
-- ============================================================================

-- Tenant registry (stores wrapped DEK; no plaintext)
CREATE TABLE tenant (
  tenant_id uuid PRIMARY KEY,
  code text UNIQUE NOT NULL, -- e.g. 'ACME'
  name text NOT NULL,
  kms_ref text NOT NULL, -- 'vault:transit/keys/acme'
  encrypted_dek text NOT NULL, -- ciphertext from Vault
  created_utc timestamptz NOT NULL DEFAULT now(),
  updated_utc timestamptz NOT NULL DEFAULT now()
);

-- Scans (immutable snapshots)
CREATE TABLE scan (
  scan_id bigserial PRIMARY KEY,
  tenant_id uuid NOT NULL REFERENCES tenant(tenant_id),
  share_name text NOT NULL, -- e.g. 'LL-B'
  started_utc timestamptz NOT NULL,
  finished_utc timestamptz,
  src_type text NOT NULL CHECK (src_type IN ('NTFS','LucidLink','SMB')),
  status text NOT NULL CHECK (status IN ('OK','WARN','ERROR'))
);
CREATE INDEX idx_scan_tenant_time ON scan (tenant_id, started_utc DESC);

-- Directories (dedup across scans)
CREATE TABLE dir (
  dir_id bigserial PRIMARY KEY,
  tenant_id uuid NOT NULL REFERENCES tenant(tenant_id),
  dir_path text NOT NULL, -- stored once
  dir_hash64 bigint NOT NULL, -- xxhash64 over dir_path
  UNIQUE (tenant_id, dir_path)
);
CREATE INDEX idx_dir_tenant_hash ON dir (tenant_id, dir_hash64);

-- Files (per scan snapshot, normalized to dir) - IMMUTABLE
CREATE TABLE file (
  file_id bigserial PRIMARY KEY,
  tenant_id uuid NOT NULL REFERENCES tenant(tenant_id),
  scan_id bigint NOT NULL REFERENCES scan(scan_id) ON DELETE CASCADE,
  dir_id bigint NOT NULL REFERENCES dir(dir_id),
  name text NOT NULL,
  size_bytes bigint NOT NULL,
  atime_unix integer NOT NULL,
  mtime_unix integer NOT NULL,
  ctime_unix integer NOT NULL,
  frn bigint, -- when NTFS local
  UNIQUE (scan_id, dir_id, name)
);
CREATE INDEX idx_file_tenant_scan ON file (tenant_id, scan_id);
CREATE INDEX idx_file_atime ON file (tenant_id, atime_unix);

-- Current file state (mutable, updated by scans and LucidLink audit)
-- This is the OPERATIONAL table used by the planner
CREATE TABLE file_current (
  file_current_id bigserial PRIMARY KEY,
  tenant_id uuid NOT NULL REFERENCES tenant(tenant_id),
  share_name text NOT NULL,
  dir_id bigint NOT NULL REFERENCES dir(dir_id),
  name text NOT NULL,
  full_path text NOT NULL, -- denormalized for quick lookup
  size_bytes bigint NOT NULL,
  atime_unix integer NOT NULL,
  mtime_unix integer NOT NULL,
  ctime_unix integer NOT NULL,
  file_hash text,
  file_extension text,
  frn bigint, -- when NTFS local
  
  -- LucidLink audit tracking
  last_accessed_source text NOT NULL DEFAULT 'initial_scan'
    CHECK (last_accessed_source IN ('initial_scan', 'lucidlink_audit')),
  atime_updated_utc timestamptz NOT NULL DEFAULT now(),
  
  -- Scan tracking
  first_seen_scan_id bigint NOT NULL REFERENCES scan(scan_id),
  last_seen_scan_id bigint NOT NULL REFERENCES scan(scan_id),
  last_scan_utc timestamptz NOT NULL,
  
  -- Audit timestamps
  created_utc timestamptz NOT NULL DEFAULT now(),
  updated_utc timestamptz NOT NULL DEFAULT now(),
  
  UNIQUE (tenant_id, full_path)
);
CREATE INDEX idx_file_current_tenant ON file_current (tenant_id);
CREATE INDEX idx_file_current_dir ON file_current (dir_id);
CREATE INDEX idx_file_current_atime ON file_current (tenant_id, atime_unix);
CREATE INDEX idx_file_current_share ON file_current (tenant_id, share_name);
CREATE INDEX idx_file_current_path ON file_current (tenant_id, full_path);

-- Operational tiering state machine
CREATE TABLE tier_object (
  tier_id bigserial PRIMARY KEY,
  tenant_id uuid NOT NULL REFERENCES tenant(tenant_id),
  share_name text NOT NULL,
  full_path text NOT NULL, -- canonical source path
  target_uri text NOT NULL, -- e.g. smb://tier2/acme/...
  state text NOT NULL CHECK (state IN ('PLANNED','STUBBED','REHYDRATED','DELETED')),
  planned_by text NOT NULL,
  planned_utc timestamptz NOT NULL DEFAULT now(),
  acted_utc timestamptz,
  last_seen_utc timestamptz,
  
  -- Warming event tracking (LucidLink audit)
  last_accessed_utc timestamptz,
  access_count integer NOT NULL DEFAULT 0,
  
  -- Link to current file state
  file_current_id bigint REFERENCES file_current(file_current_id),
  
  UNIQUE (tenant_id, full_path)
);
CREATE INDEX idx_tier_object_tenant_state ON tier_object (tenant_id, state);
CREATE INDEX idx_tier_object_file_current ON tier_object (file_current_id);

-- Tier-2 inventory captured by sanitizer
CREATE TABLE tier2_inventory (
  inv_id bigserial PRIMARY KEY,
  tenant_id uuid NOT NULL REFERENCES tenant(tenant_id),
  discovered_utc timestamptz NOT NULL DEFAULT now(),
  target_uri text NOT NULL,
  size_bytes bigint,
  tag_full_path text,
  UNIQUE (tenant_id, target_uri)
);

-- Append-only audit
CREATE TABLE audit_log (
  audit_id bigserial PRIMARY KEY,
  tenant_id uuid NOT NULL REFERENCES tenant(tenant_id),
  utc timestamptz NOT NULL DEFAULT now(),
  actor text NOT NULL,
  action text NOT NULL,
  details_json jsonb NOT NULL
);
CREATE INDEX idx_audit_tenant_time ON audit_log (tenant_id, utc DESC);

-- ============================================================================
-- STAGING TABLES
-- ============================================================================

-- Initial scan staging
CREATE TABLE staging_file (
  tenant_id uuid NOT NULL,
  scan_id bigint NOT NULL,
  dir_path text NOT NULL,
  name text NOT NULL,
  size_bytes bigint NOT NULL,
  atime_unix integer NOT NULL,
  mtime_unix integer NOT NULL,
  ctime_unix integer NOT NULL,
  file_hash text,
  file_extension text
) WITH (autovacuum_enabled = true);

-- Idempotency guard (one row per chunk id)
CREATE TABLE ingest_chunk (
  tenant_id uuid NOT NULL,
  scan_id bigint NOT NULL,
  chunk_id text NOT NULL,
  PRIMARY KEY (tenant_id, scan_id, chunk_id)
);

-- LucidLink audit update staging
CREATE TABLE staging_lucid_audit (
  tenant_id uuid NOT NULL,
  volume_id text NOT NULL,
  file_path text NOT NULL,
  new_last_accessed integer NOT NULL,
  audit_file text NOT NULL,
  audit_event_id text,
  processed_utc timestamptz
) WITH (autovacuum_enabled = true);

-- Audit event idempotency (prevent duplicate processing)
CREATE TABLE lucid_audit_processed (
  tenant_id uuid NOT NULL,
  volume_id text NOT NULL,
  audit_event_id text NOT NULL,
  processed_utc timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, volume_id, audit_event_id)
);

-- Track processing position in LucidLink audit files
CREATE TABLE lucid_audit_cursor (
  cursor_id bigserial PRIMARY KEY,
  tenant_id uuid NOT NULL REFERENCES tenant(tenant_id),
  volume_id text NOT NULL,
  audit_file_path text NOT NULL,
  last_position bigint NOT NULL DEFAULT 0,
  last_event_id text,
  last_processed_utc timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, volume_id, audit_file_path)
);
CREATE INDEX idx_lucid_audit_cursor_tenant_vol ON lucid_audit_cursor (tenant_id, volume_id);

-- ============================================================================
-- ROW-LEVEL SECURITY (RLS)
-- ============================================================================

ALTER TABLE tenant ENABLE ROW LEVEL SECURITY;
ALTER TABLE scan ENABLE ROW LEVEL SECURITY;
ALTER TABLE dir ENABLE ROW LEVEL SECURITY;
ALTER TABLE file ENABLE ROW LEVEL SECURITY;
ALTER TABLE file_current ENABLE ROW LEVEL SECURITY;
ALTER TABLE tier_object ENABLE ROW LEVEL SECURITY;
ALTER TABLE tier2_inventory ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE lucid_audit_cursor ENABLE ROW LEVEL SECURITY;

-- App sets: SET app.tenant_id = '<uuid>';
CREATE OR REPLACE FUNCTION current_tenant() RETURNS uuid
LANGUAGE sql STABLE AS $$ SELECT current_setting('app.tenant_id')::uuid $$;

CREATE POLICY p_tenant ON tenant USING (tenant_id = current_tenant());
CREATE POLICY p_scan ON scan USING (tenant_id = current_tenant());
CREATE POLICY p_dir ON dir USING (tenant_id = current_tenant());
CREATE POLICY p_file ON file USING (tenant_id = current_tenant());
CREATE POLICY p_file_current ON file_current USING (tenant_id = current_tenant());
CREATE POLICY p_tier_object ON tier_object USING (tenant_id = current_tenant());
CREATE POLICY p_t2inv ON tier2_inventory USING (tenant_id = current_tenant());
CREATE POLICY p_audit ON audit_log USING (tenant_id = current_tenant());
CREATE POLICY p_lucid_audit_cursor ON lucid_audit_cursor USING (tenant_id = current_tenant());

-- ============================================================================
-- PARTITIONING NOTES (when file rows exceed ~100M global)
-- ============================================================================

-- Files: range partition by scan_id (or by month of started_utc) 
--        and sub-partition by tenant_id if needed
-- Tier inventory: hash partition by tenant_id
-- This keeps indexes small and autovacuum healthy

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON TABLE file IS 'Immutable scan snapshots - one record per file per scan for historical compliance';
COMMENT ON TABLE file_current IS 'Mutable operational state - one record per unique file, updated by scans and LucidLink audit';
COMMENT ON COLUMN file_current.last_accessed_source IS 'Tracks whether last_accessed came from initial_scan or lucidlink_audit';
COMMENT ON COLUMN file_current.atime_updated_utc IS 'When atime_unix was last modified (for LucidLink audit tracking)';
COMMENT ON TABLE tier_object IS 'Operational tiering state machine with warming event tracking';
COMMENT ON COLUMN tier_object.last_accessed_utc IS 'Last access time from LucidLink audit (for warming event detection)';
COMMENT ON COLUMN tier_object.access_count IS 'Number of times accessed while in PLANNED/STUBBED state';
COMMENT ON TABLE lucid_audit_cursor IS 'Tracks processing position in LucidLink audit files for incremental processing';
