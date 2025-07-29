#!/usr/bin/env python3
"""
ElasticSearch Memory Diagnostics Tool - Enhanced Troubleshooting Edition

Features:
- Color-coded severity indicators
- Instant root cause analysis
- Actionable recommendations
- Visual trend indicators
- Diagnostic snapshots
- Plain English explanations
"""

import os
import sys
import time
import datetime
import csv
import argparse
import threading
import shutil
import subprocess
import re
from collections import deque

# Configuration
DEFAULT_INTERVAL = 10  # Seconds
LOG_PATH = '/var/log/es_monitor.log'
MAX_LOG_SIZE = 10 * 1024 * 1024  # 10MB
LOG_BACKUPS = 3
THRESHOLD = 85  # %
DIAG_DIR = '/var/log/es_diag'

# Color codes for terminal output
RED = "\033[1;31m"
GREEN = "\033[1;32m"
YELLOW = "\033[1;33m"
BLUE = "\033[1;34m"
MAGENTA = "\033[1;35m"
CYAN = "\033[1;36m"
RESET = "\033[0m"

# Global state
monitor_active = False
monitor_thread = None
last_pid = None
trend_history = deque(maxlen=5)  # Track memory trends

def validate_permissions():
    """Ensure required permissions"""
    try:
        os.makedirs(DIAG_DIR, exist_ok=True)
        checks = [
            ('/proc/meminfo', os.R_OK),
            ('/proc/vmstat', os.R_OK),
            (LOG_PATH, os.W_OK),
            (DIAG_DIR, os.W_OK)
        ]
        
        for path, mode in checks:
            if not os.access(path, mode):
                print(f"{RED}Permission error: Cannot access {path}{RESET}")
                print(f"{YELLOW}Run with sudo or check permissions{RESET}")
                return False
        return True
    except OSError as e:
        print(f"{RED}Permission validation failed: {str(e)}{RESET}")
        return False

def get_es_pid():
    """Find ElasticSearch PID efficiently"""
    global last_pid
    
    # Check previous PID first
    if last_pid and os.path.exists(f"/proc/{last_pid}"):
        try:
            with open(f"/proc/{last_pid}/cmdline", 'rb') as f:
                if b'org.elasticsearch.bootstrap.Elasticsearch' in f.read():
                    return last_pid
        except OSError:
            pass
    
    # Scan /proc
    for pid in os.listdir('/proc'):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/cmdline", 'rb') as f:
                if b'org.elasticsearch.bootstrap.Elasticsearch' in f.read():
                    last_pid = int(pid)
                    return last_pid
        except (FileNotFoundError, PermissionError):
            continue
    return None

def capture_diagnostic_snapshot(reason):
    """Capture system state when issues detected"""
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    diag_file = os.path.join(DIAG_DIR, f"diag_{timestamp}.log")
    
    commands = {
        "System Overview": "top -b -n1 -c | head -n20",
        "Memory Summary": "free -h",
        "ElasticSearch Top": "top -b -n1 -p $(pgrep -f elasticsearch) | grep -v '^top'",
        "Process Tree": "pstree -p $(pgrep -f elasticsearch)",
        "IO Stats": "iostat -dx 1 3",
        "VM Stats": "vmstat 1 3",
        "Open Files": "lsof -p $(pgrep -f elasticsearch) | wc -l",
        "Network Connections": "ss -tunp | grep elasticsearch"
    }
    
    try:
        with open(diag_file, 'w') as f:
            f.write(f"==== DIAGNOSTIC SNAPSHOT: {reason} ====\n")
            f.write(f"Timestamp: {datetime.datetime.now().isoformat()}\n\n")
            
            for title, cmd in commands.items():
                f.write(f"\n--- {title} ---\n")
                try:
                    result = subprocess.run(
                        cmd, shell=True, check=True,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                        text=True, timeout=5
                    )
                    f.write(result.stdout)
                except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
                    f.write(f"Command failed: {str(e)}\n")
        
        print(f"{CYAN}Saved diagnostic snapshot: {diag_file}{RESET}")
        return True
    except OSError as e:
        print(f"{RED}Failed to capture diagnostics: {str(e)}{RESET}")
        return False

def analyze_memory_issue(metrics):
    """Determine most likely cause of memory issues"""
    causes = []
    
    # System-wide memory pressure
    mem_usage = 100 - (metrics['mem_avail_mb'] / metrics['mem_total_mb'] * 100)
    if mem_usage > THRESHOLD:
        causes.append((
            RED + "SYSTEM MEMORY PRESSURE" + RESET,
            f"System memory usage at {mem_usage:.1f}% (threshold: {THRESHOLD}%)"
        ))
    
    # ElasticSearch specific issues
    es_mem_ratio = metrics['es_rss_mb'] / metrics['mem_total_mb'] * 100
    if es_mem_ratio > 70:
        causes.append((
            RED + "ELASTICSEARCH MEMORY HOG" + RESET,
            f"ES using {es_mem_ratio:.1f}% of total system memory"
        ))
    
    # Swap issues
    if metrics['swap_used_mb'] > 50:
        swap_ratio = metrics['swap_used_mb'] / metrics['swap_total_mb'] * 100
        if swap_ratio > 50:
            causes.append((
                YELLOW + "EXCESSIVE SWAPPING" + RESET,
                f"Swap usage at {swap_ratio:.1f}% ({metrics['swap_used_mb']:.1f}MB used)"
            ))
    
    # Trend analysis
    if len(trend_history) > 1:
        last_mem = trend_history[-2]['mem_avail_mb']
        current_mem = trend_history[-1]['mem_avail_mb']
        trend = "▲ INCREASING" if current_mem < last_mem else "▼ DECREASING"
        trend_color = RED if current_mem < last_mem else GREEN
        causes.append((
            BLUE + "MEMORY TREND" + RESET,
            f"Available memory: {trend_color}{trend}{RESET} "
            f"({last_mem:.1f}MB → {current_mem:.1f}MB)"
        ))
    
    # Process-level issues
    if metrics.get('es_swap_mb', 0) > 50:
        causes.append((
            YELLOW + "PROCESS SWAPPING" + RESET,
            f"ElasticSearch using {metrics['es_swap_mb']:.1f}MB of swap"
        ))
    
    # No issues found
    if not causes:
        return [(GREEN + "NORMAL OPERATION" + RESET, "No memory issues detected")]
    
    # Sort by severity (red first, then yellow, then blue)
    severity_order = {RED: 0, YELLOW: 1, BLUE: 2, GREEN: 3}
    return sorted(causes, key=lambda x: severity_order.get(x[0][:5], 3))

def get_recommendations(analysis):
    """Generate actionable recommendations based on analysis"""
    recommendations = []
    
    for cause, _ in analysis:
        if "SYSTEM MEMORY PRESSURE" in cause:
            recommendations.append(f"{MAGENTA}ACTION:{RESET} Identify top memory consumers with 'top' command")
            recommendations.append(f"{MAGENTA}ACTION:{RESET} Consider adding more RAM if this is persistent")
            recommendations.append(f"{MAGENTA}CONFIG:{RESET} Review ElasticSearch heap settings in jvm.options")
        
        if "ELASTICSEARCH MEMORY HOG" in cause:
            recommendations.append(f"{MAGENTA}ACTION:{RESET} Check ElasticSearch heap settings (Xmx/Xms)")
            recommendations.append(f"{MAGENTA}ACTION:{RESET} Investigate possible memory leaks in ElasticSearch")
            recommendations.append(f"{MAGENTA}CONFIG:{RESET} Ensure bootstrap.memory_lock=true in elasticsearch.yml")
        
        if "EXCESSIVE SWAPPING" in cause:
            recommendations.append(f"{MAGENTA}ACTION:{RESET} Reduce vm.swappiness (current: {get_swappiness()})")
            recommendations.append(f"{MAGENTA}ACTION:{RESET} Consider adding more RAM or reducing memory pressure")
            recommendations.append(f"{MAGENTA}CONFIG:{RESET} Verify swap space adequacy for workload")
        
        if "PROCESS SWAPPING" in cause:
            recommendations.append(f"{MAGENTA}ACTION:{RESET} Enable memory locking for ElasticSearch")
            recommendations.append(f"{MAGENTA}ACTION:{RESET} Check for out-of-memory errors in ElasticSearch logs")
    
    # Always include general recommendations
    recommendations.append(f"{MAGENTA}GENERAL:{RESET} Run './es_monitor.py optimize' to check system configuration")
    recommendations.append(f"{MAGENTA}GENERAL:{RESET} Check diagnostics in {DIAG_DIR} for detailed snapshots")
    
    return list(set(recommendations))  # Remove duplicates

def get_swappiness():
    """Get current swappiness value"""
    try:
        with open('/proc/sys/vm/swappiness', 'r') as f:
            return int(f.read().strip())
    except (FileNotFoundError, ValueError):
        return "Unknown"

def collect_metrics(pid):
    """Collect system and process metrics"""
    metrics = {'timestamp': datetime.datetime.now().isoformat()}
    
    try:
        # System memory
        with open('/proc/meminfo', 'r') as f:
            mem_data = f.read()
        
        # Process status
        with open(f'/proc/{pid}/status', 'r') as f:
            status_data = f.read()
        
        # VM stats
        with open('/proc/vmstat', 'r') as f:
            vmstat_data = f.read()
        
        # Parse memory info
        metrics['mem_total_mb'] = int(re_search(r'MemTotal:\s+(\d+)', mem_data)) / 1024
        metrics['mem_avail_mb'] = int(re_search(r'MemAvailable:\s+(\d+)', mem_data)) / 1024
        metrics['swap_total_mb'] = int(re_search(r'SwapTotal:\s+(\d+)', mem_data)) / 1024
        metrics['swap_free_mb'] = int(re_search(r'SwapFree:\s+(\d+)', mem_data)) / 1024
        metrics['swap_used_mb'] = metrics['swap_total_mb'] - metrics['swap_free_mb']
        
        # Parse process status
        metrics['es_rss_mb'] = int(re_search(r'VmRSS:\s+(\d+)', status_data)) / 1024
        metrics['es_swap_mb'] = int(re_search(r'VmSwap:\s+(\d+)', status_data)) / 1024
        
        # Parse vmstat
        metrics['pswpin'] = int(re_search(r'pswpin\s+(\d+)', vmstat_data))
        metrics['pswpout'] = int(re_search(r'pswpout\s+(\d+)', vmstat_data))
        
        # Store for trend analysis
        trend_history.append(metrics.copy())
        
        return metrics
    except (FileNotFoundError, PermissionError, ValueError) as e:
        print(f"{RED}Metric collection error: {str(e)}{RESET}")
        return None

def re_search(pattern, text):
    """Safe regex search with default"""
    match = re.search(pattern, text)
    return match.group(1) if match else '0'

def rotate_log():
    """Rotate log file if needed"""
    if os.path.exists(LOG_PATH) and os.path.getsize(LOG_PATH) > MAX_LOG_SIZE:
        try:
            for i in range(LOG_BACKUPS, 0, -1):
                src = f"{LOG_PATH}.{i-1}" if i > 1 else LOG_PATH
                dst = f"{LOG_PATH}.{i}"
                if os.path.exists(src):
                    shutil.move(src, dst)
            print(f"{CYAN}Rotated log file{RESET}")
        except OSError as e:
            print(f"{RED}Log rotation failed: {str(e)}{RESET}")

def display_status(metrics, analysis, recommendations):
    """Display current status with visual indicators"""
    # Header
    print(f"\n{BLUE}=== ElasticSearch Memory Status ==={RESET}")
    print(f"Time: {metrics['timestamp']}")
    print(f"PID: {last_pid or 'Not found'}")
    
    # Memory summary
    mem_usage = 100 - (metrics['mem_avail_mb'] / metrics['mem_total_mb'] * 100)
    mem_color = RED if mem_usage > THRESHOLD else YELLOW if mem_usage > 70 else GREEN
    print(f"\n{BLUE}System Memory:{RESET}")
    print(f"  Total: {metrics['mem_total_mb']:.1f} MB")
    print(f"  Available: {metrics['mem_avail_mb']:.1f} MB")
    print(f"  Usage: {mem_color}{mem_usage:.1f}%{RESET} (Threshold: {THRESHOLD}%)")
    
    # ElasticSearch memory
    es_mem_pct = metrics['es_rss_mb'] / metrics['mem_total_mb'] * 100
    es_color = RED if es_mem_pct > 70 else YELLOW if es_mem_pct > 50 else GREEN
    print(f"\n{BLUE}ElasticSearch:{RESET}")
    print(f"  RSS: {metrics['es_rss_mb']:.1f} MB ({es_color}{es_mem_pct:.1f}%{RESET} of system)")
    print(f"  Swap: {metrics['es_swap_mb']:.1f} MB")
    
    # Swap summary
    if metrics['swap_total_mb'] > 0:
        swap_usage = metrics['swap_used_mb'] / metrics['swap_total_mb'] * 100
        swap_color = RED if swap_usage > 50 else YELLOW if swap_usage > 20 else GREEN
        print(f"\n{BLUE}Swap Space:{RESET}")
        print(f"  Total: {metrics['swap_total_mb']:.1f} MB")
        print(f"  Used: {swap_color}{metrics['swap_used_mb']:.1f} MB ({swap_usage:.1f}%){RESET}")
    else:
        print(f"\n{BLUE}Swap Space:{RESET} {GREEN}Disabled{RESET}")
    
    # Root cause analysis
    print(f"\n{BLUE}=== Problem Analysis ==={RESET}")
    for cause, description in analysis:
        print(f"- {cause}: {description}")
    
    # Recommendations
    print(f"\n{BLUE}=== Recommended Actions ==={RESET}")
    for rec in recommendations:
        print(f"- {rec}")
    
    print("")

def monitor_loop(interval):
    """Main monitoring loop with enhanced diagnostics"""
    global monitor_active
    
    fieldnames = [
        'timestamp', 'mem_total_mb', 'mem_avail_mb', 'swap_total_mb',
        'swap_used_mb', 'es_rss_mb', 'es_swap_mb', 'pswpin', 'pswpout'
    ]
    
    last_pswpin = 0
    last_pswpout = 0
    last_time = time.time()
    last_alert = 0
    
    while monitor_active:
        rotate_log()
        
        pid = get_es_pid()
        if not pid:
            time.sleep(5)
            continue
        
        # Collect metrics
        start_time = time.time()
        metrics = collect_metrics(pid)
        if not metrics:
            time.sleep(interval)
            continue
        
        # Calculate swap rates
        current_time = time.time()
        time_delta = current_time - last_time
        
        metrics['swap_in_ps'] = (int(metrics['pswpin']) - last_pswpin) / time_delta
        metrics['swap_out_ps'] = (int(metrics['pswpout']) - last_pswpout) / time_delta
        
        # Update state
        last_pswpin = int(metrics['pswpin'])
        last_pswpout = int(metrics['pswpout'])
        last_time = current_time
        
        # Write to log
        try:
            file_exists = os.path.exists(LOG_PATH) and os.path.getsize(LOG_PATH) > 0
            with open(LOG_PATH, 'a', newline='') as log_file:
                writer = csv.DictWriter(log_file, fieldnames=fieldnames)
                if not file_exists:
                    writer.writeheader()
                writer.writerow(metrics)
        except OSError as e:
            print(f"{RED}Log write error: {str(e)}{RESET}")
        
        # Perform analysis
        analysis = analyze_memory_issue(metrics)
        recommendations = get_recommendations(analysis)
        
        # Display status on first run or when issues detected
        if not trend_history or any(RED in cause or YELLOW in cause for cause, _ in analysis):
            os.system('clear')  # Clear screen for better visibility
            display_status(metrics, analysis, recommendations)
            
            # Capture diagnostics for severe issues
            if any(RED in cause for cause, _ in analysis) and current_time - last_alert > 300:
                capture_diagnostic_snapshot("MEMORY CRITICAL")
                last_alert = current_time
        
        # Adaptive sleep
        elapsed = time.time() - start_time
        sleep_time = max(0.1, interval - elapsed)
        time.sleep(sleep_time)

def start_monitoring(interval):
    """Start monitoring in background thread"""
    global monitor_active, monitor_thread
    
    if monitor_thread and monitor_thread.is_alive():
        print(f"{YELLOW}Monitoring is already running{RESET}")
        return False
        
    monitor_active = True
    monitor_thread = threading.Thread(
        target=monitor_loop, 
        args=(interval,),
        daemon=True
    )
    monitor_thread.start()
    print(f"{GREEN}Monitoring started{RESET}")
    return True

def stop_monitoring():
    """Stop monitoring gracefully"""
    global monitor_active
    
    if not monitor_active:
        print(f"{YELLOW}Monitoring not active{RESET}")
        return False
    
    monitor_active = False
    if monitor_thread:
        monitor_thread.join(timeout=5)
    print(f"{GREEN}Monitoring stopped{RESET}")
    return True

def install_service(interval):
    """Create systemd service"""
    if not validate_permissions():
        return False
    
    script_path = os.path.abspath(__file__)
    service_content = f"""[Unit]
Description=ElasticSearch Memory Monitor
After=network.target elasticsearch.service

[Service]
Type=simple
ExecStart={sys.executable} {script_path} monitor --interval {interval}
Restart=on-failure
RestartSec=30
User=root

[Install]
WantedBy=multi-user.target
"""
    
    try:
        service_path = "/etc/systemd/system/es-monitor.service"
        
        if os.path.exists(service_path):
            print(f"{YELLOW}Service already exists{RESET}")
            return False
        
        with open(service_path, 'w') as f:
            f.write(service_content)
        
        subprocess.run(["systemctl", "daemon-reload"], check=True)
        subprocess.run(["systemctl", "enable", "es-monitor.service"], check=True)
        subprocess.run(["systemctl", "start", "es-monitor.service"], check=True)
        
        print(f"{GREEN}Service installed and started successfully{RESET}")
        print(f"Manage with: {CYAN}systemctl [status|stop|start] es-monitor.service{RESET}")
        return True
    except (OSError, subprocess.CalledProcessError) as e:
        print(f"{RED}Service installation failed: {str(e)}{RESET}")
        return False

def uninstall_service():
    """Remove systemd service"""
    if not validate_permissions():
        return False
    
    try:
        service_path = "/etc/systemd/system/es-monitor.service"
        
        if not os.path.exists(service_path):
            print(f"{YELLOW}Service not installed{RESET}")
            return False
        
        subprocess.run(["systemctl", "stop", "es-monitor.service"], check=True)
        subprocess.run(["systemctl", "disable", "es-monitor.service"], check=True)
        os.remove(service_path)
        subprocess.run(["systemctl", "daemon-reload"], check=True)
        
        print(f"{GREEN}Service uninstalled successfully{RESET}")
        return True
    except (OSError, subprocess.CalledProcessError) as e:
        print(f"{RED}Service uninstall failed: {str(e)}{RESET}")
        return False

def generate_report():
    """Create diagnostic report"""
    if not os.path.exists(LOG_PATH):
        print(f"{RED}Log file not found: {LOG_PATH}{RESET}")
        return False
    
    try:
        with open(LOG_PATH, 'r') as f:
            reader = csv.DictReader(f)
            data = list(reader)
        
        if not data:
            print(f"{YELLOW}No data in log file{RESET}")
            return False
        
        # Convert numeric fields
        for row in data:
            for key in row:
                if key != 'timestamp':
                    try:
                        row[key] = float(row[key])
                    except ValueError:
                        pass
        
        # Calculate statistics
        mem_total = data[0]['mem_total_mb']
        max_rss = max(row['es_rss_mb'] for row in data)
        max_swap = max(row['es_swap_mb'] for row in data)
        min_mem_avail = min(row['mem_avail_mb'] for row in data)
        max_swap_used = max(row['swap_used_mb'] for row in data)
        
        # Threshold violations
        threshold_violations = sum(
            1 for row in data 
            if (1 - (row['mem_avail_mb'] / row['mem_total_mb'])) * 100 > THRESHOLD
        )
        
        # Generate report
        print(f"\n{BLUE}=== ElasticSearch Diagnostic Report ==={RESET}")
        print(f"Period: {data[0]['timestamp']} to {data[-1]['timestamp']}")
        print(f"Duration: {len(data) * DEFAULT_INTERVAL / 3600:.2f} hours")
        print(f"Samples: {len(data)}")
        
        print(f"\n{BLUE}--- Peak Values ---{RESET}")
        print(f"- Max ES RSS: {RED if max_rss > mem_total * 0.7 else YELLOW}{max_rss:.2f} MB{RESET}")
        print(f"- Max ES Swap: {RED if max_swap > 100 else YELLOW if max_swap > 50 else ''}{max_swap:.2f} MB{RESET}")
        print(f"- Max System Swap: {RED if max_swap_used > mem_total * 0.5 else YELLOW}{max_swap_used:.2f} MB{RESET}")
        print(f"- Min Available RAM: {RED if min_mem_avail < mem_total * 0.1 else YELLOW}{min_mem_avail:.2f} MB{RESET}")
        
        print(f"\n{BLUE}--- Threshold Exceedances ---{RESET}")
        print(f"- Memory > {THRESHOLD}%: {RED if threshold_violations > 0 else GREEN}{threshold_violations}{RESET}")
        
        print(f"\n{BLUE}--- Recommendations ---{RESET}")
        if max_rss > mem_total * 0.7:
            print(f"- {MAGENTA}ACTION:{RESET} ElasticSearch is using >70% of system memory")
            print(f"  Consider increasing RAM or optimizing ElasticSearch memory usage")
        
        if max_swap > 100:
            print(f"- {MAGENTA}ACTION:{RESET} ElasticSearch swap usage exceeds 100MB")
            print(f"  Enable memory locking and check for memory pressure")
        
        if threshold_violations > 0:
            print(f"- {MAGENTA}ACTION:{RESET} Memory pressure occurred {threshold_violations} times")
            print(f"  Check diagnostic snapshots in {DIAG_DIR} for details")
        
        if not any([max_rss > mem_total * 0.7, max_swap > 100, threshold_violations > 0]):
            print(f"{GREEN}No critical issues detected{RESET}")
        
        print("")
        return True
        
    except Exception as e:
        print(f"{RED}Report generation failed: {str(e)}{RESET}")
        return False

def optimize_system():
    """Check and suggest system optimizations"""
    print(f"\n{BLUE}=== System Optimization Check ==={RESET}")
    
    checks = [
        ("vm.swappiness", "/proc/sys/vm/swappiness", "1", 
         "Reduce swapping tendency", "echo 1 > /proc/sys/vm/swappiness"),
        ("vm.max_map_count", "/proc/sys/vm/max_map_count", "262144", 
         "Increase memory maps", "echo 262144 > /proc/sys/vm/max_map_count"),
        ("THP Enabled", "/sys/kernel/mm/transparent_hugepage/enabled", "never", 
         "Disable for better latency", "echo never > /sys/kernel/mm/transparent_hugepage/enabled")
    ]
    
    for name, path, recommended, reason, fix_cmd in checks:
        try:
            with open(path, 'r') as f:
                value = f.read().strip()
            
            if '[' in value:
                current = re.search(r'\[(\w+)\]', value).group(1)
            else:
                current = value
                
            status = GREEN + "OK" + RESET if current == recommended else RED + "WARNING" + RESET
            print(f"\n{name}: {status}")
            print(f"Current: {current}")
            print(f"Recommended: {recommended}")
            print(f"Reason: {reason}")
            
            if current != recommended:
                print(f"Fix command: {MAGENTA}{fix_cmd}{RESET}")
        except (FileNotFoundError, PermissionError):
            print(f"\n{name}: {RED}ERROR - Cannot access {path}{RESET}")
    
    return True

def main():
    """Main application entry point"""
    # Pre-import regex to avoid try/except in hot path
    global re
    import re
    
    if not validate_permissions():
        sys.exit(1)
    
    parser = argparse.ArgumentParser(description="ElasticSearch Memory Diagnostics Tool")
    subparsers = parser.add_subparsers(dest='command')
    
    # Monitor command
    monitor_parser = subparsers.add_parser('monitor', help='Start real-time monitoring')
    monitor_parser.add_argument('--interval', type=int, default=DEFAULT_INTERVAL,
                               help='Sampling interval in seconds')
    
    # Service commands
    subparsers.add_parser('install', help='Install as systemd service')
    subparsers.add_parser('uninstall', help='Uninstall systemd service')
    
    # Report commands
    subparsers.add_parser('report', help='Generate performance report')
    subparsers.add_parser('optimize', help='Check system optimizations')
    
    args = parser.parse_args()
    
    # Command routing
    if args.command == 'monitor':
        start_monitoring(args.interval)
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            stop_monitoring()
    elif args.command == 'install':
        install_service(DEFAULT_INTERVAL)
    elif args.command == 'uninstall':
        uninstall_service()
    elif args.command == 'report':
        generate_report()
    elif args.command == 'optimize':
        optimize_system()
    else:
        print(f"{BLUE}ElasticSearch Memory Diagnostics Tool{RESET}")
        print("Usage:")
        print(f"  {CYAN}./es_monitor.py monitor{RESET}   - Start real-time diagnostics")
        print(f"  {CYAN}./es_monitor.py install{RESET}   - Install as background service")
        print(f"  {CYAN}./es_monitor.py report{RESET}    - Generate diagnostic report")
        print(f"  {CYAN}./es_monitor.py optimize{RESET}  - Check system optimizations")
        print(f"  {CYAN}./es_monitor.py uninstall{RESET} - Remove background service")

if __name__ == "__main__":
    main()
