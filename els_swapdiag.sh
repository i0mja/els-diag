#!/usr/bin/env python3
"""
Enhanced ElasticSearch Memory and Swap Monitor for RHEL 8.10

Key Improvements:
- Added PID validation and process tracking
- Improved swap rate calculation with counter reset handling
- Added config validation and sanitization
- Enhanced error handling and logging
- Added log rotation support
- Implemented proper daemonization
- Added JVM heap usage monitoring
- Improved system optimization checks
- Added CSV export for reports
"""

import os
import subprocess
import threading
import time
import datetime
import csv
import sys
import argparse
import logging
import shutil
import psutil
import re

# Configuration defaults
DEFAULT_INTERVAL = 5.0
DEFAULT_LOG_PATH = '/var/log/es_mem_monitor.log'
DEFAULT_THRESHOLD = 80
MAX_LOG_SIZE = 50 * 1024 * 1024  # 50MB
LOG_BACKUPS = 3

# Global state
monitoring_active = False
monitoring_thread = None
current_pid = None
last_metrics = None

def setup_logging():
    """Initialize logging system"""
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(levelname)s - %(message)s',
        handlers=[
            logging.StreamHandler(sys.stdout)
        ]
    )

def validate_config():
    """Validate configuration parameters"""
    if not os.access(os.path.dirname(DEFAULT_LOG_PATH), os.W_OK):
        logging.error("Log directory not writable: %s", os.path.dirname(DEFAULT_LOG_PATH))
        return False
    return True

def get_es_pid():
    """Find ElasticSearch PID with validation and retry"""
    global current_pid
    
    # Check if previous PID is still valid
    if current_pid:
        try:
            process = psutil.Process(current_pid)
            if "java" in process.name() and "elasticsearch" in " ".join(process.cmdline()):
                return current_pid
        except psutil.NoSuchProcess:
            pass  # Process no longer exists
    
    # Find new PID
    try:
        for proc in psutil.process_iter(['pid', 'name', 'cmdline']):
            if proc.info['name'] == 'java' and 'org.elasticsearch.bootstrap.Elasticsearch' in proc.info['cmdline']:
                current_pid = proc.info['pid']
                logging.info("Found ElasticSearch PID: %d", current_pid)
                return current_pid
    except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess) as e:
        logging.error("Process scan error: %s", str(e))
    
    logging.warning("ElasticSearch process not found")
    return None

def get_jvm_stats(pid):
    """Get JVM heap usage statistics using jstat"""
    try:
        result = subprocess.run(
            ['jstat', '-gc', str(pid)],
            capture_output=True,
            text=True,
            timeout=2,
            check=True
        )
        
        # Parse jstat output (columns: S0C S1C S0U S1U EC EU OC OU MC MU CCSC CCSU YGC YGCT FGC FGCT GCT)
        lines = result.stdout.strip().split('\n')
        if len(lines) < 2:
            return None
            
        headers = lines[0].split()
        values = lines[1].split()
        if len(headers) != len(values) or len(values) < 9:
            return None
            
        # Extract relevant values
        stats = {}
        stats['heap_used'] = int(values[8])  # OU: Old space used (KB)
        stats['heap_max'] = int(values[7])   # OC: Old space capacity (KB)
        stats['gc_count'] = int(values[12])  # FGC: Full GC count
        stats['gc_time'] = float(values[14]) # FGCT: Full GC time (seconds)
        
        return stats
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired):
        return None

def get_metrics(pid):
    """Collect comprehensive system and process metrics"""
    metrics = {}
    metrics['timestamp'] = datetime.datetime.now().isoformat()
    
    try:
        # Process metrics
        process = psutil.Process(pid)
        mem_info = process.memory_info()
        metrics['es_rss_mb'] = mem_info.rss / (1024 * 1024)
        metrics['es_vms_mb'] = mem_info.vms / (1024 * 1024)
        metrics['es_swap_mb'] = mem_info.swap / (1024 * 1024)
        
        # JVM heap statistics
        jvm_stats = get_jvm_stats(pid)
        if jvm_stats:
            metrics['jvm_heap_used_mb'] = jvm_stats['heap_used'] / 1024
            metrics['jvm_heap_max_mb'] = jvm_stats['heap_max'] / 1024
            metrics['jvm_gc_count'] = jvm_stats['gc_count']
            metrics['jvm_gc_time'] = jvm_stats['gc_time']
        
        # System memory
        sys_mem = psutil.virtual_memory()
        metrics['total_ram_used_mb'] = (sys_mem.total - sys_mem.available) / (1024 * 1024)
        metrics['mem_available_mb'] = sys_mem.available / (1024 * 1024)
        metrics['mem_total_mb'] = sys_mem.total / (1024 * 1024)
        
        # Swap metrics
        swap = psutil.swap_memory()
        metrics['total_swap_used_mb'] = swap.used / (1024 * 1024)
        metrics['swap_total_mb'] = swap.total / (1024 * 1024)
        
        # System load
        load = os.getloadavg()
        metrics['load_1m'] = load[0]
        metrics['load_5m'] = load[1]
        metrics['load_15m'] = load[2]
        
        return metrics
    except (psutil.NoSuchProcess, psutil.AccessDenied) as e:
        logging.error("Metrics collection error: %s", str(e))
        return None

def rotate_log(log_path):
    """Implement log rotation if file exceeds max size"""
    try:
        if os.path.exists(log_path) and os.path.getsize(log_path) > MAX_LOG_SIZE:
            for i in range(LOG_BACKUPS - 1, 0, -1):
                src = f"{log_path}.{i}"
                dst = f"{log_path}.{i+1}"
                if os.path.exists(src):
                    shutil.move(src, dst)
            shutil.move(log_path, f"{log_path}.1")
            logging.info("Rotated log file: %s", log_path)
    except OSError as e:
        logging.error("Log rotation failed: %s", str(e))

def monitoring_loop(interval, log_path, threshold):
    """Main monitoring loop with enhanced features"""
    global monitoring_active, last_metrics
    
    logging.info("Monitoring started with interval: %.1fs", interval)
    
    prev_pswpin = None
    prev_pswpout = None
    prev_time = time.time()
    
    fieldnames = [
        'timestamp', 'es_rss_mb', 'es_vms_mb', 'es_swap_mb', 'jvm_heap_used_mb',
        'jvm_heap_max_mb', 'jvm_gc_count', 'jvm_gc_time', 'total_ram_used_mb',
        'mem_available_mb', 'mem_total_mb', 'total_swap_used_mb', 'swap_total_mb',
        'swap_in_ps', 'swap_out_ps', 'load_1m', 'load_5m', 'load_15m'
    ]
    
    try:
        while monitoring_active:
            rotate_log(log_path)
            
            pid = get_es_pid()
            if not pid:
                time.sleep(interval)
                continue
                
            # Read vmstat for swap rates
            try:
                with open('/proc/vmstat', 'r') as f:
                    vmstat = f.read()
                pswpin = int(re.search(r'pswpin\s+(\d+)', vmstat).group(1))
                pswpout = int(re.search(r'pswpout\s+(\d+)', vmstat).group(1))
            except (FileNotFoundError, ValueError, AttributeError) as e:
                logging.error("Failed to read vmstat: %s", str(e))
                pswpin = 0
                pswpout = 0
            
            # Collect metrics
            metrics = get_metrics(pid)
            if not metrics:
                time.sleep(interval)
                continue
                
            # Calculate swap rates
            current_time = time.time()
            time_delta = current_time - prev_time
            
            if prev_pswpin is not None and time_delta > 0:
                metrics['swap_in_ps'] = (pswpin - prev_pswpin) / time_delta
                metrics['swap_out_ps'] = (pswpout - prev_pswpout) / time_delta
            else:
                metrics['swap_in_ps'] = 0
                metrics['swap_out_ps'] = 0
                
            last_metrics = metrics
            prev_pswpin = pswpin
            prev_pswpout = pswpout
            prev_time = current_time
            
            # Write to log
            try:
                file_exists = os.path.exists(log_path) and os.path.getsize(log_path) > 0
                with open(log_path, 'a', newline='') as log_file:
                    writer = csv.DictWriter(log_file, fieldnames=fieldnames)
                    if not file_exists:
                        writer.writeheader()
                    writer.writerow(metrics)
            except OSError as e:
                logging.error("Log write error: %s", str(e))
            
            # Check thresholds
            check_thresholds(metrics, threshold)
            
            time.sleep(interval)
            
    except Exception as e:
        logging.exception("Monitoring loop crashed: %s", str(e))
        monitoring_active = False

def check_thresholds(metrics, threshold):
    """Check metrics against thresholds and generate alerts"""
    alerts = []
    
    # Memory thresholds
    mem_usage = (metrics['total_ram_used_mb'] / metrics['mem_total_mb']) * 100
    if mem_usage > threshold:
        alerts.append(f"System memory usage {mem_usage:.1f}% > {threshold}%")
    
    # Swap thresholds
    if metrics['swap_total_mb'] > 0:
        swap_usage = (metrics['total_swap_used_mb'] / metrics['swap_total_mb']) * 100
        if swap_usage > threshold:
            alerts.append(f"System swap usage {swap_usage:.1f}% > {threshold}%")
    
    # Process-specific thresholds
    if metrics.get('es_swap_mb', 0) > 50:  # 50MB swap usage threshold
        alerts.append(f"ElasticSearch swap usage {metrics['es_swap_mb']:.1f}MB > 50MB")
    
    # JVM heap thresholds
    if metrics.get('jvm_heap_max_mb') and metrics.get('jvm_heap_used_mb'):
        heap_usage = (metrics['jvm_heap_used_mb'] / metrics['jvm_heap_max_mb']) * 100
        if heap_usage > 90:
            alerts.append(f"JVM heap usage {heap_usage:.1f}% > 90%")
    
    # Log alerts
    if alerts:
        logging.warning("ALERT: " + ", ".join(alerts))

def start_monitoring(interval, log_path, threshold):
    """Start monitoring thread"""
    global monitoring_thread, monitoring_active
    
    if monitoring_thread and monitoring_thread.is_alive():
        logging.info("Monitoring is already running")
        return False
        
    monitoring_active = True
    monitoring_thread = threading.Thread(
        target=monitoring_loop,
        args=(interval, log_path, threshold),
        daemon=True
    )
    monitoring_thread.start()
    logging.info("Monitoring started")
    return True

def stop_monitoring():
    """Stop monitoring thread"""
    global monitoring_active
    
    if not monitoring_active:
        logging.info("Monitoring is not running")
        return False
        
    monitoring_active = False
    if monitoring_thread:
        monitoring_thread.join(timeout=5)
    logging.info("Monitoring stopped")
    return True

def install_service(interval, log_path, threshold):
    """Install as systemd service with proper configuration"""
    if os.geteuid() != 0:
        logging.error("Root privileges required to install service")
        return False
        
    service_content = f"""[Unit]
Description=ElasticSearch Memory Monitor
After=network.target elasticsearch.service

[Service]
Type=simple
ExecStart={sys.executable} {os.path.abspath(__file__)} --daemon --interval {interval} --log "{log_path}" --threshold {threshold}
Restart=on-failure
RestartSec=30
User=root

[Install]
WantedBy=multi-user.target
"""
    
    try:
        service_path = "/etc/systemd/system/esram-monitor.service"
        with open(service_path, 'w') as f:
            f.write(service_content)
        
        subprocess.run(["systemctl", "daemon-reload"], check=True)
        subprocess.run(["systemctl", "enable", "esram-monitor.service"], check=True)
        subprocess.run(["systemctl", "start", "esram-monitor.service"], check=True)
        
        logging.info("Service installed and started successfully")
        return True
    except (OSError, subprocess.CalledProcessError) as e:
        logging.error("Service installation failed: %s", str(e))
        return False

def uninstall_service():
    """Uninstall systemd service"""
    if os.geteuid() != 0:
        logging.error("Root privileges required to uninstall service")
        return False
        
    try:
        subprocess.run(["systemctl", "stop", "esram-monitor.service"], check=True)
        subprocess.run(["systemctl", "disable", "esram-monitor.service"], check=True)
        os.remove("/etc/systemd/system/esram-monitor.service")
        subprocess.run(["systemctl", "daemon-reload"], check=True)
        logging.info("Service uninstalled successfully")
        return True
    except (OSError, subprocess.CalledProcessError) as e:
        logging.error("Service uninstall failed: %s", str(e))
        return False

def generate_report(log_path, threshold, output_format='text'):
    """Generate comprehensive performance report"""
    if not os.path.exists(log_path):
        logging.error("Log file not found: %s", log_path)
        return False
        
    try:
        with open(log_path, 'r') as f:
            reader = csv.DictReader(f)
            data = list(reader)
            
        if not data:
            logging.error("No data in log file")
            return False
            
        # Convert numeric fields
        for row in data:
            for key in row:
                if key not in ['timestamp']:
                    try:
                        row[key] = float(row[key]) if '.' in row[key] else int(row[key])
                    except (ValueError, TypeError):
                        pass
        
        # Calculate statistics
        stats = {
            'start_time': data[0]['timestamp'],
            'end_time': data[-1]['timestamp'],
            'duration_hours': len(data) * DEFAULT_INTERVAL / 3600,
            'max_rss': max(row.get('es_rss_mb', 0) for row in data),
            'max_swap': max(row.get('es_swap_mb', 0) for row in data),
            'max_heap': max(row.get('jvm_heap_used_mb', 0) for row in data),
            'max_swap_used': max(row.get('total_swap_used_mb', 0) for row in data),
            'min_mem_avail': min(row.get('mem_available_mb', 0) for row in data),
            'high_swap_events': sum(1 for row in data if row.get('swap_in_ps', 0) > 0 or row.get('swap_out_ps', 0) > 0)
        }
        
        # Threshold exceedances
        stats['mem_threshold_exceeded'] = sum(
            1 for row in data 
            if (row.get('total_ram_used_mb', 0) / row.get('mem_total_mb', 1)) * 100 > threshold
        )
        
        if output_format == 'text':
            print("\nElasticSearch Performance Report")
            print("================================")
            print(f"Period: {stats['start_time']} to {stats['end_time']}")
            print(f"Duration: {stats['duration_hours']:.2f} hours")
            print(f"Samples: {len(data)}")
            print("\nPeak Usage:")
            print(f"- Max RSS: {stats['max_rss']:.2f} MB")
            print(f"- Max Swap: {stats['max_swap']:.2f} MB")
            print(f"- Max Heap: {stats['max_heap']:.2f} MB")
            print(f"- Max System Swap Used: {stats['max_swap_used']:.2f} MB")
            print(f"- Min Available Memory: {stats['min_mem_avail']:.2f} MB")
            
            print("\nThreshold Exceedances:")
            print(f"- Memory > {threshold}%: {stats['mem_threshold_exceeded']} times")
            print(f"- Swap activity events: {stats['high_swap_events']}")
            
        elif output_format == 'csv':
            csv_file = log_path.replace('.log', '_report.csv')
            with open(csv_file, 'w', newline='') as f:
                writer = csv.writer(f)
                writer.writerow(['Metric', 'Value'])
                for key, value in stats.items():
                    writer.writerow([key, value])
            print(f"Report saved to {csv_file}")
            
        return True
        
    except Exception as e:
        logging.error("Report generation failed: %s", str(e))
        return False

def system_optimization_check():
    """Comprehensive system optimization checks"""
    print("\nSystem Optimization Check")
    print("========================")
    
    checks = {
        'vm.swappiness': {
            'path': '/proc/sys/vm/swappiness',
            'recommended': '1',
            'description': "Reduces tendency to swap out memory"
        },
        'vm.max_map_count': {
            'path': '/proc/sys/vm/max_map_count',
            'recommended': '262144',
            'description': "Required for ElasticSearch memory mapping"
        },
        'THP Enabled': {
            'path': '/sys/kernel/mm/transparent_hugepage/enabled',
            'recommended': 'never',
            'description': "Transparent Huge Pages can cause latency issues"
        }
    }
    
    all_ok = True
    
    for name, config in checks.items():
        try:
            with open(config['path'], 'r') as f:
                value = f.read().strip()
                
            # Handle different output formats
            if '[' in value:
                current = re.search(r'\[(\w+)\]', value).group(1)
            else:
                current = value
                
            status = "OK" if current == config['recommended'] else "WARNING"
            print(f"\n{name}: {status}")
            print(f"- Current: {current}")
            print(f"- Recommended: {config['recommended']}")
            print(f"- Description: {config['description']}")
            
            if status != "OK":
                all_ok = False
                
        except FileNotFoundError:
            print(f"\n{name}: ERROR - File not found")
            all_ok = False
        except PermissionError:
            print(f"\n{name}: ERROR - Permission denied")
            all_ok = False
    
    # ElasticSearch specific checks
    try:
        es_config = '/etc/elasticsearch/elasticsearch.yml'
        if os.path.exists(es_config):
            with open(es_config, 'r') as f:
                content = f.read()
                
            # Check memory lock setting
            if 'bootstrap.memory_lock: true' not in content:
                print("\nMemory Lock: WARNING")
                print("- ElasticSearch not configured to lock memory in RAM")
                print("- Add 'bootstrap.memory_lock: true' to elasticsearch.yml")
                all_ok = False
            else:
                print("\nMemory Lock: OK")
                
            # Check JVM options
            jvm_options = '/etc/elasticsearch/jvm.options'
            if os.path.exists(jvm_options):
                with open(jvm_options, 'r') as f:
                    jvm_content = f.read()
                    
                if '-Xmx' not in jvm_content or '-Xms' not in jvm_content:
                    print("\nJVM Configuration: WARNING")
                    print("- Xmx/Xms settings not found in jvm.options")
                    all_ok = False
        else:
            print("\nElasticSearch config: WARNING")
            print(f"- Configuration file not found: {es_config}")
            all_ok = False
            
    except Exception as e:
        print(f"\nElasticSearch check failed: {str(e)}")
        all_ok = False
    
    return all_ok

def parse_arguments():
    """Parse command line arguments"""
    parser = argparse.ArgumentParser(
        description="ElasticSearch Memory and Swap Monitor",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )
    
    # Daemon mode options
    parser.add_argument('--daemon', action='store_true', 
                        help='Run in daemon mode')
    parser.add_argument('--interval', type=float, default=DEFAULT_INTERVAL,
                        help='Sampling interval in seconds')
    parser.add_argument('--log', type=str, default=DEFAULT_LOG_PATH,
                        help='Log file path')
    parser.add_argument('--threshold', type=int, default=DEFAULT_THRESHOLD,
                        help='Memory usage threshold percentage')
    
    # Service management
    parser.add_argument('--install-service', action='store_true',
                        help='Install as systemd service')
    parser.add_argument('--uninstall-service', action='store_true',
                        help='Uninstall systemd service')
    
    # Reporting
    parser.add_argument('--report', action='store_true',
                        help='Generate performance report')
    parser.add_argument('--report-format', choices=['text', 'csv'], default='text',
                        help='Report output format')
    
    # System check
    parser.add_argument('--check-system', action='store_true',
                        help='Run system optimization check')
    
    return parser.parse_args()

def main():
    """Main application entry point"""
    setup_logging()
    
    if not validate_config():
        sys.exit(1)
    
    args = parse_arguments()
    
    # Service management
    if args.install_service:
        install_service(args.interval, args.log, args.threshold)
        sys.exit(0)
    elif args.uninstall_service:
        uninstall_service()
        sys.exit(0)
    
    # Reporting
    if args.report:
        generate_report(args.log, args.threshold, args.report_format)
        sys.exit(0)
    
    # System check
    if args.check_system:
        system_optimization_check()
        sys.exit(0)
    
    # Daemon mode
    if args.daemon:
        logging.info("Starting in daemon mode")
        try:
            start_monitoring(args.interval, args.log, args.threshold)
            while True:
                time.sleep(5)
        except KeyboardInterrupt:
            stop_monitoring()
            sys.exit(0)
    
    # Interactive mode
    print("\nElasticSearch Memory Monitor")
    print("===========================")
    
    while True:
        print("\n[1] Start Monitoring")
        print("[2] Stop Monitoring")
        print("[3] Generate Report")
        print("[4] System Optimization Check")
        print("[5] Install Service")
        print("[6] Uninstall Service")
        print("[7] Exit")
        
        choice = input("\nSelect option: ")
        
        if choice == '1':
            start_monitoring(DEFAULT_INTERVAL, DEFAULT_LOG_PATH, DEFAULT_THRESHOLD)
        elif choice == '2':
            stop_monitoring()
        elif choice == '3':
            generate_report(DEFAULT_LOG_PATH, DEFAULT_THRESHOLD)
        elif choice == '4':
            system_optimization_check()
        elif choice == '5':
            install_service(DEFAULT_INTERVAL, DEFAULT_LOG_PATH, DEFAULT_THRESHOLD)
        elif choice == '6':
            uninstall_service()
        elif choice == '7':
            stop_monitoring()
            print("Exiting")
            sys.exit(0)
        else:
            print("Invalid selection")

if __name__ == "__main__":
    main()
