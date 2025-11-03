
**1) Executive summary**

Build a **central Postgres cluster** in your DC for concurrent ingest from many Windows agents. Use **Vault Transit (OSS)** for envelope encryption to keep **per-client keys**. Store file metadata (paths, sizes, timestamps) at scale; generate tiering plans; run a **sanitize** routine that reconciles Tier-1 vs Tier-2 and fixes orphans. Enforce **RLS multi-tenant isolation**, HA, PITR, and full auditing.

**2) Architecture (high level)**

**Agents (customer sites, Windows Srv 2025)**  
→ Collect metadata (read-only) → batch **stage-upload** (CSV/Parquet via HTTPS to your API)  
→ Backend API (DC, IIS/Kestrel/.NET 8) → **COPY** into Postgres staging  
→ **Ingest workers** (background services) → normalize + upsert into core tables  
→ **Planner** → creates tiering plan (older than 365d)  
→ **Actor** → executes plan on Tier-2 (SMB/S3/Azure)  
→ **Sanitizer** → inventories Tier-2, detects **orphans/missing**, produces remediation  
→ **Vault** (OSS, Transit) → wrap/unwrap per-tenant DEKs  
→ **SIEM/Monitoring** → logs, metrics, tracing

**Core infra**

- Postgres HA (Patroni/pgBackRest), TLS, LDAP/AD auth
- Vault OSS Raft HA, TLS, sealed/unseal process
- Reverse proxy (Nginx/HAProxy) for API + Vault

**3) Multi-tenancy model**

- **One Postgres cluster**
- **Schemas per tenant** (recommended) _or_ shared tables with tenant_id + **RLS** (shown below uses shared tables + RLS for elasticity).
- Agents authenticate with **tenant-scoped API tokens**; backend sets app.tenant_id per connection/session.
- Vault: **one transit key per tenant**: transit/keys/&lt;tenant_code&gt;.

**4) Security & key management (Vault Transit OSS)**

- **Per-tenant DEK** (random 32 bytes), stored **wrapped** by Vault (encrypted_dek) in tenant registry table.
- Backend calls transit/decrypt/&lt;tenant&gt; at runtime to unwrap DEK **in memory only**.
- Use DEK to protect sensitive values (if any) or secrets (e.g., Tier-2 credentials).
- Vault policies limit tokens to their tenant key path when needed.

**5) Database schema (normalized, RLS, partition-ready)**

**5.1 Core tables (shared)**

\-- Tenant registry (stores wrapped DEK; no plaintext)

CREATE TABLE tenant (

tenant_id uuid PRIMARY KEY,

code text UNIQUE NOT NULL, -- e.g. 'ACME'

name text NOT NULL,

kms_ref text NOT NULL, -- 'vault:transit/keys/acme'

encrypted_dek text NOT NULL, -- ciphertext from Vault

created_utc timestamptz NOT NULL DEFAULT now(),

updated_utc timestamptz NOT NULL DEFAULT now()

);

\-- Scans (immutable snapshots)

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

\-- Directories (dedup across scans)

CREATE TABLE dir (

dir_id bigserial PRIMARY KEY,

tenant_id uuid NOT NULL REFERENCES tenant(tenant_id),

dir_path text NOT NULL, -- stored once

dir_hash64 bigint NOT NULL, -- xxhash64 over dir_path

UNIQUE (tenant_id, dir_path)

);

CREATE INDEX idx_dir_tenant_hash ON dir (tenant_id, dir_hash64);

\-- Files (per scan snapshot, normalized to dir)

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

\-- Operational tiering state machine

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

UNIQUE (tenant_id, full_path)

);

CREATE INDEX idx_tier_object_tenant_state ON tier_object (tenant_id, state);

\-- Tier-2 inventory captured by sanitizer

CREATE TABLE tier2_inventory (

inv_id bigserial PRIMARY KEY,

tenant_id uuid NOT NULL REFERENCES tenant(tenant_id),

discovered_utc timestamptz NOT NULL DEFAULT now(),

target_uri text NOT NULL,

size_bytes bigint,

tag_full_path text,

UNIQUE (tenant_id, target_uri)

);

\-- Append-only audit

CREATE TABLE audit_log (

audit_id bigserial PRIMARY KEY,

tenant_id uuid NOT NULL REFERENCES tenant(tenant_id),

utc timestamptz NOT NULL DEFAULT now(),

actor text NOT NULL,

action text NOT NULL,

details_json jsonb NOT NULL

);

CREATE INDEX idx_audit_tenant_time ON audit_log (tenant_id, utc DESC);

**Row-Level Security (RLS)**

ALTER TABLE tenant ENABLE ROW LEVEL SECURITY;

ALTER TABLE scan ENABLE ROW LEVEL SECURITY;

ALTER TABLE dir ENABLE ROW LEVEL SECURITY;

ALTER TABLE file ENABLE ROW LEVEL SECURITY;

ALTER TABLE tier_object ENABLE ROW LEVEL SECURITY;

ALTER TABLE tier2_inventory ENABLE ROW LEVEL SECURITY;

ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;

\-- App sets: SET app.tenant_id = '&lt;uuid&gt;';

CREATE OR REPLACE FUNCTION current_tenant() RETURNS uuid

LANGUAGE sql STABLE AS \$\$ select current_setting('app.tenant_id')::uuid \$\$;

CREATE POLICY p_tenant ON tenant USING (tenant_id = current_tenant());

CREATE POLICY p_scan ON scan USING (tenant_id = current_tenant());

CREATE POLICY p_dir ON dir USING (tenant_id = current_tenant());

CREATE POLICY p_file ON file USING (tenant_id = current_tenant());

CREATE POLICY p_tier_object ON tier_object USING (tenant_id = current_tenant());

CREATE POLICY p_t2inv ON tier2_inventory USING (tenant_id = current_tenant());

CREATE POLICY p_audit ON audit_log USING (tenant_id = current_tenant());

**Partitioning (when file rows exceed ~100M global)**

- **Files**: range partition by scan_id (or by month of started_utc) _and_ sub-partition by tenant_id if needed.
- **Tier inventory**: hash partition by tenant_id.  
    This keeps indexes small and autovacuum healthy.

**6) Ingestion pipeline (concurrent, idempotent)**

**6.1 Agent → API**

**Initial Full Scan (First Time):**
- Agents enumerate metadata (read-only).
- Write **newline-delimited CSV** (or Parquet) to local temp, then upload to your API endpoint with headers:
  - X-Tenant-Code, X-Scan-Started, X-Share-Name, X-Source-Type
- Agent retries with **exponential backoff**, includes **idempotency key** (scan_guid + chunk_seq).

**LucidLink Ongoing Updates (After Initial Scan):**
- Agent monitors `.lucid_audit` folder at root of LucidLink volume
- Scans all subfolders for files with `.active` extension
- Parses audit log entries to extract file access events
- Batch timestamp updates and upload to API endpoint `/api/v1/audit-updates` with headers:
  - X-Tenant-Code, X-Volume-ID, X-Source-Type: 'lucidlink_audit'
- Payload contains: file_path, new_last_accessed timestamp, audit_file reference
- Idempotency via (tenant_id, volume_id, audit_event_id)

**6.2 API → Postgres staging**

- For each upload **chunk**:
  - Begin a transaction; insert or fetch scan_id (upsert using scan_guid).
  - **COPY** CSV to **staging table** (tenant-scoped via app.tenant_id).

CREATE TABLE staging_file (

tenant_id uuid NOT NULL,

scan_id bigint NOT NULL,

dir_path text NOT NULL,

name text NOT NULL,

size_bytes bigint NOT NULL,

atime_unix integer NOT NULL,

mtime_unix integer NOT NULL,

ctime_unix integer NOT NULL

) WITH (autovacuum_enabled = true);

\-- Idempotency guard (one row per chunk id)

CREATE TABLE ingest_chunk (

tenant_id uuid NOT NULL,

scan_id bigint NOT NULL,

chunk_id text NOT NULL,

primary key (tenant_id, scan_id, chunk_id)

);

\-- LucidLink audit update staging

CREATE TABLE staging_lucid_audit (

tenant_id uuid NOT NULL,

volume_id text NOT NULL,

file_path text NOT NULL,

new_last_accessed integer NOT NULL,

audit_file text NOT NULL,

audit_event_id text,

processed_utc timestamptz

) WITH (autovacuum_enabled = true);

\-- Audit event idempotency (prevent duplicate processing)

CREATE TABLE lucid_audit_processed (

tenant_id uuid NOT NULL,

volume_id text NOT NULL,

audit_event_id text NOT NULL,

processed_utc timestamptz NOT NULL DEFAULT now(),

primary key (tenant_id, volume_id, audit_event_id)

);

- If (tenant_id, scan_id, chunk_id) exists → **skip** (exactly-once semantics).

**6.3 Normalize + upsert (ingest worker)**

- **Step 1: dir upsert**

INSERT INTO dir (tenant_id, dir_path, dir_hash64)

SELECT DISTINCT tenant_id, dir_path, xxhash64(dir_path)

FROM staging_file s

LEFT JOIN dir d

ON d.tenant_id = s.tenant_id AND d.dir_path = s.dir_path

WHERE d.dir_id IS NULL;

- **Step 2: files insert (immutable snapshot)**

INSERT INTO file (tenant_id, scan_id, dir_id, name, size_bytes, atime_unix, mtime_unix, ctime_unix)

SELECT s.tenant_id, s.scan_id, d.dir_id, s.name, s.size_bytes, s.atime_unix, s.mtime_unix, s.ctime_unix

FROM staging_file s

JOIN dir d ON d.tenant_id = s.tenant_id AND d.dir_path = s.dir_path

ON CONFLICT (scan_id, dir_id, name) DO NOTHING;

- Mark chunk complete; optionally **truncate** that chunk from staging.
- When all chunks complete, set scan.status='OK' and finished_utc=now().

**6.4 LucidLink audit update processing (ongoing)**

- **Step 1: Check idempotency**

SELECT audit_event_id FROM lucid_audit_processed

WHERE tenant_id = ? AND volume_id = ? AND audit_event_id = ANY(?);

- Skip already-processed events.

- **Step 2: Update last_accessed timestamps**

UPDATE file f

SET atime_unix = s.new_last_accessed,

    updated_utc = now()

FROM staging_lucid_audit s

JOIN dir d ON d.tenant_id = s.tenant_id 

          AND d.dir_path = substring(s.file_path from 1 for position('\\' in reverse(s.file_path)))

WHERE f.tenant_id = s.tenant_id

AND f.dir_id = d.dir_id

AND f.name = substring(s.file_path from position('\\' in reverse(s.file_path)) + 1)

AND s.new_last_accessed > f.atime_unix; -- Only update if newer

- **Step 3: Log to audit trail**

INSERT INTO audit_log (tenant_id, actor, action, details_json)

SELECT tenant_id, 'LucidLinkAuditParser', 'timestamp_update',

       jsonb_build_object('file_path', file_path, 'new_atime', new_last_accessed, 'source', 'lucidlink_audit')

FROM staging_lucid_audit;

- **Step 4: Mark events processed**

INSERT INTO lucid_audit_processed (tenant_id, volume_id, audit_event_id)

SELECT DISTINCT tenant_id, volume_id, audit_event_id

FROM staging_lucid_audit

WHERE audit_event_id IS NOT NULL

ON CONFLICT DO NOTHING;

- **Step 5: Trigger planner re-evaluation (optional)**

If updated files were previously in 'PLANNED' or 'STUBBED' state, check if they should be excluded from tiering or rehydrated.

**Concurrency**

- Multiple workers can run; protect per-tenant/scan with **pg_advisory_lock(hash(tenant_id, scan_id))** to keep normalization deterministic and fast.

**7) Planning & acting (tiering)**

**7.1 "Older than 1 year" plan (latest OK scan per tenant/share)**

WITH latest_scan AS (

SELECT DISTINCT ON (share_name)

share_name, scan_id

FROM scan

WHERE tenant_id = current_tenant() AND status='OK'

ORDER BY share_name, started_utc DESC

)

INSERT INTO tier_object (tenant_id, share_name, full_path, target_uri, state, planned_by)

SELECT f.tenant_id,

ls.share_name,

d.dir_path || '\\' || f.name AS full_path,

\-- map to your tier-2 path (function/lookup):

make_target_uri(ls.share_name, d.dir_path, f.name) AS target_uri,

'PLANNED',

'PlannerSvc'

FROM file f

JOIN latest_scan ls ON f.scan_id = ls.scan_id

JOIN dir d ON d.dir_id = f.dir_id

WHERE f.atime_unix <= EXTRACT(EPOCH FROM (now() - interval '365 days'))

ON CONFLICT (tenant_id, full_path) DO NOTHING;

**Actor** reads PLANNED, performs your stub/move, then UPDATE state='STUBBED', acted_utc=now() and logs to audit_log.

**8) Sanitizer (detect missing & orphans)**

**8.1 Inventory Tier-2**

- SMB: agent enumerates Tier-2 root → upload CSV of target_uri,size into tier2_inventory (upsert).
- S3/Azure: backend walks bucket/prefix or uses inventory files.

**8.2 Reconciliation queries**

**Missing on Tier-2 (should exist but not found)**

SELECT t.full_path, t.target_uri

FROM tier_object t

LEFT JOIN tier2_inventory i

ON i.tenant_id = t.tenant_id AND i.target_uri = t.target_uri

WHERE t.tenant_id = current_tenant()

AND t.state IN ('PLANNED','STUBBED')

AND i.inv_id IS NULL;

**Orphans (exist on Tier-2 but not referenced)**

SELECT i.target_uri, i.size_bytes

FROM tier2_inventory i

LEFT JOIN tier_object t

ON t.tenant_id = i.tenant_id AND t.target_uri = i.target_uri

WHERE i.tenant_id = current_tenant()

AND t.tier_id IS NULL;

**Stale plans (re-warmed recently)**

WITH ls AS (

SELECT scan_id FROM scan

WHERE tenant_id=current_tenant() AND status='OK'

ORDER BY started_utc DESC LIMIT 1

)

SELECT t.full_path, t.target_uri, f.atime_unix

FROM tier_object t

JOIN dir d ON d.tenant_id=t.tenant_id

JOIN file f ON f.scan_id=(SELECT scan_id FROM ls)

AND f.tenant_id=t.tenant_id

AND d.dir_id=f.dir_id

AND (t.full_path = d.dir_path || '\\' || f.name)

WHERE t.tenant_id=current_tenant()

AND t.state IN ('PLANNED','STUBBED')

AND f.atime_unix > EXTRACT(EPOCH FROM (now() - interval '365 days'));

**Broken refs (planned path not present in latest scan)**

WITH ls AS (SELECT scan_id FROM scan

WHERE tenant_id=current_tenant() AND status='OK'

ORDER BY started_utc DESC LIMIT 1),

live AS (

SELECT d.dir_path || '\\' || f.name AS full_path

FROM file f

JOIN dir d ON d.dir_id=f.dir_id

WHERE f.scan_id=(SELECT scan_id FROM ls)

)

SELECT t.full_path

FROM tier_object t

LEFT JOIN live l ON l.full_path=t.full_path

WHERE t.tenant_id=current_tenant()

AND l.full_path IS NULL;

**Remediation** is idempotent and requires **dry-run** + dual approval (quarantine or delete).

**9) Ops: HA, backups, monitoring**

**Postgres**

- HA with **Patroni** (or EDB/Bitnami), sync replication (1 replica), **pgBackRest** for PITR.
- shared_buffers ~25% RAM, effective_cache_size ~60%, autovacuum tuned for big partitions.
- COPY for ingest; connection pooling via **PgBouncer**.

**Vault (OSS)**

- 3 Raft nodes, TLS, audit to syslog; Shamir unseal or auto-unseal with a local KMS/HSM if available.
- Nightly Raft snapshots off-box.

**Monitoring**

- Prometheus + Grafana (Postgres exporter, Vault exporter).
- Windows agents log to Event Log; centralize via NXLog/Winlogbeat to SIEM.
- Alerts: ingest lag, sanitizer orphan delta, failed integrity checks, Vault seal/unseal events.

**10) Security hardening**

- **RLS** + **SET app.tenant_id** enforced at connection pooler (init queries).
- DB roles per function: scanner_role, ingest_role, planner_role, actor_role, sanitizer_role, report_role.
- TLS everywhere (mutual TLS agent→API optional).
- Secrets never stored plaintext; only **Vault ciphertext** in DB; unwrap in memory.
- Signed agents; limited service accounts; firewall rules per role.
- Two-person approve for destructive sanitization.

**11) Sizing & performance (guidance)**

- **Throughput**: with COPY, a modest 8-core Postgres can ingest **1-3 million rows/min** from staging to file (proper indexes added after bulk or using constraint-backfill).
- **Scale**:
  - 5M files/tenant → DB for that tenant's latest scan ≈ 1-3 GB (normalized; excludes historical scans).
  - 50M global rows → partitioning recommended; keep per-partition indexes < 10-15 GB.
- **Hardware (start)**: 2× db nodes (16C/128 GB RAM/ NVMe), 1× witness; Vault 3× small VMs (4C/8 GB). Grow vertically first.

**12) Windows agent notes (practical)**

**Initial Scan:**
- **Enumeration**: PowerShell 7 or .NET 8 worker; long-path aware (\\\\?\\), retries, skip errors.
- **Output**: CSV columns: dir_path,name,size_bytes,atime_unix,mtime_unix,ctime_unix.
- **Upload**: chunk 250-500k rows; gzip; include chunk_id.
- **Resilience**: local queue dir with .ok markers; resume after reboot.
- **Time**: collect UTC; don't format dates in the pipeline.

**LucidLink Audit Monitoring:**
- **Discovery**: Locate `.lucid_audit` folder at volume root (e.g., `Z:\.lucid_audit`)
- **Scanning**: Recursively scan all subfolders for files with `.active` extension
- **Parsing**: Custom parser for LucidLink audit format; extract file_path, access_time, event_id
- **Batching**: Group updates by volume; batch up to 10k updates per upload
- **Frequency**: Poll every 5 minutes (configurable); track last processed position per audit file
- **Deduplication**: Use audit_event_id to prevent reprocessing same events
- **Error Handling**: Skip corrupted/unparseable entries; log warnings; continue processing
- **State Tracking**: Maintain cursor file tracking last processed audit file + position

**13) Rollout plan (phased)**

- **P0**: Stand up Vault OSS (Transit), Postgres HA, API & ingest worker.
- **P1**: One tenant pilot (scanner → plan → actor → sanitize dry-run).
- **P2**: Add RLS + multi-tenant; onboarding automation (tenant registry, Vault key creation).
- **P3**: Partitioning, sanitizer remediation with approval workflow, full dashboards.
- **P4**: Hardening audit, backup/restore drills, performance soak.

**14) Deliverables (what I can prep next)**

- **Postgres DDL pack** (tables, RLS, partitions, indexes, helper functions).
- **Vault bootstrap scripts** (per-tenant key create; wrap/unwrap DEK).
- **Ingest worker** skeleton (.NET 8) with COPY + advisory locks.
- **Agent** (PowerShell or .NET) with resilient chunked uploads.
- **Sanitizer** stored procedures + report exports (CSV).
- **Runbooks** for backup/restore + failover + sanitize.

If you want, I'll generate the **DDL pack + Vault bootstrap** first so you can spin up a lab and start load testing.