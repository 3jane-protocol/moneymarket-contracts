#!/bin/bash

# 3Jane Morpho Blue - Production Monitoring Script
# Continuous monitoring for mainnet deployment
# Run via cron: */5 * * * * /path/to/production-monitor.sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NETWORK="mainnet"
RPC_URL="${MAINNET_RPC_URL}"
ALERT_WEBHOOK="${SLACK_WEBHOOK_URL:-}"
LOG_FILE="/var/log/3jane-morpho/monitor.log"
METRICS_FILE="/var/log/3jane-morpho/metrics.json"

# Deployed contract addresses (Mainnet)
TIMELOCK="0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2"
PROTOCOL_CONFIG="0x6b276A2A7dd8b629adBA8A06AD6573d01C84f34E"
MORPHO_CREDIT="0xDe6e08ac208088cc62812Ba30608D852c6B0EcBc"
CREDIT_LINE="0xc9e2dB3cE1bb35aacDF638251A4AD891bDD8e5dF"
ADAPTIVE_CURVE_IRM="0xc3A8d4dD5CeC946B93E5F1bD1aAab63f826beb95"
USD3="0x37Bd5aAB956b39774711F86E5E0Ae1B19A6D5Fb9"
SUSD3="0xfE11E09f1a3f956d088aEbfAE87C19f887Ed1c71"
HELPER="0x970F965dFaE8090fa9dCc2DbC2dc6D652F087f42"

# Alert thresholds
MIN_LIQUIDITY="1000000000000" # 1M USDC in wei
MAX_UTILIZATION="950000000000000000" # 95%
MAX_RESPONSE_TIME="5" # seconds
MIN_BLOCK_CONFIRMATIONS="12" # blocks

# Functions
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

send_alert() {
    local severity=$1
    local message=$2
    
    log_message "[$severity] $message"
    
    if [ ! -z "$ALERT_WEBHOOK" ]; then
        curl -X POST $ALERT_WEBHOOK \
            -H 'Content-Type: application/json' \
            -d "{\"text\":\"🚨 [$severity] $message\"}" \
            2>/dev/null || true
    fi
    
    # Also print to console if running interactively
    if [ -t 1 ]; then
        case $severity in
            "CRITICAL")
                echo -e "${RED}[CRITICAL]${NC} $message"
                ;;
            "WARNING")
                echo -e "${YELLOW}[WARNING]${NC} $message"
                ;;
            "INFO")
                echo -e "${BLUE}[INFO]${NC} $message"
                ;;
        esac
    fi
}

# Contract responsiveness check
check_contract_health() {
    local contract_name=$1
    local contract_address=$2
    
    START_TIME=$(date +%s)
    
    # Try to call a view function with timeout
    RESULT=$(timeout $MAX_RESPONSE_TIME cast call $contract_address \
        "owner()" --rpc-url $RPC_URL 2>/dev/null || echo "TIMEOUT")
    
    END_TIME=$(date +%s)
    RESPONSE_TIME=$((END_TIME - START_TIME))
    
    if [ "$RESULT" = "TIMEOUT" ]; then
        send_alert "CRITICAL" "$contract_name not responding at $contract_address"
        return 1
    elif [ $RESPONSE_TIME -gt $MAX_RESPONSE_TIME ]; then
        send_alert "WARNING" "$contract_name slow response: ${RESPONSE_TIME}s"
        return 1
    fi
    
    return 0
}

# Check if protocol is paused
check_pause_state() {
    IS_PAUSED=$(cast call $MORPHO_CREDIT "paused()" --rpc-url $RPC_URL 2>/dev/null || echo "ERROR")
    
    if [ "$IS_PAUSED" = "ERROR" ]; then
        send_alert "CRITICAL" "Cannot check pause state"
        return 1
    elif [ "$IS_PAUSED" != "0x0000000000000000000000000000000000000000000000000000000000000000" ]; then
        send_alert "CRITICAL" "Protocol is PAUSED!"
        return 1
    fi
    
    return 0
}

# Check market liquidity
check_market_liquidity() {
    # Get a sample market ID (would need actual market ID)
    # For now, checking if markets exist
    MARKET_COUNT=$(cast call $MORPHO_CREDIT "marketsCreated()" --rpc-url $RPC_URL 2>/dev/null || echo "0x0")
    
    if [ "$MARKET_COUNT" = "0x0" ]; then
        send_alert "WARNING" "No markets created yet"
    else
        log_message "Markets created: $(cast to-dec $MARKET_COUNT)"
    fi
}

# Check timelock operations
check_pending_operations() {
    # Check for pending timelock operations that might affect the protocol
    # This would require monitoring timelock events
    log_message "Checking for pending timelock operations..."
    
    # Get latest block
    LATEST_BLOCK=$(cast block-number --rpc-url $RPC_URL)
    
    # Check recent events (simplified - would need proper event monitoring)
    EVENTS=$(cast logs \
        --address $TIMELOCK \
        --from-block $((LATEST_BLOCK - 100)) \
        --to-block $LATEST_BLOCK \
        --rpc-url $RPC_URL 2>/dev/null || echo "")
    
    if [ ! -z "$EVENTS" ]; then
        log_message "Timelock events detected in last 100 blocks"
    fi
}

# Check gas prices
check_gas_prices() {
    GAS_PRICE=$(cast gas-price --rpc-url $RPC_URL 2>/dev/null || echo "0")
    GAS_PRICE_GWEI=$(cast to-unit $GAS_PRICE gwei 2>/dev/null || echo "0")
    
    log_message "Current gas price: ${GAS_PRICE_GWEI} gwei"
    
    # Alert if gas is extremely high
    if [ $(echo "$GAS_PRICE_GWEI > 200" | bc -l) -eq 1 ]; then
        send_alert "WARNING" "High gas price: ${GAS_PRICE_GWEI} gwei"
    fi
}

# Collect metrics
collect_metrics() {
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    BLOCK_NUMBER=$(cast block-number --rpc-url $RPC_URL)
    
    # Get protocol owner
    MORPHO_OWNER=$(cast call $MORPHO_CREDIT "owner()" --rpc-url $RPC_URL 2>/dev/null || echo "0x0")
    
    # Get fee recipient
    FEE_RECIPIENT=$(cast call $MORPHO_CREDIT "feeRecipient()" --rpc-url $RPC_URL 2>/dev/null || echo "0x0")
    
    # Create metrics JSON
    cat > "$METRICS_FILE" <<EOF
{
    "timestamp": "$TIMESTAMP",
    "block": $BLOCK_NUMBER,
    "contracts": {
        "morpho_credit": "$MORPHO_CREDIT",
        "protocol_config": "$PROTOCOL_CONFIG",
        "credit_line": "$CREDIT_LINE",
        "timelock": "$TIMELOCK"
    },
    "state": {
        "paused": $([ "$IS_PAUSED" = "0x0000000000000000000000000000000000000000000000000000000000000000" ] && echo "false" || echo "true"),
        "owner": "$MORPHO_OWNER",
        "fee_recipient": "$FEE_RECIPIENT"
    },
    "network": {
        "gas_price_gwei": "$GAS_PRICE_GWEI"
    }
}
EOF
    
    log_message "Metrics collected at block $BLOCK_NUMBER"
}

# Check for configuration changes
check_config_changes() {
    # Store and compare critical configurations
    CACHE_FILE="/tmp/3jane-config-cache.json"
    
    # Get current configurations
    CURRENT_OWNER=$(cast call $MORPHO_CREDIT "owner()" --rpc-url $RPC_URL)
    CURRENT_FEE_RECIPIENT=$(cast call $MORPHO_CREDIT "feeRecipient()" --rpc-url $RPC_URL)
    
    if [ -f "$CACHE_FILE" ]; then
        PREV_OWNER=$(jq -r '.owner' "$CACHE_FILE" 2>/dev/null || echo "")
        PREV_FEE_RECIPIENT=$(jq -r '.fee_recipient' "$CACHE_FILE" 2>/dev/null || echo "")
        
        if [ "$CURRENT_OWNER" != "$PREV_OWNER" ] && [ ! -z "$PREV_OWNER" ]; then
            send_alert "CRITICAL" "OWNER CHANGED from $PREV_OWNER to $CURRENT_OWNER"
        fi
        
        if [ "$CURRENT_FEE_RECIPIENT" != "$PREV_FEE_RECIPIENT" ] && [ ! -z "$PREV_FEE_RECIPIENT" ]; then
            send_alert "WARNING" "Fee recipient changed from $PREV_FEE_RECIPIENT to $CURRENT_FEE_RECIPIENT"
        fi
    fi
    
    # Update cache
    echo "{\"owner\":\"$CURRENT_OWNER\",\"fee_recipient\":\"$CURRENT_FEE_RECIPIENT\"}" > "$CACHE_FILE"
}

# Main monitoring loop
main() {
    # Create log directory if it doesn't exist
    mkdir -p $(dirname "$LOG_FILE")
    
    log_message "Starting monitoring cycle..."
    
    # Track overall health
    HEALTH_STATUS="HEALTHY"
    
    # Check each contract
    echo "Checking contract health..."
    check_contract_health "MorphoCredit" $MORPHO_CREDIT || HEALTH_STATUS="DEGRADED"
    check_contract_health "ProtocolConfig" $PROTOCOL_CONFIG || HEALTH_STATUS="DEGRADED"
    check_contract_health "CreditLine" $CREDIT_LINE || HEALTH_STATUS="DEGRADED"
    check_contract_health "Timelock" $TIMELOCK || HEALTH_STATUS="DEGRADED"
    
    # Check protocol state
    echo "Checking protocol state..."
    check_pause_state || HEALTH_STATUS="CRITICAL"
    
    # Check market conditions
    echo "Checking market conditions..."
    check_market_liquidity
    
    # Check pending operations
    echo "Checking pending operations..."
    check_pending_operations
    
    # Check gas prices
    echo "Checking network conditions..."
    check_gas_prices
    
    # Check for configuration changes
    echo "Checking for configuration changes..."
    check_config_changes
    
    # Collect metrics
    echo "Collecting metrics..."
    collect_metrics
    
    # Log overall status
    log_message "Monitoring cycle complete. Status: $HEALTH_STATUS"
    
    if [ "$HEALTH_STATUS" = "CRITICAL" ]; then
        send_alert "CRITICAL" "System health check failed - immediate attention required"
        exit 1
    elif [ "$HEALTH_STATUS" = "DEGRADED" ]; then
        send_alert "WARNING" "System health degraded - review required"
        exit 2
    fi
}

# Handle script arguments
case "${1:-}" in
    --once)
        # Run once and exit
        main
        ;;
    --daemon)
        # Run continuously
        while true; do
            main
            sleep 300 # 5 minutes
        done
        ;;
    --help)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Monitor 3Jane Morpho Blue production deployment"
        echo ""
        echo "Options:"
        echo "  --once     Run once and exit"
        echo "  --daemon   Run continuously (every 5 minutes)"
        echo "  --help     Show this help message"
        echo ""
        echo "Environment variables:"
        echo "  MAINNET_RPC_URL    Mainnet RPC endpoint"
        echo "  SLACK_WEBHOOK_URL  Slack webhook for alerts (optional)"
        echo ""
        echo "Example cron entry (every 5 minutes):"
        echo "  */5 * * * * $0 --once"
        exit 0
        ;;
    *)
        # Default: run once
        main
        ;;
esac