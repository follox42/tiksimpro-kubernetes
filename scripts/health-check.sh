# ==========================================
# docker/scripts/health-check.sh - Container health verification
# ==========================================
#!/bin/bash
# Health check script for TikSimPro containers
# This script is used by Kubernetes to verify container health

# Check if main application process is running
if ! pgrep -f "python.*main.py\|python.*scheduler.py" > /dev/null; then
    echo "ERROR: Main application process not running"
    exit 1
fi

# Check if required directories are accessible
required_dirs=("/app/data" "/app/logs" "/app/videos")
for dir in "${required_dirs[@]}"; do
    if [ ! -d "$dir" ] || [ ! -w "$dir" ]; then
        echo "ERROR: Directory $dir not accessible or not writable"
        exit 1
    fi
done

# Check disk space (fail if more than 90% full)
disk_usage=$(df /app | tail -1 | awk '{print $5}' | sed 's/%//')
if [ "$disk_usage" -gt 90 ]; then
    echo "ERROR: Disk usage too high: ${disk_usage}%"
    exit 1
fi

# Check memory usage (warn if more than 95% used)
if command -v free >/dev/null 2>&1; then
    memory_usage=$(free | grep Mem | awk '{printf "%.0f", $3/$2 * 100.0}')
    if [ "$memory_usage" -gt 95 ]; then
        echo "WARNING: Memory usage high: ${memory_usage}%"
        # Don't fail on memory warnings, just log them
    fi
fi

# Create a readiness indicator file
touch /app/data/.ready

echo "Health check passed - container is healthy"
exit 0