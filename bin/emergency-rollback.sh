#!/bin/bash

# 3Jane Morpho Blue - Emergency Rollback Procedures
# USE WITH EXTREME CAUTION - MAINNET ONLY IN EMERGENCIES

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
DEPLOYMENT_DIR="deployments/1"

# Deployed contracts
TIMELOCK="0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2"
MORPHO_CREDIT="0xDe6e08ac208088cc62812Ba30608D852c6B0EcBc"
PROTOCOL_CONFIG="0x6b276A2A7dd8b629adBA8A06AD6573d01C84f34E"

# Functions
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

# Confirmation prompt
confirm_action() {
    local action=$1
    print_warning "You are about to: $action"
    print_warning "This action affects MAINNET and cannot be easily undone!"
    echo -n "Type 'CONFIRM' to proceed: "
    read confirmation
    if [ "$confirmation" != "CONFIRM" ]; then
        print_error "Action cancelled"
        exit 1
    fi
}

# Backup current state
backup_state() {
    print_info "Backing up current state..."
    
    BACKUP_DIR="backups/$(date +%Y%m%d_%H%M%S)"
    mkdir -p $BACKUP_DIR
    
    # Backup contract states
    for contract in $MORPHO_CREDIT $PROTOCOL_CONFIG; do
        CONTRACT_NAME=$(echo $contract | cut -c1-10)
        
        # Get owner
        OWNER=$(cast call $contract "owner()" --rpc-url $RPC_URL 2>/dev/null || echo "N/A")
        
        # Get implementation (for proxies)
        IMPL_SLOT="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
        IMPLEMENTATION=$(cast storage $contract $IMPL_SLOT --rpc-url $RPC_URL 2>/dev/null || echo "N/A")
        
        cat > "$BACKUP_DIR/${CONTRACT_NAME}_state.json" <<EOF
{
    "address": "$contract",
    "owner": "$OWNER",
    "implementation": "$IMPLEMENTATION",
    "block": $(cast block-number --rpc-url $RPC_URL),
    "timestamp": $(date -u +"%Y-%m-%dT%H:%M:%SZ")
}
EOF
    done
    
    print_success "State backed up to $BACKUP_DIR"
}

# Emergency pause protocol
emergency_pause() {
    confirm_action "PAUSE the entire protocol"
    
    print_info "Pausing protocol..."
    
    # Check current owner
    OWNER=$(cast call $MORPHO_CREDIT "owner()" --rpc-url $RPC_URL)
    print_info "Current owner: $OWNER"
    
    # Pause the protocol (requires owner private key or multisig)
    if [ ! -z "$EMERGENCY_PRIVATE_KEY" ]; then
        cast send $MORPHO_CREDIT "pause()" \
            --private-key $EMERGENCY_PRIVATE_KEY \
            --rpc-url $RPC_URL \
            --confirmations 3
        
        print_success "Protocol paused successfully"
    else
        print_error "EMERGENCY_PRIVATE_KEY not set. Manual intervention required."
        print_info "Execute: cast send $MORPHO_CREDIT \"pause()\" --private-key <KEY>"
        exit 1
    fi
}

# Emergency unpause protocol
emergency_unpause() {
    confirm_action "UNPAUSE the protocol"
    
    print_info "Unpausing protocol..."
    
    if [ ! -z "$EMERGENCY_PRIVATE_KEY" ]; then
        cast send $MORPHO_CREDIT "unpause()" \
            --private-key $EMERGENCY_PRIVATE_KEY \
            --rpc-url $RPC_URL \
            --confirmations 3
        
        print_success "Protocol unpaused successfully"
    else
        print_error "EMERGENCY_PRIVATE_KEY not set"
        exit 1
    fi
}

# Schedule implementation rollback via timelock
schedule_rollback() {
    local proxy=$1
    local previous_impl=$2
    
    confirm_action "SCHEDULE rollback of $proxy to implementation $previous_impl"
    
    print_info "Scheduling rollback via Timelock..."
    
    # Prepare upgrade call data
    UPGRADE_DATA=$(cast calldata "upgradeToAndCall(address,bytes)" \
        $previous_impl \
        "0x")
    
    # Get timelock delay
    MIN_DELAY=$(cast call $TIMELOCK "getMinDelay()" --rpc-url $RPC_URL)
    MIN_DELAY_DEC=$(cast to-dec $MIN_DELAY)
    
    print_info "Timelock delay: $MIN_DELAY_DEC seconds"
    
    # Calculate execution time
    EXEC_TIME=$(($(date +%s) + MIN_DELAY_DEC))
    
    # Generate salt
    SALT=$(cast keccak "ROLLBACK_$(date +%s)")
    
    print_info "Upgrade will be executable at: $(date -d @$EXEC_TIME)"
    print_info "Salt: $SALT"
    
    # Schedule the operation (requires proposer role)
    if [ ! -z "$PROPOSER_PRIVATE_KEY" ]; then
        cast send $TIMELOCK \
            "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" \
            $proxy \
            0 \
            $UPGRADE_DATA \
            "0x0000000000000000000000000000000000000000000000000000000000000000" \
            $SALT \
            $MIN_DELAY \
            --private-key $PROPOSER_PRIVATE_KEY \
            --rpc-url $RPC_URL \
            --confirmations 3
        
        print_success "Rollback scheduled. Execute after delay with:"
        print_info "cast send $TIMELOCK \"execute(address,uint256,bytes,bytes32,bytes32)\" $proxy 0 $UPGRADE_DATA 0x0 $SALT"
    else
        print_error "PROPOSER_PRIVATE_KEY not set. Cannot schedule via script."
        print_info "Manual command:"
        echo "cast send $TIMELOCK \\"
        echo "  \"schedule(address,uint256,bytes,bytes32,bytes32,uint256)\" \\"
        echo "  $proxy 0 $UPGRADE_DATA 0x0 $SALT $MIN_DELAY"
    fi
}

# Export critical state
export_state() {
    print_info "Exporting critical state..."
    
    OUTPUT_FILE="state_export_$(date +%Y%m%d_%H%M%S).json"
    
    # Get all critical values
    MORPHO_OWNER=$(cast call $MORPHO_CREDIT "owner()" --rpc-url $RPC_URL)
    MORPHO_FEE_RECIPIENT=$(cast call $MORPHO_CREDIT "feeRecipient()" --rpc-url $RPC_URL)
    CONFIG_OWNER=$(cast call $PROTOCOL_CONFIG "owner()" --rpc-url $RPC_URL)
    
    cat > $OUTPUT_FILE <<EOF
{
    "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "block": $(cast block-number --rpc-url $RPC_URL),
    "morpho_credit": {
        "address": "$MORPHO_CREDIT",
        "owner": "$MORPHO_OWNER",
        "fee_recipient": "$MORPHO_FEE_RECIPIENT",
        "paused": $(cast call $MORPHO_CREDIT "paused()" --rpc-url $RPC_URL || echo "unknown")
    },
    "protocol_config": {
        "address": "$PROTOCOL_CONFIG",
        "owner": "$CONFIG_OWNER"
    },
    "timelock": {
        "address": "$TIMELOCK",
        "min_delay": $(cast call $TIMELOCK "getMinDelay()" --rpc-url $RPC_URL || echo "unknown")
    }
}
EOF
    
    print_success "State exported to $OUTPUT_FILE"
}

# Check system health
check_health() {
    print_info "Checking system health..."
    
    # Check if paused
    IS_PAUSED=$(cast call $MORPHO_CREDIT "paused()" --rpc-url $RPC_URL 2>/dev/null || echo "ERROR")
    
    if [ "$IS_PAUSED" = "ERROR" ]; then
        print_error "Cannot connect to contract"
    elif [ "$IS_PAUSED" = "0x0000000000000000000000000000000000000000000000000000000000000001" ]; then
        print_warning "Protocol is PAUSED"
    else
        print_success "Protocol is active"
    fi
    
    # Check owners
    MORPHO_OWNER=$(cast call $MORPHO_CREDIT "owner()" --rpc-url $RPC_URL 2>/dev/null || echo "ERROR")
    if [ "$MORPHO_OWNER" != "ERROR" ]; then
        print_info "MorphoCredit owner: $MORPHO_OWNER"
    fi
    
    # Check recent blocks
    LATEST_BLOCK=$(cast block-number --rpc-url $RPC_URL)
    print_info "Latest block: $LATEST_BLOCK"
}

# Recovery checklist
show_recovery_checklist() {
    cat <<EOF

${YELLOW}EMERGENCY RECOVERY CHECKLIST${NC}
====================================

1. ${BLUE}IMMEDIATE ACTIONS:${NC}
   [ ] Identify the issue
   [ ] Document the current state (./emergency-rollback.sh export)
   [ ] Backup critical data (./emergency-rollback.sh backup)
   [ ] Alert the team via emergency channels

2. ${BLUE}CONTAINMENT:${NC}
   [ ] Pause the protocol if necessary (./emergency-rollback.sh pause)
   [ ] Stop any ongoing transactions
   [ ] Monitor for exploit continuation

3. ${BLUE}ASSESSMENT:${NC}
   [ ] Determine impact scope
   [ ] Check affected users/funds
   [ ] Review recent transactions
   [ ] Analyze root cause

4. ${BLUE}RECOVERY:${NC}
   [ ] Plan rollback/fix strategy
   [ ] Schedule via timelock if needed
   [ ] Test fix on fork first
   [ ] Execute recovery

5. ${BLUE}POST-INCIDENT:${NC}
   [ ] Verify system stability
   [ ] Unpause when safe
   [ ] Communicate with users
   [ ] Post-mortem analysis

Emergency Contacts:
- Tech Lead: [REDACTED]
- Security Team: [REDACTED]
- Legal: [REDACTED]

EOF
}

# Main menu
main_menu() {
    echo ""
    echo "3Jane Morpho Blue - Emergency Rollback System"
    echo "============================================="
    echo ""
    echo "Current Network: $NETWORK"
    echo "RPC: $RPC_URL"
    echo ""
    echo "Options:"
    echo "  1) Check system health"
    echo "  2) Export current state"
    echo "  3) Backup state"
    echo "  4) Emergency PAUSE protocol"
    echo "  5) Emergency UNPAUSE protocol"
    echo "  6) Schedule implementation rollback"
    echo "  7) Show recovery checklist"
    echo "  8) Exit"
    echo ""
    echo -n "Select option: "
    read option
    
    case $option in
        1)
            check_health
            ;;
        2)
            export_state
            ;;
        3)
            backup_state
            ;;
        4)
            emergency_pause
            ;;
        5)
            emergency_unpause
            ;;
        6)
            echo -n "Enter proxy address: "
            read proxy
            echo -n "Enter previous implementation address: "
            read impl
            schedule_rollback $proxy $impl
            ;;
        7)
            show_recovery_checklist
            ;;
        8)
            exit 0
            ;;
        *)
            print_error "Invalid option"
            ;;
    esac
}

# Handle command line arguments
case "${1:-}" in
    health)
        check_health
        ;;
    export)
        export_state
        ;;
    backup)
        backup_state
        ;;
    pause)
        emergency_pause
        ;;
    unpause)
        emergency_unpause
        ;;
    checklist)
        show_recovery_checklist
        ;;
    --help)
        echo "Usage: $0 [COMMAND]"
        echo ""
        echo "Emergency rollback and recovery procedures for 3Jane Morpho Blue"
        echo ""
        echo "Commands:"
        echo "  health     Check system health"
        echo "  export     Export current state"
        echo "  backup     Backup critical data"
        echo "  pause      Emergency pause protocol"
        echo "  unpause    Emergency unpause protocol"
        echo "  checklist  Show recovery checklist"
        echo "  (none)     Interactive menu"
        echo ""
        echo "Environment variables:"
        echo "  MAINNET_RPC_URL         Mainnet RPC endpoint"
        echo "  EMERGENCY_PRIVATE_KEY   Private key for emergency actions"
        echo "  PROPOSER_PRIVATE_KEY    Private key for timelock proposals"
        echo ""
        print_warning "USE WITH EXTREME CAUTION ON MAINNET"
        exit 0
        ;;
    *)
        # Interactive mode
        while true; do
            main_menu
        done
        ;;
esac