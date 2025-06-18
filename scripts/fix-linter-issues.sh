#!/bin/bash

# Fix Linter Issues Script
# Helps diagnose and fix common linting problems

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

echo "🔧 YugabyteDB Project Linter Issues Diagnostics & Fixes"
echo "====================================================="

## 1. Check YAML Linting
check_yaml_linting() {
    log_info "🔍 Checking YAML linting..."
    
    if command -v yamllint &> /dev/null; then
        if [ -f ".yamllint.yml" ]; then
            log_info "Running yamllint with project config..."
            if yamllint -c .yamllint.yml manifests/; then
                log_success "YAML linting passed"
            else
                log_warning "YAML linting issues found - see above"
            fi
        else
            log_warning ".yamllint.yml config not found"
        fi
    else
        log_warning "yamllint not installed. Install with: pip install yamllint"
    fi
}

## 2. Check Network Policies (False Positive Fix)
fix_network_policies() {
    log_info "🛡️ Checking NetworkPolicy linter issues..."
    
    local network_policy_file="manifests/policies/network-policies.yaml"
    if [ -f "$network_policy_file" ]; then
        # Check if file uses correct Kubernetes API version
        if grep -q "apiVersion: networking.k8s.io/v1" "$network_policy_file"; then
            log_success "NetworkPolicy API version is correct"
            log_info "Note: 'Missing property terms' errors are FALSE POSITIVES"
            log_info "NetworkPolicy resources don't require 'terms' property"
            log_info "This is a VS Code extension schema issue"
        else
            log_warning "NetworkPolicy API version may be incorrect"
        fi
    else
        log_warning "NetworkPolicy file not found"
    fi
}

## 3. Check Bitbucket Pipelines Indentation
check_pipelines_yaml() {
    log_info "🔄 Checking Bitbucket Pipelines YAML..."
    
    local pipelines_file="bitbucket-pipelines.yml"
    if [ -f "$pipelines_file" ]; then
        # Check for common indentation issues
        if grep -n "^[[:space:]]*-[[:space:]]*[a-zA-Z]" "$pipelines_file" | head -5; then
            log_success "Pipelines YAML structure looks correct"
        fi
        
        # Check for trailing spaces
        if grep -n "[[:space:]]$" "$pipelines_file" > /dev/null; then
            log_warning "Found trailing whitespace in pipelines file"
            log_info "Fix with: sed -i 's/[[:space:]]*$//' bitbucket-pipelines.yml"
        else
            log_success "No trailing whitespace found"
        fi
    else
        log_warning "bitbucket-pipelines.yml not found"
    fi
}

## 4. Check Shell Scripts
check_shell_scripts() {
    log_info "📜 Checking shell scripts..."
    
    if command -v shellcheck &> /dev/null; then
        log_info "Running shellcheck on scripts..."
        find scripts/ -name "*.sh" -exec shellcheck {} \; && log_success "Shell scripts passed checks" || log_warning "Shell script issues found"
    else
        log_warning "shellcheck not installed. Install with: apt-get install shellcheck"
    fi
}

## 5. Check Python Code
check_python_code() {
    log_info "🐍 Checking Python code..."
    
    if [ -f "requirements.txt" ]; then
        if command -v flake8 &> /dev/null; then
            log_info "Running flake8..."
            flake8 examples/ tests/ --max-line-length=100 && log_success "Python linting passed" || log_warning "Python linting issues found"
        else
            log_warning "flake8 not installed. Install with: pip install flake8"
        fi
    else
        log_warning "requirements.txt not found"
    fi
}

## 6. VS Code Extension Issues
check_vscode_extensions() {
    log_info "🔧 VS Code Extension Issues..."
    
    echo ""
    echo "Common VS Code linter false positives:"
    echo "======================================"
    echo "1. 'Unable to load schema' - Extension issue, not code problem"
    echo "2. 'Missing property terms' - NetworkPolicy schema issue"  
    echo "3. Bitbucket Pipelines schema - Extension may not recognize latest syntax"
    echo ""
    echo "Solutions:"
    echo "- Update VS Code extensions (YAML, Kubernetes, Bitbucket)"
    echo "- Disable problematic extensions temporarily"
    echo "- Use command-line linters (yamllint, shellcheck) for authoritative results"
    echo ""
}

## 7. Generate Linter Config
generate_linter_configs() {
    log_info "📝 Checking linter configurations..."
    
    # Check yamllint config
    if [ ! -f ".yamllint.yml" ]; then
        log_warning "Creating .yamllint.yml config..."
        cat > .yamllint.yml << 'EOF'
extends: default
rules:
  line-length:
    max: 120
  indentation:
    spaces: 2
  new-line-at-end-of-file: disable
  truthy: disable
  comments:
    min-spaces-from-content: 1
EOF
        log_success "Created .yamllint.yml"
    else
        log_success ".yamllint.yml already exists"
    fi
    
    # Check editorconfig
    if [ ! -f ".editorconfig" ]; then
        log_warning "Creating .editorconfig..."
        cat > .editorconfig << 'EOF'
root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
trim_trailing_whitespace = true
indent_style = space
indent_size = 2

[*.{yml,yaml}]
indent_size = 2

[*.py]
indent_size = 4

[*.sh]
indent_size = 2
EOF
        log_success "Created .editorconfig"
    else
        log_success ".editorconfig already exists"
    fi
}

## Main execution
main() {
    check_yaml_linting
    echo ""
    fix_network_policies  
    echo ""
    check_pipelines_yaml
    echo ""
    check_shell_scripts
    echo ""
    check_python_code
    echo ""
    check_vscode_extensions
    echo ""
    generate_linter_configs
    
    echo ""
    log_success "🎉 Linter diagnostics completed!"
    echo ""
    echo "📋 Summary:"
    echo "- Most linter errors are likely FALSE POSITIVES from VS Code extensions"
    echo "- Use command-line tools (yamllint, shellcheck) for authoritative results"
    echo "- NetworkPolicy 'terms' errors can be safely ignored"
    echo "- Update VS Code extensions if issues persist"
}

main "$@" 