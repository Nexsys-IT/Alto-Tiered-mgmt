# PostgreSQL Core Schema Implementation Plan

## Problem Statement

The data model open questions document identifies several gaps between the proposed schema (in `prostgresql_Proposal.md`) and the requirements that have been finalized through recent decisions. Specifically:

1. **Inconsistent Table Names**: Flow diagram references `file_inventory` table, but PostgreSQL proposal uses normalized `file` table
2. **Missing Columns**: Decisions require `last_accessed_source` and `updated_utc` columns not present in current schema
3. **LucidLink-Specific Tracking**: Need cursor/state management tables for audit log processing
4. **Unclear Relationship**: The `file` table in proposal is scan-based (immutable snapshots), but LucidLink audit updates require mutable records

## Current State Analysis

### Existing Schema (from prostgresql_Proposal.md)

The current proposal defines these core tables:

#### 1. `tenant` table
```sql
CREATE TABLE tenant (
  tenant_id uuid PRIMARY KEY,
  code text UNIQUE NOT NULL,
  name text NOT NULL,
  kms_ref text NOT NULL,
  encrypted_dek text NOT NULL,
  created_utc timestamptz NOT NULL DEFAULT now(),
  updated_utc timestamptz NOT NULL DEFAULT now()
);
```
**Status**: ✅ Complete

#### 2. `scan` table
```sql
CREATE TABLE scan (
  scan_id bigserial PRIMARY KEY,
  tenant_id uuid NOT NULL REFERENCES tenant(tenant_id),
  share_name text NOT NULL,
  started_utc timestamptz NOT NULL,
  finished_utc timestamptz,
  src_type text NOT NULL CHECK (src_type IN ('NTFS','LucidLink','SMB')),
  status text NOT NULL CHECK (status IN ('OK','WARN','ERROR'))
);
CREATE INDEX idx_scan_tenant_time ON scan (tenant_id, started_utc DESC);
```
**Status**: ✅ Complete

#### 3. `dir` table (directory deduplication)
```sql
CREATE TABLE dir (
  dir_id bigserial PRIMARY KEY,
  tenant_id uuid NOT NULL REFERENCES tenant(tenant_id),
  dir_path text NOT NULL,
  dir_hash64 bigint NOT NULL,
  UNIQUE (tenant_id, dir_path)
);
CREATE INDEX idx_dir_tenant_hash ON dir (tenant_id, dir_hash64);
```
**Status**: ✅ Complete

#### 4. `file` table (immutable scan snapshots)
```sql
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
  frn bigint,
  UNIQUE (scan_id, dir_id, name)
);
CREATE INDEX idx_file_tenant_scan ON file (tenant_id, scan_id);
CREATE INDEX idx_file_atime ON file (tenant_id, atime_unix);
```
**Issues**: 
- ❌ No `updated_utc` column for tracking when `atime_unix` was last modified
- ❌ No `last_accessed_source` to track update origin
- ❌ Scan-based design makes LucidLink audit updates problematic (creates duplicate records per scan)
- ❌ Missing `file_hash` column mentioned in flow diagram
- ❌ Missing `file_extension` column mentioned in flow diagram

#### 5. `tier_object` table (operational state)
```sql
CREATE TABLE tier_object (
  tier_id bigserial PRIMARY KEY,
  tenant_id uuid NOT NULL REFERENCES tenant(tenant_id),
  share_name text NOT NULL,
  full_path text NOT NULL,
  target_uri text NOT NULL,
  state text NOT NULL CHECK (state IN ('PLANNED','STUBBED','REHYDRATED','DELETED')),
  planned_by text NOT NULL,
  planned_utc timestamptz NOT NULL DEFAULT now(),
  acted_utc timestamptz,
  last_seen_utc timestamptz,
  UNIQUE (tenant_id, full_path)
);
CREATE INDEX idx_tier_object_tenant_state ON tier_object (tenant_id, state);
```
**Issues**:
- ❌ Missing `last_accessed_utc` for warming event tracking
- ❌ Missing `access_count` for trend analysis
- ❌ No relationship to `file` table (no foreign key)

#### 6. Staging tables
```sql
-- Initial scan staging
CREATE TABLE staging_file (
  tenant_id uuid NOT NULL,
  scan_id bigint NOT NULL,
  dir_path text NOT NULL,
  name text NOT NULL,
  size_bytes bigint NOT NULL,
  atime_unix integer NOT NULL,
  mtime_unix integer NOT NULL,
  ctime_unix integer NOT NULL
);

-- LucidLink audit staging
CREATE TABLE staging_lucid_audit (
  tenant_id uuid NOT NULL,
  volume_id text NOT NULL,
  file_path text NOT NULL,
  new_last_accessed integer NOT NULL,
  audit_file text NOT NULL,
  audit_event_id text,
  processed_utc timestamptz
);

-- Idempotency tables
CREATE TABLE ingest_chunk (
  tenant_id uuid NOT NULL,
  scan_id bigint NOT NULL,
  chunk_id text NOT NULL,
  PRIMARY KEY (tenant_id, scan_id, chunk_id)
);

CREATE TABLE lucid_audit_processed (
  tenant_id uuid NOT NULL,
  volume_id text NOT NULL,
  audit_event_id text NOT NULL,
  processed_utc timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, volume_id, audit_event_id)
);
```
**Status**: ✅ Complete for staging, but missing cursor tracking

### Update Logic (from prostgresql_Proposal.md lines 384-404)

```sql
-- Current approach: Update file table directly
UPDATE file f
SET atime_unix = s.new_last_accessed,
    updated_utc = now()  -- Column doesn't exist!
FROM staging_lucid_audit s
JOIN dir d ON d.tenant_id = s.tenant_id 
          AND d.dir_path = substring(s.file_path from 1 for position('\\' in reverse(s.file_path)))
WHERE f.tenant_id = s.tenant_id
AND f.dir_id = d.dir_id
AND f.name = substring(s.file_path from position('\\' in reverse(s.file_path)) + 1)
AND s.new_last_accessed > f.atime_unix;
```

**Critical Issue**: This UPDATE statement references `updated_utc` column that doesn't exist in the schema. Also, it would update ALL scans containing that file, not just the latest.

### Documentation Conflicts

**flow_Diagram.md (lines 145-161)** references `file_inventory` table:
```
- Table: `public.file_inventory`
- Columns:
  - `id` (UUID, primary key)
  - `customer_id` (UUID, foreign key)
  - `host_id` (UUID, foreign key)
  - `file_path` (TEXT, indexed)
  - `file_size` (BIGINT)
  - `last_modified` (TIMESTAMP)
  - `last_accessed` (TIMESTAMP)
  - `file_extension` (VARCHAR(10))
  - `file_hash` (VARCHAR(64))
  - `is_stubbed` (BOOLEAN)
  - `stub_created_at` (TIMESTAMP)
  - `tiered_location` (TEXT)
  - `last_scan_time` (TIMESTAMP)
  - `created_at` (TIMESTAMP)
  - `updated_at` (TIMESTAMP)
```

This is a **different design** from the normalized `scan` + `dir` + `file` approach in PostgreSQL proposal.

---

## Design Decision Required

**CRITICAL CHOICE**: We must choose between two architectural approaches:

### Option A: Scan-Based Immutable Snapshots (Current Proposal)
- Each scan creates new `file` records
- Historical point-in-time accuracy
- Complex LucidLink audit updates (which scan to update?)
- More storage overhead
- Better for compliance/audit trail

### Option B: Mutable Current-State Inventory (Flow Diagram)
- Single `file_inventory` record per unique file
- Updates in place for `last_accessed`
- Simpler LucidLink audit updates
- Less storage overhead
- Need separate history tracking for compliance

**RECOMMENDATION**: **Hybrid Approach**

1. Keep normalized `scan` + `dir` + `file` for **immutable scan history**
2. Add new `file_current` table for **mutable current state** that gets updated by:
   - Initial scans (upsert)
   - LucidLink audit logs (update `atime_unix` only)
3. Use `file_current` for planner rule evaluation
4. Keep `file` snapshots for historical analysis and compliance

---

## Proposed Schema Changes

### 1. Add `file_current` table (NEW)

```sql
-- Current operational view of files (mutable)
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

-- RLS policy
ALTER TABLE file_current ENABLE ROW LEVEL SECURITY;
CREATE POLICY p_file_current ON file_current USING (tenant_id = current_tenant());
```

### 2. Enhance `tier_object` table

```sql
-- Add missing columns for warming event tracking
ALTER TABLE tier_object 
  ADD COLUMN last_accessed_utc timestamptz,
  ADD COLUMN access_count integer NOT NULL DEFAULT 0,
  ADD COLUMN file_current_id bigint REFERENCES file_current(file_current_id);

CREATE INDEX idx_tier_object_file_current ON tier_object (file_current_id);
```

### 3. Add cursor tracking table for LucidLink

```sql
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

-- RLS policy
ALTER TABLE lucid_audit_cursor ENABLE ROW LEVEL SECURITY;
CREATE POLICY p_lucid_audit_cursor ON lucid_audit_cursor USING (tenant_id = current_tenant());
```

### 4. Update staging tables

```sql
-- Add hash and extension to staging
ALTER TABLE staging_file
  ADD COLUMN file_hash text,
  ADD COLUMN file_extension text;
```

---

## Updated Data Flow

### Initial Scan Flow
1. Agent scans filesystem → CSV with all metadata
2. API loads to `staging_file`
3. Ingest worker:
   - Upserts to `dir` (deduplicate directories)
   - Inserts to `file` (immutable snapshot)
   - **UPSERTS to `file_current`** (current operational state)
     - If exists: update timestamps, size, hash if changed
     - If new: insert new record

### LucidLink Audit Update Flow
1. Agent parses `.lucid_audit/*.active` files
2. API loads to `staging_lucid_audit`
3. Update worker:
   - Check `lucid_audit_processed` for idempotency
   - **UPDATE `file_current.atime_unix`** where path matches
   - Set `last_accessed_source = 'lucidlink_audit'`
   - Set `atime_updated_utc = now()`
   - Insert to `lucid_audit_processed`
   - Update `lucid_audit_cursor` position
   - Log to `audit_log`

### Planner Rule Evaluation
- Reads from `file_current` (not `file` snapshots)
- Evaluates against `atime_unix`, `mtime_unix`, `size_bytes`
- Creates entries in `tier_object` with `file_current_id` foreign key

### Warming Event Detection
- When `tier_object.state = 'STUBBED'` and LucidLink audit shows access:
  - Update `tier_object.last_accessed_utc`
  - Increment `tier_object.access_count`
  - Trigger alert/rehydration based on policy

---

## Implementation Tasks

### Phase 1: Schema Migration (DDL)
- [ ] Create `file_current` table with all columns and indexes
- [ ] Create `lucid_audit_cursor` table
- [ ] Alter `tier_object` to add tracking columns
- [ ] Alter `staging_file` to add hash and extension
- [ ] Add RLS policies for new tables

### Phase 2: Ingest Worker Updates
- [ ] Modify initial scan ingest to populate both `file` AND `file_current`
- [ ] Implement upsert logic for `file_current`:
  - ON CONFLICT (tenant_id, full_path) DO UPDATE
  - Update last_seen_scan_id, timestamps, and data if changed
- [ ] Update to use full_path construction (dir_path + name)

### Phase 3: LucidLink Audit Worker
- [ ] Implement UPDATE query for `file_current.atime_unix` from `staging_lucid_audit`
- [ ] Add cursor tracking logic (read/write `lucid_audit_cursor`)
- [ ] Implement idempotency checks against `lucid_audit_processed`
- [ ] Add audit logging for all timestamp updates

### Phase 4: Planner Integration
- [ ] Update planner queries to read from `file_current` instead of `file`
- [ ] Add foreign key relationship `tier_object.file_current_id`
- [ ] Implement warming event detection logic

### Phase 5: Testing & Validation
- [ ] Test initial scan → `file_current` population
- [ ] Test LucidLink audit → `file_current` updates
- [ ] Test cursor recovery after restart
- [ ] Test idempotency (duplicate audit events)
- [ ] Performance test with millions of records

---

## Open Questions to Resolve

1. **Partitioning Strategy**: Should `file_current` be partitioned by tenant_id when it grows large?
   - Recommendation: Yes, hash partition by tenant_id when > 50M rows globally

2. **Historical Scans Retention**: How long to keep `file` snapshot records?
   - Current: Indefinite (via scan retention policy)
   - Need to define: Automated cleanup after X scans or X days?

3. **Path Construction**: Use Windows backslash `\` or normalize to forward slash `/`?
   - Current proposal uses backslash in SQL: `dir_path || '\\' || name`
   - Need to decide: Store as-is or normalize?

4. **Missing Files**: If LucidLink audit references file not in `file_current`, should we:
   - Option A: Insert new record with limited metadata
   - Option B: Log warning and wait for next full scan
   - Recommendation: Option A for new files, Option B for deleted files

5. **Concurrent Updates**: How to handle race condition where scan and audit update same file?
   - Need: Advisory lock or optimistic locking with version column

---

## Files Requiring Updates

1. **prostgresql_Proposal.md**
   - Add `file_current` table definition
   - Add `lucid_audit_cursor` table definition
   - Update section 6.4 LucidLink audit processing with correct column names
   - Document hybrid approach (immutable snapshots + mutable current state)

2. **flow_Diagram.md**
   - Update "Core Inventory Schema" section to reflect actual table names
   - Remove references to `file_inventory` or clarify it refers to `file_current`
   - Update database update logic SQL example

3. **data_model_open_questions.md**
   - Mark schema questions as resolved
   - Add note about hybrid approach decision
   - Move to validation phase for testing questions

---

## Success Criteria

- [ ] Schema creates without errors in PostgreSQL 14+
- [ ] All foreign keys and constraints valid
- [ ] RLS policies enforce tenant isolation
- [ ] Initial scan populates both `file` and `file_current`
- [ ] LucidLink audit updates only `file_current.atime_unix`
- [ ] Planner reads from `file_current` successfully
- [ ] Warming events detected and logged
- [ ] Performance: 10k+ LucidLink audit updates per minute
- [ ] Idempotency: Duplicate events safely ignored
- [ ] Documentation updated and consistent across all files
