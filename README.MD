# ElasticSearch Memory Diagnostics Tool



## Overview

The ElasticSearch Memory Diagnostics Tool is a comprehensive monitoring solution designed to help administrators quickly identify and resolve memory-related issues in ElasticSearch deployments on RHEL 8 systems. With its intuitive visual interface and actionable insights, it transforms complex memory metrics into clear, understandable diagnostics.

## Key Features

- **At-a-Glance Diagnostics**: Color-coded dashboard showing real-time memory status
- **Root Cause Analysis**: Automatic identification of memory issues with plain English explanations
- **Actionable Recommendations**: Prioritized steps to resolve detected problems
- **Automatic Snapshots**: Forensic data collection during critical events
- **Trend Analysis**: Memory usage tracking with visual indicators
- **System Optimization Checks**: Validation of ElasticSearch best practices
- **Lightweight Operation**: Minimal resource footprint (<1% CPU, <10MB RAM)

## Installation

### Prerequisites

- RHEL 8 or compatible (CentOS 8, Rocky Linux 8)
- Python 3.6+
- ElasticSearch 7.x+
- Root privileges

### Quick Install

```bash
# Download the tool
curl -O https://example.com/es_monitor.py
chmod +x es_monitor.py

# Verify functionality
sudo ./es_monitor.py monitor
```

## Usage

### Basic Commands

| Command     | Description                           | Example                          |
| ----------- | ------------------------------------- | -------------------------------- |
| `monitor`   | Start real-time diagnostics dashboard | `sudo ./es_monitor.py monitor`   |
| `install`   | Install as background service         | `sudo ./es_monitor.py install`   |
| `report`    | Generate performance report           | `sudo ./es_monitor.py report`    |
| `optimize`  | Check system optimizations            | `sudo ./es_monitor.py optimize`  |
| `uninstall` | Remove background service             | `sudo ./es_monitor.py uninstall` |

### Service Management

```bash
# Start service
sudo systemctl start es-monitor

# Check status
sudo systemctl status es-monitor

# View live logs
journalctl -u es-monitor -f
```

## Understanding the Dashboard

When running in monitor mode, you'll see a real-time dashboard with:

### System Memory Status

- Color-coded usage indicators (Green/Yellow/Red)
- Available vs. total memory
- Usage percentage relative to threshold

### ElasticSearch Memory

- Resident Set Size (RSS)
- Swap usage
- Percentage of system memory used

### Problem Analysis

- Root causes of memory issues
- Severity indicators (Critical/Warning/Info)
- Memory trend direction (Increasing/Decreasing)

### Recommended Actions

- Specific commands to run
- Configuration changes needed
- Optimization suggestions

## Diagnostic Snapshots

During critical events, the tool automatically captures system snapshots stored in `/var/log/es_diag/`. Each snapshot includes:

- Top memory-consuming processes
- Memory allocation breakdown
- I/O statistics
- Virtual memory metrics
- Open file handles
- Network connections

### Sample snapshot file

```text
diag_20230729_142305.log
├── System Overview
├── Memory Summary
├── ElasticSearch Top
├── Process Tree
├── IO Stats
├── VM Stats
├── Open Files
└── Network Connections
```

## Performance Reporting

Generate comprehensive reports with:

```bash
sudo ./es_monitor.py report
```

### Reports include:

- Monitoring period and duration
- Peak memory/swap usage
- Threshold violations
- Problem severity analysis
- Specific recommendations
- Optimization checklist

## System Optimization Checks

Validate your ElasticSearch configuration with:

```bash
sudo ./es_monitor.py optimize
```

### Checks include:

- Kernel parameter validation (swappiness, max\_map\_count)
- Transparent Huge Pages status
- Memory lock configuration
- JVM heap settings
- Bootstrap configuration

## Troubleshooting

### Common Issues

**ElasticSearch process not found:**

```bash
sudo systemctl status elasticsearch
ps aux | grep elasticsearch
```

**Permission errors:**

```bash
sudo chmod +x es_monitor.py
sudo ./es_monitor.py [command]
```

**Service installation fails:**

```bash
sudo ./es_monitor.py uninstall
sudo rm /etc/systemd/system/es-monitor.service
sudo systemctl daemon-reload
sudo ./es_monitor.py install
```

### Log Locations

- Main log: `/var/log/es_monitor.log`
- Diagnostic snapshots: `/var/log/es_diag/`
- Service logs: `journalctl -u es-monitor`

## Uninstallation

Complete removal:

```bash
sudo ./es_monitor.py uninstall  # Remove service
sudo rm es_monitor.py           # Remove script
sudo rm -r /var/log/es_diag     # Remove diagnostics
sudo rm /var/log/es_monitor*    # Remove logs
```

## Support

For assistance, contact your infrastructure team with:

1. Tool version
2. RHEL version (`cat /etc/redhat-release`)
3. ElasticSearch version (`/usr/share/elasticsearch/bin/elasticsearch -V`)
4. Relevant logs from `/var/log/es_diag/`

---

**License**: Apache 2.0\
**Version**: 1.0.0\
**Last Updated**: July 29, 2025

