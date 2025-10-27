# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Project Overview

**Alto Tiered Storage Management Solution** is a centralized web-based management solution for automated file tiering and stubbing across distributed Windows hosts. The system enables policy-driven data lifecycle management with comprehensive tracking, monitoring, and recovery capabilities.

**Current Status:** Planning phase - no code implementation yet. Only project documentation exists.

## System Architecture

### Three-Tier Architecture

1. **Central Management Server**
   - Web-based console for multi-tenant management
   - RESTful API + WebSocket for real-time updates
   - PostgreSQL for rules, config, and audit logs
   - InfluxDB/TimescaleDB for metrics
   - RabbitMQ/Redis for async operations

2. **Host Agents** (Distributed)
   - Written in Go or Rust for performance
   - File system scanning and tiering execution
   - Rehydration handling
   - gRPC communication with central server
   - Runs as Windows Service or systemd service

3. **Storage Backend**
   - Windows File Shares (SMB/CIFS) - one per customer
   - File server: Windows Server with Storage Spaces or SAN
   - NTFS permissions for security
   - Optional DFS for high availability

### Key Integration: EaseFilter Driver

- **Pre-built minifilter driver** for Windows (not custom developed)
- Handles transparent file stubbing and on-access rehydration
- Only requires configuration management from our system
- Critical configuration areas:
  - Service startup parameters
  - Filter registration settings
  - Monitored paths/volumes
  - Stub file format and metadata
  - Rehydration triggers
  - Cache policies

## Technology Stack

### Backend
- **Primary Options:** Node.js (Express) OR Python (FastAPI)
- **Database:** PostgreSQL (main), InfluxDB/TimescaleDB (metrics)
- **Message Queue:** RabbitMQ or Redis
- **Agent Communication:** gRPC

### Frontend
- **Framework:** React with TypeScript
- **UI Library:** Material-UI or Ant Design
- **State Management:** Redux or Zustand
- **Charts:** Recharts or Chart.js

### Agent
- **Language:** Go or Rust (final decision pending)
- **Windows Integration:** EaseFilter minifilter driver
- **Storage Protocol:** SMB/CIFS for file share access

## Core Components

### Rule Engine
Rules define tiering criteria:
- File age (last modified/accessed)
- File size thresholds
- File type/extension filters
- Path patterns (glob/regex)
- Ownership and permissions
- Custom metadata tags
- Priority and conflict resolution

### Stub Tracking System
- Central registry of all stubbed files
- Tracks stub-to-storage mappings
- Orphan detection (stubs without storage or vice versa)
- Integrity verification via SHA-256 hashes
- Real-time monitoring via file system watchers

### Rehydration System
Per-customer configurable policies:
- Automatic on-access (via driver)
- Manual on-demand (via UI/CLI)
- Policy-based scheduled restoration
- Bandwidth throttling
- Priority queues
- Retention period after rehydration

### Storage Backend
- Dedicated Windows File Share per customer
- Naming: `\\server\customer-{customer_id}-tiered`
- Automated provisioning for new customers
- Quota management
- Health monitoring
- Integration with backup systems

## Development Approach

### Project Phases (34 weeks total)
1. **Weeks 1-4:** Planning and Design
2. **Weeks 5-6:** Infrastructure Setup (CI/CD, dev environments)
3. **Weeks 7-12:** Core Backend Development (API, auth, database)
4. **Weeks 10-16:** Agent Development (scanning, tiering, rehydration)
5. **Weeks 13-16:** EaseFilter Driver Configuration Management
6. **Weeks 14-17:** Storage Backend Integration (SMB/file shares)
7. **Weeks 16-22:** Web UI Development
8. **Weeks 20-24:** Tracking and Monitoring Systems
9. **Weeks 22-28:** Testing and QA
10. **Weeks 26-30:** Documentation and Training
11. **Weeks 28-32:** Pilot Deployment
12. **Weeks 32-34:** Production Launch

### Multi-Tenant Design
- Customer isolation at database, storage, and rule level
- Separate file shares per customer
- RBAC for user permissions
- API key authentication for agents

### Critical Quality Requirements
- 99.9% uptime for management services
- Sub-second stub file access times
- Zero data loss during tiering/rehydration
- Support 100+ concurrent hosts per customer
- Complete audit trail for compliance

## Security Considerations

- **Authentication:** MFA, SSO (SAML/OAuth), API key rotation
- **Data Protection:** SMB 3.0+ encryption, NTFS permissions, optional encryption at rest
- **Network Security:** TLS/SSL for APIs, SMB signing, firewall rules
- **Access Control:** RBAC, Windows domain integration, least privilege principle
- **Audit Trail:** Tamper-proof logging, 7-year retention, SIEM integration

## Key Risk Areas

1. **EaseFilter Driver Integration:** Learning curve for API and configuration
2. **Performance at Scale:** Millions of files, efficient indexing required
3. **Data Integrity:** Hash verification at every step, atomic operations
4. **Network Reliability:** Robust retry logic, local queuing
5. **Storage Capacity:** File share capacity management, compression, quotas
6. **Windows Compatibility:** Test across Server 2016/2019/2022, Windows 10/11

## Documentation References

- [README.md](README.md) - Project overview and key features
- [project_plan.md](project_plan.md) - Comprehensive 34-week project plan with phases, roadblocks, and detailed requirements
