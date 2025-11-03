# Data Model Finalization Questions

Draft checklist of open questions to resolve before locking the PostgreSQL schema and provisioning the development environment. Update this doc as decisions are made.

## LucidLink Integration Updates

**DECISION MADE**: The system will use a hybrid approach for LucidLink volumes:
- **Initial Scan**: Standard CSV/Parquet import captures complete file inventory
- **Ongoing Updates**: Monitor `.lucid_audit` folder for `.active` files to update `last_accessed` timestamps
- **Impact**: This affects staging tables, update workflows, and planner re-evaluation logic

## Scope & Retention
- Should the core database retain only stubbed file records, or do we still need a short-term cache of full scan metadata for rule evaluation and reporting?
ANSWER: We will need an initial full scan of all the entire file system to get abase line of all the files and there timestamps. So no need all files and a record of files that have been stubbed
- If non-stubbed file data is dropped, how do we support future rule changes that need historical context (e.g., rerunning policies, producing space-savings estimates)?
ANSWER: we will not be dropping them we need them for reference
- **NEW**: For LucidLink volumes, should we distinguish between files scanned via initial CSV import vs. files only updated via audit logs?
OPEN: Do we need a flag/column indicating update source (full_scan, audit_log, incremental_scan)?
- What retention period is required for stubbed file records and their lifecycle states (planned, stubbed, rehydrated, deleted)?
ANSWER: The retension period for with regauds to automatiaclly removeing files is not an option however:
planned = will be either a default setting of 1 year or older or a custom setting from the client
stubed = remain for ever unless one of the other rules overide it
rehydrated = Rules to be determined  but will be set in the clients global settings
deleted = Rules to be determined but will be set in the clients global settings
- Do we need to snapshot stub states over time for analytics/audit, or can we rely on the latest state plus an audit log?
ANSWER: no

## Staging & Ingest Flow
- Once the CSV/Parquet batch lands in staging, which columns must persist into the core schema versus being used only for transient calculations?
ANSER: 
- Can staging tables be truncated immediately after tiering decisions are made, or do we require delayed cleanup for troubleshooting?
- How should we handle partial ingest failures when only stubbed records are stored—do we retry at the file level or reprocess the entire batch?
- **NEW**: Do we need a separate staging table for LucidLink audit updates (`staging_lucid_audit`) or can we reuse existing staging infrastructure?
RECOMMENDATION: Separate table due to different schema (only file_path + timestamp vs. full metadata)
- **NEW**: What is the retention period for `staging_lucid_audit` records? Can they be truncated immediately after processing?
RECOMMENDATION: Truncate after successful processing + audit log entry; retain 24 hours for troubleshooting
- **NEW**: How do we handle LucidLink audit events for files not in our inventory (deleted files, new files not yet scanned)?
OPEN: Should we queue these for investigation or ignore them?

## Stub Registry Model
- What minimal attributes define a stubbed object (e.g., source path, tiered URI, hash, size, timestamps, job reference, agent/host)?
- Do we need to track multiple stub incarnations for the same file path (e.g., when a file is rehydrated then re-tiered)?
- How do we represent relationships between stubs and tiering jobs or planner runs?
- Are there tenant-specific metadata fields (custom tags, business units) that must live with the stub record?
- **NEW**: Should the file inventory table include an `update_source` column to track whether last_accessed came from full scan or LucidLink audit?
RECOMMENDATION: Add `last_accessed_source` ENUM ('initial_scan', 'lucidlink_audit', 'incremental_scan', 'manual')
- **NEW**: Do we need `updated_utc` timestamp on file records to track when last_accessed was last modified?
RECOMMENDATION: Yes, add `updated_utc` column for audit trail and debugging

## Rehydration & Recovery
- What data is required to orchestrate rehydration without a full file inventory (e.g., original NTFS ACLs, ownership, compression/encryption parameters)?
- Should rehydration attempts update the same stub record, create child records, or log events elsewhere?
- How do we ensure orphan detection if only stub data is stored—do we inventory Tier-2 storage separately and compare against stub registry?
- **NEW**: When LucidLink audit logs indicate file access, should we automatically trigger rehydration for stubbed files?
OPEN: Define policy—immediate rehydration vs. alert-only vs. configurable per customer
- **NEW**: How do we track "warming" events—files that were stubbed but recently accessed per audit logs?
RECOMMENDATION: Add `tier_object.last_accessed_utc` and `tier_object.access_count` for trending analysis

## Multi-Tenancy & Security
- Will we continue with shared tables plus row-level security, or is a schema-per-tenant layout preferable for the reduced data set?
- Which columns need encryption at rest via Vault (e.g., tiered_location, credentials, hashes)?
- How are tenant-scoped API tokens mapped to database roles and RLS policies during ingest and planner execution?

## Audit & Observability
- What events must be captured in the audit log to evidence stub lifecycle changes (creation, rehydration, deletion, failure)?
- Do we need derived tables or materialized views for dashboards, or can analytics read directly from the stub registry and audit log?
- Which metrics should be exposed for monitoring stub throughput, failures, and storage consumption?

## Integration with Planner & Actor
- How will the planner evaluate tiering rules if the core store lacks non-stubbed file metadata? Do we compute rule matches entirely in-memory from staging?
- What identifiers do planner and actor services use to correlate jobs with stub records when only stubbed data is persisted?
- Do we need to persist planner scoring/estimates (space saved, duration) alongside the stub record for reporting?
- **NEW**: Should the planner be triggered after every LucidLink audit batch update, or only when updates affect planned/stubbed files?
RECOMMENDATION: Selective re-evaluation—only check files in 'PLANNED' or 'STUBBED' state
- **NEW**: How do we handle race conditions where audit logs update last_accessed while tiering is in progress?
OPEN: Need locking strategy or state machine to prevent conflicts
- **NEW**: What is the acceptable lag between audit log event and planner re-evaluation?
RECOMMENDATION: Near real-time (< 15 minutes) for stubbed files; batch processing for planned files

## Migration & Tooling
- What is the bootstrap process for creating tenants, hosts, and stub records in development environments?
- Which migrations, seed data, or fixtures are required so engineers can run end-to-end flows locally?
- Do we need rollback strategies for schema changes given the reduced dataset, and how will we validate them in CI?

## LucidLink Audit Log Specific Questions

### Parsing & Format
- What is the exact format of `.active` files in `.lucid_audit` folders?
OPEN: Need LucidLink documentation or reverse engineering
- Do audit files contain event IDs for idempotency, or must we generate our own?
OPEN: Test with real LucidLink volume
- What access types are logged (read, write, modify, delete, metadata)? Do we care about all or just "read" for last_accessed?
RECOMMENDATION: Focus on read/open events for last_accessed updates

### Performance & Scalability
- How many audit events are generated per day for a typical LucidLink volume?
OPEN: Need baseline metrics to size staging tables and workers
- What is the size of `.active` files? Can they fit in memory for parsing?
OPEN: May need streaming parser for large audit files
- Should we process audit files sequentially or in parallel?
RECOMMENDATION: Parallel processing with worker pool; track progress per file

### State Management
- How do we track "last processed position" in each audit file to support incremental processing?
RECOMMENDATION: Add `lucid_audit_cursor` table with (tenant_id, volume_id, audit_file, last_position, last_event_id, last_processed_utc)
- What happens when audit files are rotated/archived by LucidLink?
OPEN: Need to handle file renames, deletions, and potential gaps

### Data Quality
- How do we validate that audit log timestamps are trustworthy and not clock-skewed?
RECOMMENDATION: Compare against last known timestamp; reject if > 7 days in future or too far in past
- What if audit logs reference files with paths that don't match our inventory?
RECOMMENDATION: Log warnings; optionally queue for next full scan

## Open Assumptions to Validate
- Rule evaluation can operate without the full file inventory once stub creation is complete.
- All reporting requirements can be satisfied using stub records plus audits.
- Agents can supply any additional metadata needed for rehydration on demand rather than relying on stored file attributes.
- **NEW**: LucidLink audit logs provide sufficient accuracy for last_accessed updates (no missed events, no corruption)
- **NEW**: Polling `.lucid_audit` every 5 minutes does not impact LucidLink performance or stability
- **NEW**: Audit log format is stable across LucidLink versions (forward/backward compatibility)

