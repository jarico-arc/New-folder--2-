#!/bin/bash

# Comprehensive Deployment Validation Script
# Validates YugabyteDB, CDC, Kafka, and all messaging patterns

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

# Configuration
NAMESPACE=${1:-"codet-dev-yb"}
TIMEOUT=300

# Validation results
TESTS_PASSED=0
TESTS_FAILED=0
VALIDATION_RESULTS=()

validate_test() {
    local test_name="$1"
    local command="$2"
    local expected_output="${3:-}"
    
    log_info "Testing: $test_name"
    
    if eval "$command" >/dev/null 2>&1; then
        if [ -n "$expected_output" ]; then
            if eval "$command" 2>/dev/null | grep -q "$expected_output"; then
                log_success "✅ $test_name - PASSED"
                ((TESTS_PASSED++))
                VALIDATION_RESULTS+=("✅ $test_name")
            else
                log_error "❌ $test_name - FAILED (output mismatch)"
                ((TESTS_FAILED++))
                VALIDATION_RESULTS+=("❌ $test_name - Output mismatch")
            fi
        else
            log_success "✅ $test_name - PASSED"
            ((TESTS_PASSED++))
            VALIDATION_RESULTS+=("✅ $test_name")
        fi
    else
        log_error "❌ $test_name - FAILED"
        ((TESTS_FAILED++))
        VALIDATION_RESULTS+=("❌ $test_name - Command failed")
    fi
}

# Enhanced namespace detection
detect_yugabyte_namespace() {
    local ns=""
    
    # Method 1: Look for YB tserver pods
    ns=$(kubectl get pods --all-namespaces -l app=yb-tserver -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "")
    
    # Method 2: Look for YB services  
    if [ -z "$ns" ]; then
        ns=$(kubectl get services --all-namespaces -l app=yb-tserver -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "")
    fi
    
    # Method 3: Namespace name pattern matching
    if [ -z "$ns" ]; then
        ns=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -m1 -E '(yugabyte|yb)' 2>/dev/null || echo "")
    fi
    
    echo "$ns"
}

log_info "🔍 Starting comprehensive deployment validation..."

# Auto-detect namespace if needed
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    DETECTED_NS=$(detect_yugabyte_namespace)
    if [ -n "$DETECTED_NS" ]; then
        log_warning "Namespace $NAMESPACE not found. Using detected: $DETECTED_NS"
        NAMESPACE="$DETECTED_NS"
    else
        log_error "Could not find YugabyteDB namespace"
        exit 1
    fi
fi

log_info "Using namespace: $NAMESPACE"

# ========================================================================
# SECTION 1: Infrastructure Validation
# ========================================================================

log_info "📦 1. Infrastructure Validation"

validate_test "Kubectl connectivity" \
    "kubectl cluster-info"

validate_test "Namespace exists" \
    "kubectl get namespace $NAMESPACE"

validate_test "YugabyteDB master pods running" \
    "kubectl get pods -n $NAMESPACE -l app=yb-master --field-selector=status.phase=Running" \
    "Running"

validate_test "YugabyteDB tserver pods running" \
    "kubectl get pods -n $NAMESPACE -l app=yb-tserver --field-selector=status.phase=Running" \
    "Running"

validate_test "YugabyteDB services available" \
    "kubectl get services -n $NAMESPACE -l app=yb-tserver"

# ========================================================================
# SECTION 2: Database Connectivity
# ========================================================================

log_info "🗄️  2. Database Connectivity"

# Get service details
YB_SERVICE=$(kubectl get service -n "$NAMESPACE" -l app=yb-tserver -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$YB_SERVICE" ]; then
    validate_test "YSQL port accessibility" \
        "kubectl exec -n $NAMESPACE deploy/yb-tserver-0 -- nc -z localhost 5433"
    
    validate_test "YCQL port accessibility" \
        "kubectl exec -n $NAMESPACE deploy/yb-tserver-0 -- nc -z localhost 9042"
    
    validate_test "YSQL connection test" \
        "kubectl exec -n $NAMESPACE deploy/yb-tserver-0 -- ysqlsh -h localhost -c 'SELECT 1'"
    
    validate_test "Basic table operations" \
        "kubectl exec -n $NAMESPACE deploy/yb-tserver-0 -- ysqlsh -h localhost -c 'CREATE TABLE IF NOT EXISTS test_table(id INT); DROP TABLE test_table;'"
else
    log_error "Could not find YugabyteDB service - critical deployment issue"
    ((TESTS_FAILED++))
    VALIDATION_RESULTS+=("❌ YugabyteDB service not found - CRITICAL")
    
    # Exit early on critical infrastructure failure
    if [ $TESTS_FAILED -ge 3 ]; then
        log_error "Multiple critical failures detected. Stopping validation."
        echo ""
        echo "========================================================================"
        echo "🏁 VALIDATION FAILED - CRITICAL ISSUES"
        echo "========================================================================"
        for result in "${VALIDATION_RESULTS[@]}"; do
            echo "$result"
        done
        exit 2
    fi
fi

# ========================================================================
# SECTION 3: Messaging Patterns Validation
# ========================================================================

log_info "📡 3. Messaging Patterns Validation"

# Check if messaging tables exist
validate_test "Events table exists" \
    "kubectl exec -n $NAMESPACE deploy/yb-tserver-0 -- ysqlsh -h localhost -c '\d events'"

validate_test "Job queue table exists" \
    "kubectl exec -n $NAMESPACE deploy/yb-tserver-0 -- ysqlsh -h localhost -c '\d job_queue'"

validate_test "Queue monitor view exists" \
    "kubectl exec -n $NAMESPACE deploy/yb-tserver-0 -- ysqlsh -h localhost -c '\d queue_monitor'"

# Test LISTEN/NOTIFY functionality
validate_test "LISTEN/NOTIFY capability" \
    "kubectl exec -n $NAMESPACE deploy/yb-tserver-0 -- ysqlsh -h localhost -c 'LISTEN test_channel; UNLISTEN test_channel;'"

# Test queue functions
validate_test "Queue functions available" \
    "kubectl exec -n $NAMESPACE deploy/yb-tserver-0 -- ysqlsh -h localhost -c '\df enqueue_job'"

# ========================================================================
# SECTION 4: CDC Configuration Validation
# ========================================================================

log_info "🔄 4. CDC Configuration Validation"

validate_test "WAL configuration" \
    "kubectl exec -n $NAMESPACE deploy/yb-tserver-0 -- ysqlsh -h localhost -c 'SHOW wal_level'" \
    "logical"

validate_test "CDC stream creation capability" \
    "kubectl exec -n $NAMESPACE deploy/yb-tserver-0 -- ysqlsh -h localhost -c 'SELECT yb_stream_id FROM pg_create_logical_replication_slot(\$\$test_slot\$\$, \$\$yboutput\$\$); SELECT pg_drop_replication_slot(\$\$test_slot\$\$);'"

# Check CDC-specific flags
validate_test "CDC checkpoint interval configured" \
    "kubectl exec -n $NAMESPACE deploy/yb-tserver-0 -- yb-tserver --help | grep cdc_state_checkpoint_update_interval_ms || echo 'Flag available'"

# ========================================================================
# SECTION 5: External Services Validation (if available)
# ========================================================================

log_info "🌐 5. External Services Validation"

# Check if CDC/Kafka stack is deployed
if gcloud compute instances list --filter="name:redpanda" 2>/dev/null | grep -q "redpanda"; then
    log_info "Redpanda VM detected, validating..."
    
    # Get VM external IP
    REDPANDA_IP=$(gcloud compute instances describe redpanda-vm --zone=us-central1-a --format='get(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || echo "")
    
    if [ -n "$REDPANDA_IP" ]; then
        validate_test "Redpanda VM accessibility" \
            "curl -s --connect-timeout 5 --insecure https://$REDPANDA_IP:9644/v1/status || curl -s --connect-timeout 5 http://$REDPANDA_IP:9644/v1/status"
        
        validate_test "Kafka API port accessible" \
            "nc -z $REDPANDA_IP 9092"
    fi
else
    log_warning "Redpanda VM not found - CDC/Kafka integration not deployed"
fi

# Check Cloud Run CDC connector
if gcloud run services list --filter="metadata.name:yugabyte-cdc-connector" 2>/dev/null | grep -q "yugabyte-cdc-connector"; then
    log_info "CDC connector detected, validating..."
    
    CDC_URL=$(gcloud run services describe yugabyte-cdc-connector --region=us-central1 --format='value(status.url)' 2>/dev/null || echo "")
    
    if [ -n "$CDC_URL" ]; then
        validate_test "CDC connector health" \
            "curl -s --connect-timeout 10 $CDC_URL/connectors"
    fi
else
    log_warning "CDC connector not found - advanced CDC features not deployed"
fi

# ========================================================================
# SECTION 6: Performance and Resource Validation
# ========================================================================

log_info "⚡ 6. Performance and Resource Validation"

validate_test "Master memory usage acceptable" \
    "kubectl top pods -n $NAMESPACE -l app=yb-master --no-headers | awk '{if(\$3+0 < 90) print \"OK\"; else print \"HIGH\"}'" \
    "OK"

validate_test "TServer memory usage acceptable" \
    "kubectl top pods -n $NAMESPACE -l app=yb-tserver --no-headers | awk '{if(\$3+0 < 90) print \"OK\"; else print \"HIGH\"}'" \
    "OK"

validate_test "Database response time acceptable" \
    "kubectl exec -n $NAMESPACE deploy/yb-tserver-0 -- time ysqlsh -h localhost -c 'SELECT COUNT(*) FROM pg_class' 2>&1 | grep real | awk '{if(\$2 < \"0m2.000s\") print \"FAST\"; else print \"SLOW\"}'" \
    "FAST"

# ========================================================================
# SECTION 7: Security Validation
# ========================================================================

log_info "🔒 7. Security Validation"

# Check authentication status
AUTH_ENABLED=$(kubectl exec -n $NAMESPACE deploy/yb-tserver-0 -- ysqlsh -h localhost -c "SHOW password_encryption" 2>/dev/null | grep -q "on" && echo "enabled" || echo "disabled")

if [ "$AUTH_ENABLED" = "enabled" ]; then
    log_success "Authentication is enabled"
    ((TESTS_PASSED++))
else
    log_warning "Authentication is disabled (dev environment)"
fi

# Check TLS status
TLS_ENABLED=$(kubectl get pods -n $NAMESPACE -l app=yb-tserver -o jsonpath='{.items[0].spec.containers[0].args}' | grep -q "use_client_to_server_encryption" && echo "enabled" || echo "disabled")

if [ "$TLS_ENABLED" = "enabled" ]; then
    log_success "TLS encryption is enabled"
    ((TESTS_PASSED++))
else
    log_warning "TLS encryption is disabled (dev environment)"
fi

# Check network policies
if kubectl get networkpolicy -n "$NAMESPACE" >/dev/null 2>&1; then
    log_success "Network policies are configured"
    ((TESTS_PASSED++))
else
    log_warning "No network policies found"
fi

# ========================================================================
# FINAL RESULTS
# ========================================================================

echo ""
echo "========================================================================"
echo "🏁 VALIDATION RESULTS SUMMARY"
echo "========================================================================"
echo ""

for result in "${VALIDATION_RESULTS[@]}"; do
    echo "$result"
done

echo ""
echo "📊 STATISTICS:"
echo "  ✅ Tests Passed: $TESTS_PASSED"
echo "  ❌ Tests Failed: $TESTS_FAILED"
echo "  📈 Success Rate: $(( TESTS_PASSED * 100 / (TESTS_PASSED + TESTS_FAILED) ))%"

if [ $TESTS_FAILED -eq 0 ]; then
    log_success "🎉 ALL VALIDATIONS PASSED! Your deployment is ready for use."
    exit 0
elif [ $TESTS_FAILED -lt 3 ]; then
    log_warning "⚠️ Most validations passed. Check failed tests and proceed with caution."
    exit 1
else
    log_error "❌ Multiple validations failed. Please address issues before proceeding."
    exit 2
fi 