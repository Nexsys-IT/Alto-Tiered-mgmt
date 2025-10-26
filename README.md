# Alto Tiered Storage Management Solution

A centralized web-based management solution for automated file tiering and stubbing across distributed Windows hosts.

## Overview

This solution enables policy-driven data lifecycle management with comprehensive tracking, monitoring, and recovery capabilities. Files are automatically tiered to dedicated Windows File Shares based on customizable rules, with transparent rehydration when accessed.

## Key Features

- **Central Management Console** - Web-based interface for multi-customer tiering rule management
- **EaseFilter Integration** - Pre-built minifilter driver for transparent file stubbing and rehydration
- **Windows File Share Backend** - Simple, cost-effective storage using dedicated shares per customer
- **Automated Tiering Engine** - Rule-based file system scanning and tiering execution
- **Rehydration System** - On-demand and automated file restoration with per-customer policies
- **Analytics Dashboard** - Real-time visibility into tiering operations and storage metrics
- **Comprehensive Audit Trail** - Full event logging and compliance tracking
- **Orphan Detection** - Automated detection and recovery of orphaned stub files

## Technology Stack

### Backend
- API Server: Node.js (Express) or Python (FastAPI)
- Database: PostgreSQL
- Message Queue: RabbitMQ or Redis
- Time-Series DB: InfluxDB or TimescaleDB

### Frontend
- Framework: React with TypeScript
- UI Library: Material-UI or Ant Design
- Charts: Recharts or Chart.js

### Agent
- Language: Go or Rust
- Driver: EaseFilter minifilter (Windows)
- Storage: Windows File Shares (SMB/CIFS)

## Project Status

Currently in planning phase. See [project_plan.md](project_plan.md) for detailed project roadmap.

## Documentation

- [Project Plan](project_plan.md) - Comprehensive project plan with phases, roadblocks, and timeline

## License

TBD

## Contact

TBD
