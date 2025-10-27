# Alto Tiered Storage Management – Workflow Diagram

```mermaid
flowchart TD
  Admin[Admins & Support Users] --> UI[Web UI (React + RBAC)]
  UI --> API[Management API & WebSockets]
  API -->|Rule & config CRUD| CoreDB[(Postgres Core Schemas)]
  API -->|Tenant-scoped auth| Vault[Vault Transit<br/>Per-tenant keys]
  API --> MQ[Async Queue / Notifications]
  MQ --> AgentPull[Config & Job Fan-out]

  subgraph Postgres_Cluster [Postgres HA Cluster]
    Staging[(Staging Schemas)]
    Ingest[Ingest Workers]
    CoreDB
    Staging -->|COPY| Ingest -->|Normalize & Upsert| CoreDB
  end

  subgraph Services [Backend Services]
    Planner[Planner Service<br/>Tiering plan generation]
    Actor[Actor Service<br/>Tiering execution]
    Sanitizer[Sanitizer Service<br/>Inventory & reconciliation]
    Audit[Audit Log & Analytics]
  end

  Planner <-->|Policy context| CoreDB
  Planner -->|Tiering jobs| MQ
  Actor <-- MQ
  Actor -->|Stub/move status| CoreDB
  Actor -->|Moves tiered data| Tiered[Tier-2 Storage<br/>(SMB/S3/Azure)]
  Sanitizer -->|Inventory results| CoreDB
  Tiered --> Sanitizer
  CoreDB --> Audit
  API --> Audit

  subgraph TenantSite [Customer Site / Host]
    FS[Primary Tier-1 File System]
    Stub[EaseFilter Stub Driver]
    Agent[Host Agent Service<br/>(Go/.NET)]
    FS -.-> Stub
    Stub -.On-access triggers.-> Agent
    Agent -->|Heartbeat & metrics| API
    Agent -->|Metadata batches (CSV/Parquet)| API
    Agent <-- MQ
    Agent -->|Execute tier/rehydrate ops| Stub
    Agent -->|Fetch/restore files| Tiered
    Tiered --> Agent
    Agent -->|Recovery updates| CoreDB
  end

  CoreDB --> Dashboard[Analytics / Dashboard]
  API --> Dashboard

  subgraph Observability [Observability]
    SIEM[SIEM / Audit Export]
    Metrics[Prometheus & Grafana]
  end
  Audit --> SIEM
  Services --> Metrics
  Agent --> Metrics
  Vault -->|Audit trail| SIEM
```
