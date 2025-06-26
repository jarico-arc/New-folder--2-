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

# Function to check script permissions
check_script_permissions() {
    local script_path="$0"
    if [ ! -x "$script_path" ]; then
        echo -e "${YELLOW}Making script executable...${NC}"
        chmod +x "$script_path"
        if [ ! -x "$script_path" ]; then
            echo -e "${RED}❌ Failed to make script executable${NC}"
            exit 1
        fi
        echo -e "${GREEN}✅ Script is now executable${NC}"
    fi
}

# Create reports directory
mkdir -p "$REPORT_DIR"

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to install security tools
install_security_tools() {
    echo -e "\n${YELLOW}📦 Installing security tools...${NC}"
    
    check_script_permissions
    
    # Python security tools
    if command_exists pip; then
        echo -e "${BLUE}Installing Python security tools...${NC}"
        pip install --quiet bandit safety pip-audit 2>/dev/null || echo "Warning: Failed to install Python security tools"
    fi
    
    # Node.js security tools (if needed)
    if command_exists npm; then
        echo -e "${BLUE}Installing Node.js security tools...${NC}"
        npm install -g --silent audit-ci snyk 2>/dev/null || echo "Warning: Failed to install Node.js security tools"
    fi
    
    # Trivy for container scanning
    if ! command_exists trivy; then
        echo -e "${BLUE}Installing Trivy...${NC}"
        if command_exists curl; then
            curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin 2>/dev/null || echo "Warning: Failed to install Trivy"
        fi
    fi
    
    # Hadolint for Dockerfile linting
    if ! command_exists hadolint; then
        echo -e "${BLUE}Installing Hadolint...${NC}"
        if command_exists wget; then
            wget -q -O /usr/local/bin/hadolint https://github.com/hadolint/hadolint/releases/download/v2.12.0/hadolint-Linux-x86_64 2>/dev/null || echo "Warning: Failed to install Hadolint"
            chmod +x /usr/local/bin/hadolint 2>/dev/null || true
        fi
    fi
    
    # Checkov for Infrastructure as Code
    if ! command_exists checkov; then
        echo -e "${BLUE}Installing Checkov...${NC}"
        pip install --quiet checkov 2>/dev/null || echo "Warning: Failed to install Checkov"
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
                echo -e "${BLUE}Running Bandit security scan...${NC}"
                bandit -r "$dir" -f json -o "$REPORT_DIR/bandit-report-$TIMESTAMP.json" -ll 2>/dev/null || true
                if bandit -r "$dir" -ll 2>/dev/null; then
                    echo -e "${GREEN}✅ Bandit scan passed${NC}"
                else
                    echo -e "${YELLOW}⚠️ Bandit found security issues${NC}"
                fi
            fi
            
            # Safety dependency check
            if command_exists safety && [ -f "$dir/requirements.txt" ]; then
                echo -e "${BLUE}Running Safety dependency check...${NC}"
                safety check -r "$dir/requirements.txt" --json --output "$REPORT_DIR/safety-report-$TIMESTAMP.json" 2>/dev/null || true
                if safety check -r "$dir/requirements.txt" 2>/dev/null; then
                    echo -e "${GREEN}✅ Safety scan passed${NC}"
                else
                    echo -e "${YELLOW}⚠️ Safety found vulnerable dependencies${NC}"
                fi
            fi
            
            # pip-audit advanced vulnerability check
            if command_exists pip-audit && [ -f "$dir/requirements.txt" ]; then
                echo -e "${BLUE}Running pip-audit vulnerability check...${NC}"
                pip-audit -r "$dir/requirements.txt" --format=json --output="$REPORT_DIR/pip-audit-report-$TIMESTAMP.json" 2>/dev/null || true
                if pip-audit -r "$dir/requirements.txt" --desc 2>/dev/null; then
                    echo -e "${GREEN}✅ pip-audit scan passed${NC}"
                else
                    echo -e "${YELLOW}⚠️ pip-audit found vulnerabilities${NC}"
                fi
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
            local image_safe_name=$(echo "$image" | tr '/:' '-')
            
            trivy image --format json --output "$REPORT_DIR/trivy-$TIMESTAMP-$image_safe_name.json" "$image" 2>/dev/null || true
            
            if trivy image --severity HIGH,CRITICAL "$image" 2>/dev/null; then
                echo -e "${GREEN}✅ No high/critical vulnerabilities in $image${NC}"
            else
                echo -e "${YELLOW}⚠️ High/Critical vulnerabilities found in $image${NC}"
            fi
        done
    else
        echo -e "${YELLOW}Trivy not available - skipping container image scans${NC}"
    fi
}

# Function to scan Kubernetes manifests
scan_kubernetes_manifests() {
    echo -e "\n${YELLOW}☸️ Scanning Kubernetes manifests for security issues...${NC}"
    
    local manifest_dir="$PROJECT_ROOT/manifests"
    
    if [ -d "$manifest_dir" ]; then
        # Checkov security scan
        if command_exists checkov; then
            echo -e "${BLUE}Running Checkov security scan...${NC}"
            checkov -d "$manifest_dir" --framework kubernetes --output json --output-file "$REPORT_DIR/checkov-report-$TIMESTAMP.json" 2>/dev/null || true
            if checkov -d "$manifest_dir" --framework kubernetes 2>/dev/null; then
                echo -e "${GREEN}✅ Checkov scan passed${NC}"
            else
                echo -e "${YELLOW}⚠️ Checkov found security issues${NC}"
            fi
        fi
        
        # Custom security checks
        echo -e "${BLUE}Running custom Kubernetes security checks...${NC}"
        
        # Check for privileged containers
        echo -e "${BLUE}Checking for privileged containers...${NC}"
        if grep -r "privileged.*true" "$manifest_dir" 2>/dev/null; then
            echo -e "${YELLOW}⚠️ Found privileged containers${NC}"
        else
            echo -e "${GREEN}✅ No privileged containers found${NC}"
        fi
        
        # Check for host network usage
        echo -e "${BLUE}Checking for host network usage...${NC}"
        if grep -r "hostNetwork.*true" "$manifest_dir" 2>/dev/null; then
            echo -e "${YELLOW}⚠️ Found host network usage${NC}"
        else
            echo -e "${GREEN}✅ No host network usage found${NC}"
        fi
        
        # Check for host PID usage
        echo -e "${BLUE}Checking for host PID usage...${NC}"
        if grep -r "hostPID.*true" "$manifest_dir" 2>/dev/null; then
            echo -e "${YELLOW}⚠️ Found host PID usage${NC}"
        else
            echo -e "${GREEN}✅ No host PID usage found${NC}"
        fi
        
        # Check for host IPC usage
        echo -e "${BLUE}Checking for host IPC usage...${NC}"
        if grep -r "hostIPC.*true" "$manifest_dir" 2>/dev/null; then
            echo -e "${YELLOW}⚠️ Found host IPC usage${NC}"
        else
            echo -e "${GREEN}✅ No host IPC usage found${NC}"
        fi
        
        # Check for allowPrivilegeEscalation
        echo -e "${BLUE}Checking for privilege escalation...${NC}"
        if grep -r "allowPrivilegeEscalation.*true" "$manifest_dir" 2>/dev/null; then
            echo -e "${YELLOW}⚠️ Found privilege escalation${NC}"
        else
            echo -e "${GREEN}✅ No privilege escalation found${NC}"
        fi
        
        # Check for runAsRoot
        echo -e "${BLUE}Checking for containers running as root...${NC}"
        if grep -r "runAsUser.*0" "$manifest_dir" 2>/dev/null; then
            echo -e "${YELLOW}⚠️ Found containers running as root${NC}"
        else
            echo -e "${GREEN}✅ No containers running as root found${NC}"
        fi
    else
        echo -e "${YELLOW}Manifest directory not found - skipping Kubernetes scans${NC}"
    fi
}

# Function to scan for secrets
scan_secrets() {
    echo -e "\n${YELLOW}🔐 Scanning for exposed secrets...${NC}"
    
    # Check for common secret patterns
    echo -e "${BLUE}Checking for hardcoded secrets...${NC}"
    
    local secret_patterns=(
        "password.*=.*['\"][^'\"]*['\"]"
        "secret.*=.*['\"][^'\"]*['\"]"
        "api[_-]?key.*=.*['\"][^'\"]*['\"]"
        "token.*=.*['\"][^'\"]*['\"]"
        "private[_-]?key.*=.*['\"][^'\"]*['\"]"
        "BEGIN.*PRIVATE.*KEY"
    )
    
    local secrets_found=0
    for pattern in "${secret_patterns[@]}"; do
        echo -e "${BLUE}Searching for pattern: $pattern${NC}"
        if grep -r -E "$pattern" "$PROJECT_ROOT" --exclude-dir=.git --exclude-dir=security-reports --exclude="*.log" 2>/dev/null; then
            echo -e "${YELLOW}⚠️ Potential secrets found - please review${NC}"
            secrets_found=1
        fi
    done
    
    if [ $secrets_found -eq 0 ]; then
        echo -e "${GREEN}✅ No hardcoded secrets found${NC}"
    fi
    
    # Check for high entropy strings (potential secrets)
    echo -e "${BLUE}Checking for high entropy strings...${NC}"
    if find "$PROJECT_ROOT" -name "*.yaml" -o -name "*.yml" -o -name "*.py" -o -name "*.sh" 2>/dev/null | \
        xargs grep -E '[A-Za-z0-9+/]{32,}' 2>/dev/null | \
        grep -v -E '(example|sample|test|placeholder)' >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ Suspicious high entropy strings found${NC}"
    else
        echo -e "${GREEN}✅ No suspicious high entropy strings found${NC}"
    fi
}

# Function to scan shell scripts
scan_shell_scripts() {
    echo -e "\n${YELLOW}📜 Scanning shell scripts for security issues...${NC}"
    
    if command_exists shellcheck; then
        echo -e "${BLUE}Running ShellCheck on scripts...${NC}"
        local script_errors=0
        find "$PROJECT_ROOT" -name "*.sh" -type f 2>/dev/null | while read -r script; do
            if ! shellcheck "$script" 2>/dev/null; then
                echo -e "${YELLOW}⚠️ ShellCheck issues found in $script${NC}"
                script_errors=$((script_errors + 1))
            fi
        done
        
        if [ $script_errors -eq 0 ]; then
            echo -e "${GREEN}✅ All shell scripts pass ShellCheck${NC}"
        fi
    else
        echo -e "${YELLOW}ShellCheck not available - skipping shell script analysis${NC}"
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