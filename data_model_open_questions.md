# Data Model Finalization Questions

Open questions to resolve before locking the PostgreSQL schema and provisioning the development environment.

---

## Decisions Made

### LucidLink Integration
- **Hybrid Approach**: Initial CSV/Parquet scan + ongoing `.lucid_audit` monitoring for `last_accessed` updates
- **No Incremental Scans**: New files added via audit logs only
- **Update Source Tracking**: Add `last_accessed_source` ENUM ('initial_scan', 'lucidlink_audit')

### Data Retention
- **All Files Retained**: Both stubbed and non-stubbed files remain in database for reference
- **Deleted Files**: Keep for 7 years for external audit purposes
- **Stub States**: No historical snapshots needed; rely on current state + audit log
- **Lifecycle Retention**:
  - `planned`: 1 year default (client configurable)
  - `stubbed`: Permanent until rules change
  - `rehydrated`: Per client global settings
  - `deleted`: Per client global settings

### Stub Registry
- **Single Record Per File**: No tracking of multiple incarnations; status flag only
- **No Custom Metadata**: No tenant-specific tags or business unit fields needed
- **Add Updated Timestamp**: Include `updated_utc` for audit trail

### Rehydration
- **Driver Managed**: NTFS ACLs, ownership, compression handled by EaseFilter driver
- **Same Record Update**: Rehydration updates existing record (remove stub status)
- **Orphan Detection**: Track stub + Tier-2 location; verify both exist

### Security & Tenancy
- **Shared Schema**: Common schema for all tenants with row-level security
- **Encrypt All Sensitive Columns**: tiered_location, credentials, hashes via Vault

### Audit & Monitoring
- **Log All Events**: All stub lifecycle changes (creation, rehydration, deletion, failure)
- **Key Metric**: Space saved on LucidLink storage

---

## Open Questions: Staging & Ingest Flow

### CSV/Parquet Staging
- Which columns from staging must persist into core schema vs. transient calculations?
  - **ACTION**: Define column mapping (staging → core schema)

- Staging table cleanup strategy?
  - **DECISION**: Retain staging data for troubleshooting; define retention period (24-48 hours?)

### LucidLink Audit Staging
- Separate `staging_lucid_audit` table confirmed
- Staging cleanup: We read audit files only (no modifications)
  - **ACTION**: Define read cursor tracking mechanism
  - **ACTION**: Clarify if we copy audit data to our staging table or parse directly

### Error Handling
- Partial ingest failures: Log error, skip file, continue batch
- **OPEN**: Retry logic for transient failures (network, locks)?
- **OPEN**: Alert thresholds for batch failure rates?

## Resolved: Core Schema Implementation

### Hybrid Approach Adopted
**DECISION**: Implemented dual-table design:
1. **`file` table**: Immutable scan snapshots (historical compliance/audit)
2. **`file_current` table**: Mutable operational state (planner uses this)

### Schema Additions Completed
- ✅ `file_current` table with all required columns
- ✅ `last_accessed_source` ENUM ('initial_scan', 'lucidlink_audit')
- ✅ `updated_utc` and `atime_updated_utc` timestamps
- ✅ `tier_object.last_accessed_utc` for warming event tracking
- ✅ `tier_object.access_count` for trend analysis
- ✅ `tier_object.file_current_id` foreign key relationship
- ✅ `lucid_audit_cursor` table for position tracking
- ✅ `staging_file` enhanced with `file_hash` and `file_extension`

### Complete `file_current` Schema
```sql
CREATE TABLE file_current (
  file_current_id bigserial PRIMARY KEY,
  tenant_id uuid NOT NULL REFERENCES tenant(tenant_id),
  share_name text NOT NULL,
  dir_id bigint NOT NULL REFERENCES dir(dir_id),
  name text NOT NULL,
  full_path text NOT NULL,
  size_bytes bigint NOT NULL,
  atime_unix integer NOT NULL,
  mtime_unix integer NOT NULL,
  ctime_unix integer NOT NULL,
  file_hash text,
  file_extension text,
  last_accessed_source text NOT NULL DEFAULT 'initial_scan',
  atime_updated_utc timestamptz NOT NULL DEFAULT now(),
  first_seen_scan_id bigint NOT NULL REFERENCES scan(scan_id),
  last_seen_scan_id bigint NOT NULL REFERENCES scan(scan_id),
  last_scan_utc timestamptz NOT NULL,
  created_utc timestamptz NOT NULL DEFAULT now(),
  updated_utc timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, full_path)
);
```

## Open Questions: Stub Registry Schema

### Required Attributes
- Minimal stub definition: source path, tiered URI, hash, size, timestamps, job reference, agent/host
  - **STATUS**: Schema finalized in `prostgresql_Proposal.md`

## Open Questions: Rehydration & Recovery

### Rehydration Triggers
- **CRITICAL**: When audit logs show stubbed file access, what action?
  - Option 1: Automatic immediate rehydration
  - Option 2: Alert only (manual intervention)
  - Option 3: Configurable per customer
  - **ACTION**: Define policy and implement configuration

### Pattern Recognition
- Audit log pattern to identify rehydrated files?
  - **ACTION**: Document LucidLink audit log patterns for rehydration events

### Warming Events
- Track recently accessed stubbed files for trend analysis
  - **ACTION**: Confirm schema additions: `last_accessed_utc`, `access_count` on `tier_object`

## Open Questions: Multi-Tenancy & Security

### API Token to RLS Mapping
- How are tenant-scoped API tokens mapped to database roles and RLS policies?
  - **ACTION**: Define authentication flow and session management
  - **ACTION**: Document connection pooler configuration with `SET app.tenant_id`

## Open Questions: Analytics & Dashboards

### Data Access Pattern
- Direct queries vs. materialized views for dashboards?
  - **ACTION**: Performance test both approaches
  - **RECOMMENDATION**: Start with direct queries; add materialized views only if needed

### Additional Metrics
- Beyond "space saved on LucidLink storage", which metrics are critical?
  - **ACTION**: Define complete metrics list for monitoring dashboards

## Open Questions: Planner & Actor Integration

### Rule Evaluation
- Planner rule evaluation with full file inventory available
  - **ACTION**: Confirm planner reads from core `file` table (not staging)

### Job Correlation
- Identifiers for correlating planner jobs with stub records
  - **ACTION**: Define job schema and foreign key relationships

### Planner Scoring
- Persist estimates (space saved, duration) with stub records?
  - **ACTION**: Decide if estimates stored or calculated on-demand

### LucidLink Audit Triggers
- **DECISION**: Selective re-evaluation (only 'PLANNED' or 'STUBBED' files)
- **OPEN**: Race condition handling - need locking strategy or state machine
- **DECISION**: Target lag < 15 minutes for stubbed files; batch for planned files
  - **ACTION**: Implement state machine or advisory locks to prevent conflicts
RECOMMENDATION: Near real-time (< 15 minutes) for stubbed files; batch processing for planned files

## Open Questions: Migration & Tooling

### Development Environment
- Bootstrap process for creating tenants, hosts, and stub records
  - **ACTION**: Create seed data scripts

### Database Migrations
- Migration strategy and rollback procedures
  - **ACTION**: Choose migration tool (Flyway, Liquibase, native Postgres)
  - **ACTION**: Define CI validation process

### Fixtures for Testing
- Sample data for local end-to-end testing
  - **ACTION**: Create fixture data representing typical customer scenarios

## Critical: LucidLink Audit Log Investigation Required

### Parsing & Format (BLOCKING)
- **Exact format of `.active` files** - Need LucidLink documentation or reverse engineering
  - **ACTION**: Contact LucidLink support or test with production volume
  - **ACTION**: Document file format, field definitions, encoding

- **Event IDs for idempotency** - Test with real LucidLink volume
  - **ACTION**: Determine if native event IDs exist or must be generated
  - **ACTION**: Design idempotency strategy

- **Access types logged** - Which events update last_accessed?
  - **RECOMMENDATION**: Focus on read/open events
  - **ACTION**: Confirm complete list of logged event types

### Performance & Scalability (BLOCKING)
- **Event volume** - How many events/day for typical LucidLink volume?
  - **ACTION**: Gather baseline metrics to size infrastructure

- **File size** - Can `.active` files fit in memory?
  - **ACTION**: Test with production volumes
  - **DECISION**: Implement streaming parser if files > 100MB

- **Processing strategy**
  - **RECOMMENDATION**: Parallel processing with worker pool
  - **ACTION**: Design worker pool architecture and progress tracking

### State Management (HIGH PRIORITY)
- **Cursor tracking** - How to track last processed position?
  - **RECOMMENDATION**: Add `lucid_audit_cursor` table
  - Schema: (tenant_id, volume_id, audit_file, last_position, last_event_id, last_processed_utc)
  - **ACTION**: Implement cursor persistence and recovery

- **File rotation handling** - What happens when LucidLink rotates/archives logs?
  - **ACTION**: Test rotation behavior and design gap detection

### Data Quality (HIGH PRIORITY)
- **Timestamp validation** - Prevent clock skew issues
  - **RECOMMENDATION**: Reject timestamps > 7 days future or far past
  - **ACTION**: Implement validation logic

- **Unknown file paths** - Audit logs reference files not in inventory
  - **DECISION**: New files added via audit logs; deleted files retained 7 years
  - **ACTION**: Implement new file insertion workflow

---

## Assumptions Requiring Validation

### LucidLink Specific
1. **Audit log accuracy** - No missed events, no corruption
   - **VALIDATION**: Test under load and verify against known file access patterns

2. **Polling impact** - 5-minute polling doesn't degrade LucidLink performance
   - **VALIDATION**: Monitor LucidLink metrics during pilot

3. **Format stability** - Audit log format stable across LucidLink versions
   - **VALIDATION**: Request forward compatibility guarantee from LucidLink

### General
1. **Full inventory available** - Rule evaluation works with complete file inventory
   - **VALIDATION**: Confirmed by design decisions

2. **Reporting from core tables** - No need for complex aggregations
   - **VALIDATION**: Review reporting requirements; performance test queries

3. **Driver provides rehydration metadata** - No need to store NTFS details
   - **VALIDATION**: Confirm with EaseFilter documentation

