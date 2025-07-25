#!/usr/bin/env python3
"""
ElasticSearch Memory and Swap Usage Monitor for RHEL 8.10

Usage:
- Interactive mode: python3 es_mem_monitor.py
  - Launches a text-based menu for monitoring and configuration.
- Daemon mode: python3 es_mem_monitor.py --daemon --interval <seconds> --log <path>
  - Runs monitoring continuously, suitable for systemd service.

Features:
- Monitors ElasticSearch process memory and swap usage.
- Logs metrics to a configurable file.
- Installs as a systemd service for background monitoring.
- Generates reports with peak usage and threshold exceedances.
- Checks system configuration for ElasticSearch optimization.
"""

import os
import subprocess
import threading
import time
import datetime
import csv
import sys

# Default configuration settings
interval = 1.0  # Sampling interval in seconds
log_path = '/var/log/es_mem_monitor.log'  # Default log file path
threshold = 80  # Threshold percentage for alerts

# Global variables for monitoring control
monitoring_active = False
monitoring_thread = None

def get_es_pid():
    """Find the PID of the ElasticSearch process."""
    try:
        output = subprocess.check_output(["pgrep", "-f", "java.*org.elasticsearch.bootstrap.Elasticsearch"])
        pids = output.decode().strip().split()
        if pids:
            return int(pids[0])
        return None
    except subprocess.CalledProcessError:
        return None

def get_metrics(pid):
    """Collect memory and swap metrics for the given PID."""
    metrics = {}
    metrics['timestamp'] = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    
    # ElasticSearch process metrics from /proc/<pid>/status
    try:
        with open(f'/proc/{pid}/status', 'r') as f:
            for line in f:
                if line.startswith('VmRSS:'):
                    metrics['es_rss_mb'] = int(line.split()[1]) / 1024.0  # kB to MB
                elif line.startswith('VmSwap:'):
                    metrics['es_swap_mb'] = int(line.split()[1]) / 1024.0  # kB to MB
    except (FileNotFoundError, PermissionError):
        print("Error: Cannot access /proc/<pid>/status. Run with sudo if necessary.")
        return None
    
    # System memory metrics from /proc/meminfo
    with open('/proc/meminfo', 'r') as f:
        for line in f:
            if line.startswith('MemTotal:'):
                mem_total = int(line.split()[1]) / 1024.0  # kB to MB
            elif line.startswith('MemFree:'):
                mem_free = int(line.split()[1]) / 1024.0  # kB to MB
            elif line.startswith('MemAvailable:'):
                metrics['mem_available_mb'] = int(line.split()[1]) / 1024.0  # kB to MB
            elif line.startswith('SwapTotal:'):
                swap_total = int(line.split()[1]) / 1024.0  # kB to MB
            elif line.startswith('SwapFree:'):
                swap_free = int(line.split()[1]) / 1024.0  # kB to MB
    metrics['total_ram_used_mb'] = mem_total - mem_free
    metrics['total_swap_used_mb'] = swap_total - swap_free
    
    # Swap in/out rates from /proc/vmstat
    with open('/proc/vmstat', 'r') as f:
        for line in f:
            if line.startswith('pswpin'):
                metrics['pswpin'] = int(line.split()[1])
            elif line.startswith('pswpout'):
                metrics['pswpout'] = int(line.split()[1])
    
    return metrics

def monitoring_loop():
    """Run the monitoring loop, logging metrics to file."""
    global monitoring_active
    pid = get_es_pid()
    if not pid:
        print("Error: ElasticSearch process not found.")
        return
    
    prev_pswpin = None
    prev_pswpout = None
    prev_time = None
    
    try:
        with open(log_path, 'a') as log_file:
            writer = csv.DictWriter(log_file, fieldnames=[
                'timestamp', 'es_rss_mb', 'es_swap_mb', 'total_ram_used_mb',
                'mem_available_mb', 'total_swap_used_mb', 'swap_in_ps', 'swap_out_ps'
            ])
            if log_file.tell() == 0:
                writer.writeheader()
            
            while monitoring_active:
                current_time = time.time()
                metrics = get_metrics(pid)
                if not metrics:
                    break
                
                if prev_pswpin is not None:
                    dt = current_time - prev_time
                    swap_in_ps = (metrics['pswpin'] - prev_pswpin) / dt
                    swap_out_ps = (metrics['pswpout'] - prev_pswpout) / dt
                else:
                    swap_in_ps = 0
                    swap_out_ps = 0
                
                log_metrics = {k: v for k, v in metrics.items() if k not in ['pswpin', 'pswpout']}
                log_metrics['swap_in_ps'] = swap_in_ps
                log_metrics['swap_out_ps'] = swap_out_ps
                writer.writerow(log_metrics)
                log_file.flush()
                
                prev_pswpin = metrics['pswpin']
                prev_pswpout = metrics['pswpout']
                prev_time = current_time
                time.sleep(interval)
    except PermissionError:
        print(f"Error: Cannot write to {log_path}. Run with sudo or check permissions.")
        monitoring_active = False

def start_monitoring():
    """Start monitoring in a separate thread."""
    global monitoring_thread, monitoring_active
    if monitoring_thread is not None:
        print("Monitoring is already running.")
    else:
        monitoring_active = True
        monitoring_thread = threading.Thread(target=monitoring_loop)
        monitoring_thread.start()
        print("Monitoring started.")

def stop_monitoring():
    """Stop the monitoring thread."""
    global monitoring_thread, monitoring_active
    if monitoring_thread is None:
        print("Monitoring is not running.")
    else:
        monitoring_active = False
        monitoring_thread.join()
        monitoring_thread = None
        print("Monitoring stopped.")

def configure_settings():
    """Configure monitoring settings interactively."""
    global interval, log_path, threshold
    while True:
        print("\nCurrent Settings:")
        print(f"1. Sampling Interval: {interval} seconds")
        print(f"2. Log File Path: {log_path}")
        print(f"3. Threshold: {threshold}%")
        print("4. Back to main menu")
        choice = input("Select an option to change (1-4): ")
        
        if choice == '1':
            try:
                interval = float(input("Enter new sampling interval (seconds): "))
                if interval <= 0:
                    raise ValueError
                print(f"Interval set to {interval} seconds.")
            except ValueError:
                print("Invalid input. Please enter a positive number.")
        elif choice == '2':
            log_path = input("Enter new log file path: ")
            print(f"Log file path set to {log_path}.")
        elif choice == '3':
            try:
                threshold = int(input("Enter new threshold percentage (0-100): "))
                if not 0 <= threshold <= 100:
                    raise ValueError
                print(f"Threshold set to {threshold}%.")
            except ValueError:
                print("Invalid input. Please enter a number between 0 and 100.")
        elif choice == '4':
            break
        else:
            print("Invalid option.")

def install_service():
    """Install the script as a systemd service."""
    if os.geteuid() != 0:
        print("Error: Need root privileges to install service. Run with sudo.")
        return
    
    unit_file = "/etc/systemd/system/esram-monitor.service"
    script_path = os.path.abspath(__file__)
    try:
        with open(unit_file, 'w') as f:
            f.write(f"""[Unit]
Description=ElasticSearch Memory Monitor
[Service]
ExecStart=/usr/bin/python3 {script_path} --daemon --interval {interval} --log {log_path}
Restart=always
[Install]
WantedBy=multi-user.target
""")
        subprocess.run(["systemctl", "daemon-reload"], check=True)
        subprocess.run(["systemctl", "enable", "esram-monitor.service"], check=True)
        subprocess.run(["systemctl", "start", "esram-monitor.service"], check=True)
        print("Service installed and started successfully.")
    except (PermissionError, subprocess.CalledProcessError) as e:
        print(f"Error installing service: {e}")

def uninstall_service():
    """Uninstall the systemd service."""
    if os.geteuid() != 0:
        print("Error: Need root privileges to uninstall service. Run with sudo.")
        return
    
    try:
        subprocess.run(["systemctl", "stop", "esram-monitor.service"], check=True)
        subprocess.run(["systemctl", "disable", "esram-monitor.service"], check=True)
        os.remove("/etc/systemd/system/esram-monitor.service")
        subprocess.run(["systemctl", "daemon-reload"], check=True)
        print("Service uninstalled successfully.")
    except (PermissionError, subprocess.CalledProcessError, FileNotFoundError) as e:
        print(f"Error uninstalling service: {e}")

def generate_report():
    """Generate a report from the log file."""
    try:
        with open('/proc/meminfo', 'r') as f:
            for line in f:
                if line.startswith('MemTotal:'):
                    mem_total = int(line.split()[1]) / 1024.0  # kB to MB
                elif line.startswith('SwapTotal:'):
                    swap_total = int(line.split()[1]) / 1024.0  # kB to MB
        
        with open(log_path, 'r') as f:
            reader = csv.DictReader(f)
            data = list(reader)
        
        if not data:
            print("No data available in the log file.")
            return
        
        # Compute peak values
        max_es_rss = max(float(row['es_rss_mb']) for row in data)
        max_es_swap = max(float(row['es_swap_mb']) for row in data)
        max_swap_used = max(float(row['total_swap_used_mb']) for row in data)
        min_mem_available = min(float(row['mem_available_mb']) for row in data)
        
        # Threshold exceedances
        high_es_rss = [row for row in data if float(row['es_rss_mb']) > (threshold / 100) * mem_total]
        low_mem_available = [row for row in data if float(row['mem_available_mb']) < (1 - threshold / 100) * mem_total]
        high_swap_used = [row for row in data if float(row['total_swap_used_mb']) > (threshold / 100) * swap_total]
        swap_activity = [row for row in data if float(row['swap_in_ps']) > 0 or float(row['swap_out_ps']) > 0]
        
        # Generate report
        print("\nElasticSearch Memory and Swap Usage Report")
        print("==========================================")
        print(f"Total RAM: {mem_total:.2f} MB")
        print(f"Total Swap: {swap_total:.2f} MB")
        print(f"Threshold: {threshold}%")
        print("\nPeak Usage:")
        print(f"- Max ES RSS: {max_es_rss:.2f} MB ({max_es_rss / mem_total * 100:.1f}% of total RAM)")
        print(f"- Max ES Swap: {max_es_swap:.2f} MB")
        print(f"- Max Total Swap Used: {max_swap_used:.2f} MB ({max_swap_used / swap_total * 100:.1f}% of total swap)")
        print(f"- Min MemAvailable: {min_mem_available:.2f} MB ({min_mem_available / mem_total * 100:.1f}% of total RAM)")
        
        print("\nThreshold Exceedances:")
        if high_es_rss:
            print(f"- ES RSS exceeded {threshold}% of total RAM {len(high_es_rss)} times.")
        if low_mem_available:
            print(f"- MemAvailable dropped below {100 - threshold}% of total RAM {len(low_mem_available)} times.")
        if high_swap_used:
            print(f"- Total Swap Used exceeded {threshold}% of total swap {len(high_swap_used)} times.")
        
        if swap_activity:
            print("\nSwap Activity Detected:")
            for row in swap_activity[:5]:  # Limit to first 5 instances
                print(f"- {row['timestamp']}: Swap In = {float(row['swap_in_ps']):.2f} pages/s, Swap Out = {float(row['swap_out_ps']):.2f} pages/s")
            if len(swap_activity) > 5:
                print(f"... and {len(swap_activity) - 5} more instances.")
        
    except FileNotFoundError:
        print(f"Error: Log file {log_path} not found.")
    except PermissionError:
        print("Error: Permission denied accessing system files. Run with sudo.")

def system_optimization_check():
    """Check system parameters and provide optimization recommendations."""
    print("\nSystem Optimization Check")
    print("=========================")
    
    # Check vm.swappiness
    try:
        with open('/proc/sys/vm/swappiness', 'r') as f:
            swappiness = int(f.read().strip())
        if swappiness > 1:
            print(f"WARNING: vm.swappiness = {swappiness}. Recommend setting to 1 for ElasticSearch.")
    except (FileNotFoundError, PermissionError):
        print("Error: Cannot read vm.swappiness. Check permissions.")
    
    # Check swap status
    try:
        with open('/proc/meminfo', 'r') as f:
            for line in f:
                if line.startswith('SwapTotal:'):
                    swap_total = int(line.split()[1])
                    if swap_total > 0:
                        print("NOTE: Swap is enabled. ElasticSearch recommends disabling swap for performance.")
                    break
    except (FileNotFoundError, PermissionError):
        print("Error: Cannot read /proc/meminfo. Check permissions.")
    
    # Check memory lock settings
    try:
        with open('/etc/elasticsearch/elasticsearch.yml', 'r') as f:
            memory_lock = False
            for line in f:
                if line.strip().startswith('bootstrap.memory_lock:'):
                    value = line.split(':')[1].strip()
                    memory_lock = value == 'true'
                    break
            if not memory_lock:
                print("RECOMMENDATION: Set bootstrap.memory_lock: true in elasticsearch.yml to lock JVM heap in RAM.")
            else:
                pid = get_es_pid()
                if pid:
                    with open(f'/proc/{pid}/limits', 'r') as lf:
                        for line in lf:
                            if line.startswith('Max locked memory'):
                                limit = line.split()[3]
                                if limit != 'unlimited':
                                    print(f"WARNING: memlock limit is {limit}. Set to unlimited for memory locking.")
                                break
    except (FileNotFoundError, PermissionError):
        print("NOTE: Could not check memory lock settings. Verify /etc/elasticsearch/elasticsearch.yml permissions.")
    
    # Check Transparent Huge Pages
    try:
        with open('/sys/kernel/mm/transparent_hugepage/enabled', 'r') as f:
            thp = f.read().strip()
        if '[always]' in thp or '[madvise]' in thp:
            print("RECOMMENDATION: Disable Transparent Huge Pages (set to 'never') to avoid latency issues.")
    except (FileNotFoundError, PermissionError):
        print("Error: Cannot check THP settings. Check permissions.")
    
    # Check vm.max_map_count
    try:
        with open('/proc/sys/vm/max_map_count', 'r') as f:
            max_map_count = int(f.read().strip())
        if max_map_count < 262144:
            print(f"WARNING: vm.max_map_count = {max_map_count}. Recommend setting to at least 262144.")
    except (FileNotFoundError, PermissionError):
        print("Error: Cannot read vm.max_map_count. Check permissions.")

def main():
    """Main function to handle command-line arguments and menu."""
    global interval, log_path, monitoring_thread, monitoring_active
    
    # Check for daemon mode
    if '--daemon' in sys.argv:
        try:
            interval_idx = sys.argv.index('--interval') + 1
            log_idx = sys.argv.index('--log') + 1
            interval = float(sys.argv[interval_idx])
            log_path = sys.argv[log_idx]
            monitoring_active = True
            monitoring_loop()
        except (IndexError, ValueError):
            print("Error: Invalid arguments for daemon mode. Use: --daemon --interval <seconds> --log <path>")
            sys.exit(1)
    else:
        # Interactive menu
        while True:
            print("\nElasticSearch Memory Monitor Menu")
            print("=================================")
            print("1. Start Monitoring")
            print("2. Stop Monitoring")
            print("3. Configure Settings")
            print("4. Install as Service")
            print("5. Uninstall Service")
            print("6. Generate Report")
            print("7. System Optimization Check")
            print("8. Exit")
            choice = input("Select an option (1-8): ")
            
            if choice == '1':
                start_monitoring()
            elif choice == '2':
                stop_monitoring()
            elif choice == '3':
                configure_settings()
            elif choice == '4':
                install_service()
            elif choice == '5':
                uninstall_service()
            elif choice == '6':
                generate_report()
            elif choice == '7':
                system_optimization_check()
            elif choice == '8':
                if monitoring_thread is not None:
                    stop_monitoring()
                print("Exiting.")
                sys.exit(0)
            else:
                print("Invalid option. Please select 1-8.")

if __name__ == "__main__":
    main()
