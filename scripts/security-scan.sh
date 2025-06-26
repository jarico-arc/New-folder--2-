
#!/bin/bash

# YugabyteDB Security Scanning Script
# Comprehensive security assessment for the entire project

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
REPORT_DIR="$PROJECT_ROOT/security-reports"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

echo -e "${GREEN}🔒 YugabyteDB Security Scanning Suite${NC}"
echo -e "${BLUE}Project: $PROJECT_ROOT${NC}"
echo -e "${BLUE}Timestamp: $TIMESTAMP${NC}"

# Create reports directory
mkdir -p "$REPORT_DIR"

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to install security tools
install_security_tools() {
    echo -e "\n${YELLOW}📦 Installing security tools...${NC}"
    
    # Python security tools
    if command_exists pip; then
        pip install --quiet bandit safety pip-audit || echo "Warning: Failed to install Python security tools"
    fi
    
    # Node.js security tools (if needed)
    if command_exists npm; then
        npm install -g --silent audit-ci snyk || echo "Warning: Failed to install Node.js security tools"
    fi
    
    # Trivy for container scanning
    if ! command_exists trivy; then
        echo "Installing Trivy..."
        curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
    fi
    
    # Hadolint for Dockerfile linting
    if ! command_exists hadolint; then
        echo "Installing Hadolint..."
        wget -O /usr/local/bin/hadolint https://github.com/hadolint/hadolint/releases/download/v2.12.0/hadolint-Linux-x86_64
        chmod +x /usr/local/bin/hadolint
    fi
    
    # Checkov for Infrastructure as Code
    if ! command_exists checkov; then
        pip install --quiet checkov || echo "Warning: Failed to install Checkov"
    fi
}

# Function to scan Python code for security issues
scan_python_security() {
    echo -e "\n${YELLOW}🐍 Scanning Python code for security vulnerabilities...${NC}"
    
    local python_dirs=("$PROJECT_ROOT/cloud-functions")
    
    for dir in "${python_dirs[@]}"; do
        if [ -d "$dir" ]; then
            echo -e "${BLUE}Scanning directory: $dir${NC}"
            
            # Bandit security linting
            if command_exists bandit; then
                echo "Running Bandit security scan..."
                bandit -r "$dir" -f json -o "$REPORT_DIR/bandit-report-$TIMESTAMP.json" -ll || true
                bandit -r "$dir" -ll || echo "Bandit found security issues"
            fi
            
            # Safety dependency check
            if command_exists safety && [ -f "$dir/requirements.txt" ]; then
                echo "Running Safety dependency check..."
                safety check -r "$dir/requirements.txt" --json --output "$REPORT_DIR/safety-report-$TIMESTAMP.json" || true
                safety check -r "$dir/requirements.txt" || echo "Safety found vulnerable dependencies"
            fi
            
            # pip-audit advanced vulnerability check
            if command_exists pip-audit && [ -f "$dir/requirements.txt" ]; then
                echo "Running pip-audit vulnerability check..."
                pip-audit -r "$dir/requirements.txt" --format=json --output="$REPORT_DIR/pip-audit-report-$TIMESTAMP.json" || true
                pip-audit -r "$dir/requirements.txt" --desc || echo "pip-audit found vulnerabilities"
            fi
        fi
    done
}

# Function to scan container images
scan_container_images() {
    echo -e "\n${YELLOW}🐳 Scanning container images for vulnerabilities...${NC}"
    
    # Scan base images mentioned in the project
    local images=(
        "google/cloud-sdk:alpine"
        "postgres:15"
        "yugabytedb/yugabyte:2.25.2"
    )
    
    if command_exists trivy; then
        for image in "${images[@]}"; do
            echo -e "${BLUE}Scanning image: $image${NC}"
            trivy image --format json --output "$REPORT_DIR/trivy-$TIMESTAMP-$(echo "$image" | tr '/:' '-').json" "$image" || true
            trivy image --severity HIGH,CRITICAL "$image" || echo "High/Critical vulnerabilities found in $image"
        done
    fi
}

# Function to scan Kubernetes manifests
scan_kubernetes_manifests() {
    echo -e "\n${YELLOW}☸️ Scanning Kubernetes manifests for security issues...${NC}"
    
    local manifest_dir="$PROJECT_ROOT/manifests"
    
    if [ -d "$manifest_dir" ]; then
        # Checkov security scan
        if command_exists checkov; then
            echo "Running Checkov security scan..."
            checkov -d "$manifest_dir" --framework kubernetes --output json --output-file "$REPORT_DIR/checkov-report-$TIMESTAMP.json" || true
            checkov -d "$manifest_dir" --framework kubernetes || echo "Checkov found security issues"
        fi
        
        # Custom security checks
        echo "Running custom Kubernetes security checks..."
        
        # Check for privileged containers
        echo -e "${BLUE}Checking for privileged containers...${NC}"
        grep -r "privileged.*true" "$manifest_dir" || echo "✅ No privileged containers found"
        
        # Check for host network usage
        echo -e "${BLUE}Checking for host network usage...${NC}"
        grep -r "hostNetwork.*true" "$manifest_dir" || echo "✅ No host network usage found"
        
        # Check for host PID usage
        echo -e "${BLUE}Checking for host PID usage...${NC}"
        grep -r "hostPID.*true" "$manifest_dir" || echo "✅ No host PID usage found"
        
        # Check for host IPC usage
        echo -e "${BLUE}Checking for host IPC usage...${NC}"
        grep -r "hostIPC.*true" "$manifest_dir" || echo "✅ No host IPC usage found"
        
        # Check for allowPrivilegeEscalation
        echo -e "${BLUE}Checking for privilege escalation...${NC}"
        grep -r "allowPrivilegeEscalation.*true" "$manifest_dir" || echo "✅ No privilege escalation found"
        
        # Check for runAsRoot
        echo -e "${BLUE}Checking for containers running as root...${NC}"
        if grep -r "runAsUser.*0" "$manifest_dir"; then
            echo "⚠️ Found containers running as root"
        else
            echo "✅ No containers running as root found"
        fi
    fi
}

# Function to scan for secrets
scan_secrets() {
    echo -e "\n${YELLOW}🔐 Scanning for exposed secrets...${NC}"
    
    # Check for common secret patterns
    echo "Checking for hardcoded secrets..."
    
    local secret_patterns=(
        "password.*=.*['\"][^'\"]*['\"]"
        "secret.*=.*['\"][^'\"]*['\"]"
        "api[_-]?key.*=.*['\"][^'\"]*['\"]"
        "token.*=.*['\"][^'\"]*['\"]"
        "private[_-]?key.*=.*['\"][^'\"]*['\"]"
        "BEGIN.*PRIVATE.*KEY"
    )
    
    for pattern in "${secret_patterns[@]}"; do
        echo -e "${BLUE}Searching for pattern: $pattern${NC}"
        if grep -r -E "$pattern" "$PROJECT_ROOT" --exclude-dir=.git --exclude-dir=security-reports --exclude="*.log"; then
            echo "⚠️ Potential secrets found - please review"
        else
            echo "✅ No hardcoded secrets found for this pattern"
        fi
    done
    
    # Check for high entropy strings (potential secrets)
    echo -e "${BLUE}Checking for high entropy strings...${NC}"
    find "$PROJECT_ROOT" -name "*.yaml" -o -name "*.yml" -o -name "*.py" -o -name "*.sh" | \
        xargs grep -E '[A-Za-z0-9+/]{32,}' | \
        grep -v -E '(example|sample|test|placeholder)' || echo "✅ No suspicious high entropy strings found"
}

# Function to scan shell scripts
scan_shell_scripts() {
    echo -e "\n${YELLOW}🐚 Scanning shell scripts for security issues...${NC}"
    
    local script_dir="$PROJECT_ROOT/scripts"
    
    if [ -d "$script_dir" ]; then
        # ShellCheck security scan
        if command_exists shellcheck; then
            echo "Running ShellCheck security scan..."
            find "$script_dir" -name "*.sh" -exec shellcheck {} \; || echo "ShellCheck found issues"
        fi
        
        # Custom security checks for shell scripts
        echo "Running custom shell script security checks..."
        
        # Check for curl without verification
        echo -e "${BLUE}Checking for insecure curl usage...${NC}"
        grep -r "curl.*-k\|curl.*--insecure" "$script_dir" || echo "✅ No insecure curl usage found"
        
        # Check for wget without verification
        echo -e "${BLUE}Checking for insecure wget usage...${NC}"
        grep -r "wget.*--no-check-certificate" "$script_dir" || echo "✅ No insecure wget usage found"
        
        # Check for sudo without full path
        echo -e "${BLUE}Checking for unsafe sudo usage...${NC}"
        grep -r "sudo [^/]" "$script_dir" || echo "✅ No unsafe sudo usage found"
        
        # Check for eval usage
        echo -e "${BLUE}Checking for eval usage...${NC}"
        grep -r "eval " "$script_dir" || echo "✅ No eval usage found"
    fi
}

# Function to generate security report
generate_security_report() {
    echo -e "\n${YELLOW}📋 Generating security report...${NC}"
    
    local report_file="$REPORT_DIR/security-summary-$TIMESTAMP.md"
    
    cat > "$report_file" <<EOF
# Security Scan Report

**Date**: $(date)
**Project**: YugabyteDB Multi-Zone Deployment
**Scan ID**: $TIMESTAMP

## Summary

This report contains the results of comprehensive security scanning performed on the YugabyteDB project.

## Scans Performed

- ✅ Python Security (Bandit, Safety, pip-audit)
- ✅ Container Image Vulnerabilities (Trivy)
- ✅ Kubernetes Manifest Security (Checkov)
- ✅ Secret Detection
- ✅ Shell Script Security (ShellCheck)

## Report Files

The following detailed reports were generated:

EOF
    
    # List all generated report files
    ls -la "$REPORT_DIR"/*"$TIMESTAMP"* >> "$report_file" 2>/dev/null || true
    
    cat >> "$report_file" <<EOF

## Recommendations

1. **Review all HIGH and CRITICAL vulnerabilities** in container images
2. **Address any hardcoded secrets** found in the codebase
3. **Fix Kubernetes security misconfigurations** identified by Checkov
4. **Update vulnerable dependencies** identified by Safety and pip-audit
5. **Implement security policies** for any violations found

## Next Steps

1. Review individual report files for detailed findings
2. Create issues for each security finding that needs attention
3. Implement fixes and re-run security scans
4. Consider integrating these scans into CI/CD pipeline

## Security Contacts

- Security Team: security@yourdomain.com
- DevOps Team: devops@yourdomain.com

---

**Note**: This report is generated automatically. Please review all findings and consult with the security team for any questions.
EOF
    
    echo -e "${GREEN}✅ Security report generated: $report_file${NC}"
}

# Function to check compliance
check_compliance() {
    echo -e "\n${YELLOW}📜 Checking security compliance...${NC}"
    
    # Check for required security files
    local required_files=(
        "SECURITY.md"
        ".gitignore"
        ".github/workflows/ci.yml"
        "manifests/policies/network-policies.yaml"
        "manifests/policies/resource-quotas.yaml"
    )
    
    echo -e "${BLUE}Checking for required security files...${NC}"
    for file in "${required_files[@]}"; do
        if [ -f "$PROJECT_ROOT/$file" ]; then
            echo "✅ $file exists"
        else
            echo "❌ $file missing"
        fi
    done
    
    # Check for security practices in CI/CD
    echo -e "${BLUE}Checking CI/CD security practices...${NC}"
    if [ -f "$PROJECT_ROOT/.github/workflows/ci.yml" ]; then
        if grep -q "bandit\|safety\|trivy\|checkov" "$PROJECT_ROOT/.github/workflows/ci.yml"; then
            echo "✅ Security scanning integrated in CI/CD"
        else
            echo "⚠️ Consider adding security scanning to CI/CD pipeline"
        fi
    fi
}

# Main execution
main() {
    echo -e "\n${GREEN}Starting comprehensive security scan...${NC}"
    
    # Install required tools
    install_security_tools
    
    # Run all security scans
    scan_python_security
    scan_container_images
    scan_kubernetes_manifests
    scan_secrets
    scan_shell_scripts
    check_compliance
    
    # Generate final report
    generate_security_report
    
    echo -e "\n${GREEN}🎉 Security scanning completed!${NC}"
    echo -e "${BLUE}Reports saved to: $REPORT_DIR${NC}"
    echo -e "${YELLOW}Please review all findings and take appropriate action.${NC}"
}

# Handle script arguments
case "${1:-all}" in
    "python")
        scan_python_security
        ;;
    "containers")
        scan_container_images
        ;;
    "kubernetes")
        scan_kubernetes_manifests
        ;;
    "secrets")
        scan_secrets
        ;;
    "shell")
        scan_shell_scripts
        ;;
    "compliance")
        check_compliance
        ;;
    "all")
        main
        ;;
    *)
        echo "Usage: $0 [python|containers|kubernetes|secrets|shell|compliance|all]"
        exit 1
        ;;
esac 