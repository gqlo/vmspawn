#!/bin/bash
# A simple script to simulate bursty CPU and memory consumption in cycles

# Install stress-ng if not already present
if ! command -v stress-ng &> /dev/null; then
    echo "stress-ng not found, installing..."
    if command -v dnf &> /dev/null; then
        dnf install -y epel-release 2>/dev/null || true
        dnf install -y stress-ng
    elif command -v yum &> /dev/null; then
        yum install -y epel-release 2>/dev/null || true
        yum install -y stress-ng
    elif command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y stress-ng
    else
        echo "Error: no supported package manager found."
        exit 1
    fi
    if ! command -v stress-ng &> /dev/null; then
        echo "Error: failed to install stress-ng."
        exit 1
    fi
fi

# Function to generate a random number between min and max
random_range() {
    local min=$1
    local max=$2
    echo $(( min + RANDOM % (max - min + 1) ))
}

# Default settings
NUM_CYCLES=0              # 0 means run forever
BURST_MIN=5               # Minimum burst duration in seconds
BURST_MAX=600             # Maximum burst duration in seconds
ACTIVE_PROBABILITY=50     # Probability (%) that a VM will be active in a cycle
CPU_LOAD_MIN=50           # Minimum CPU load percentage
CPU_LOAD_MAX=100          # Maximum CPU load percentage
CPU_CORES=$(nproc)        # Number of CPU cores to use
MEM_WORKERS=1             # Number of memory workers
MAX_MEM_PERCENT=80        # Percentage of total memory to use

# generate a random range of memory percetange 
MEM_PERCENT=$(random_range 20 $MAX_MEM_PERCENT)

# Calculate memory to use based on system total memory
TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
MEM_TO_USE=$(( TOTAL_MEM * MEM_PERCENT / 100 ))

echo "Starting bursty workload simulation (running forever)"
echo "Using $CPU_CORES CPU cores"
echo "Memory usage: $MEM_TO_USE MB ($MEM_PERCENT% of system memory)"
echo "VM activity probability: $ACTIVE_PROBABILITY%"
echo "Press Ctrl+C to stop"
echo ""

# Run forever
cycle=1
while true; do
    # Generate random parameters for this cycle
    duration=$(random_range $BURST_MIN $BURST_MAX)
    cpu_load=$(random_range $CPU_LOAD_MIN $CPU_LOAD_MAX)
    
    # Determine if VM will be active this cycle (random probability)
    active_roll=$(random_range 1 100)
    if [ "$active_roll" -le "$ACTIVE_PROBABILITY" ]; then
        # VM is active - run stress
        echo "Cycle $cycle: ACTIVE - Running stress test for $duration seconds..."
        echo "  - CPU: $cpu_load%"
        echo "  - Memory: $MEM_TO_USE MB (aggressive, vm-keep)"
        
        #Run stress-ng with CPU and memory load including vm-keep and aggressive options
        stress-ng --cpu $CPU_CORES --cpu-load $cpu_load --vm $MEM_WORKERS --vm-bytes ${MEM_TO_USE}M --vm-keep --aggressive --timeout ${duration}s > /dev/null 2>&1
    else
        # VM is inactive - just idle for the duration
        echo "Cycle $cycle: IDLE - Sleeping for $duration seconds..."
        sleep $duration
    fi
    ((cycle++))
done
