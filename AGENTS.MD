# ElasticSearch Memory Monitor Agent

## Overview

This agent provides real-time monitoring and diagnostics for ElasticSearch memory usage on RHEL 8 systems. Designed for efficiency and ease of use, it offers:

- Continuous memory/swap monitoring
- Threshold-based alerts
- Performance reporting
- System optimization checks
- Service integration

## Features

- **Lightweight Monitoring**: <1% CPU, <10MB RAM usage
- **Real-time Alerts**: Threshold-based notifications
- **Built-in Log Rotation**: Automatic log management
- **Systemd Integration**: Easy service management
- **Optimization Checks**: Pre-configured system validation
- **Adaptive Sampling**: Maintains precise intervals
- **Zero Dependencies**: Pure Python implementation

## Requirements

- RHEL 8 or compatible (CentOS 8, Rocky Linux 8)
- Python 3.6+
- ElasticSearch 7.x+
- Root privileges for full functionality

## Installation

1. Download the agent:
```bash
curl -O https://example.com/es_monitor.py
chmod +x es_monitor.py
```

2. Validate permissions:
```bash
sudo ./es_monitor.py
```

## Usage

### Basic Commands

| Command | Description | Example |
|---------|-------------|---------|
| `monitor` | Start real-time monitoring | `sudo ./es_monitor.py monitor --interval 5` |
| `install` | Install as systemd service | `sudo ./es_monitor.py install` |
| `uninstall` | Remove systemd service | `sudo ./es_monitor.py uninstall` |
| `report` | Generate performance report | `sudo ./es_monitor.py report` |
| `optimize` | Check system optimizations | `sudo ./es_monitor.py optimize` |

### Service Management
```bash
# Start service
sudo systemctl start es-monitor

# Check status
sudo systemctl status es-monitor

# Stop service
sudo systemctl stop es-monitor

# View logs
journalctl -u es-monitor -f
```

### Configuration Options

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--interval` | 10s | Sampling interval (1-60s) |
| `--threshold` | 85% | Memory usage alert threshold |

Example custom configuration:
```bash
sudo ./es_monitor.py install --interval 5 --threshold 90
```

## Metrics Collected

The agent tracks these key metrics:

1. **System Memory**:
   - Total RAM
   - Available memory
   - Swap usage

2. **ElasticSearch Process**:
   - RSS (Resident Set Size)
   - Swap usage
   - Memory utilization percentage

3. **System Activity**:
   - Swap in/out rates
   - Memory pressure

## Log Files

- **Primary Log**: `/var/log/es_monitor.log`
- **Format**: CSV with timestamped metrics
- **Rotation**:
  - Rotates at 10MB
  - Keeps 3 backups
  - Automatic management

Sample log structure:
```csv
timestamp,mem_total_mb,mem_avail_mb,swap_total_mb,swap_used_mb,es_rss_mb,es_swap_mb,swap_in_ps,swap_out_ps
2023-07-29T12:00:00,32000.0,12000.0,8000.0,200.0,15000.0,50.0,0.0,0.0
```

## Alert Thresholds

Default triggers (configurable):

1. **Memory Pressure**: >85% system RAM usage
2. **Swap Utilization**: >85% swap space used
3. **Process Swap**: >50MB ElasticSearch swap usage

Alerts appear in:
- System journal
- Terminal output (when running interactively)
- Service logs

## Optimization Checks

Run `sudo ./es_monitor.py optimize` to validate:

1. **Kernel Parameters**:
   - vm.swappiness (recommended: 1)
   - vm.max_map_count (recommended: ≥262144)
   - Transparent Huge Pages (recommended: disabled)

2. **ElasticSearch Configuration**:
   - Memory lock setting
   - JVM heap configuration
   - Bootstrap checks

3. **System Recommendations**:
   - Swap space configuration
   - Memory allocation

## Reporting

Generate performance reports with:
```bash
sudo ./es_monitor.py report
```

Report includes:
- Monitoring period and duration
- Peak memory/swap usage
- Threshold violations
- System resource utilization
- Optimization recommendations

## Troubleshooting

### Common Issues

1. **Permission Errors**:
   ```bash
   sudo chmod +x es_monitor.py
   sudo ./es_monitor.py [command]
   ```

2. **ElasticSearch Not Found**:
   - Verify ES is running: `systemctl status elasticsearch`
   - Check process: `pgrep -af elasticsearch`

3. **Service Installation Fails**:
   - Uninstall first: `sudo ./es_monitor.py uninstall`
   - Verify systemd directory exists: `ls /etc/systemd/system`

### Log Locations
- Agent logs: `/var/log/es_monitor.log*`
- Service logs: `journalctl -u es-monitor`
- System logs: `/var/log/messages`

## Uninstallation

Complete removal:
```bash
sudo ./es_monitor.py uninstall  # Remove service
sudo rm /var/log/es_monitor*    # Remove logs
sudo rm es_monitor.py           # Remove agent
```

## Security

- Runs as root (required for system metrics)
- No external network access
- No persistent data collection
- Log files contain only system metrics

## License

Apache 2.0 - See [LICENSE](https://www.apache.org/licenses/LICENSE-2.0) for details.

## Support

Contact infrastructure-team@example.com for assistance. Include:
1. Agent version
2. RHEL version
3. ElasticSearch version
4. Relevant logs (`/var/log/es_monitor.log`)

---

**Version**: 1.1.0  
**Last Updated**: July 29, 2025  
**Compatibility**: RHEL 8+, ES 7.x+

