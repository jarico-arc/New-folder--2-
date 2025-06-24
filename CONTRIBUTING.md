# Contributing to YugabyteDB Multi-Zone Deployment

Thank you for your interest in contributing to this project! This guide will help you get started with contributing code, documentation, and other improvements.

## 📋 Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Contribution Workflow](#contribution-workflow)
- [Coding Standards](#coding-standards)
- [Testing Guidelines](#testing-guidelines)
- [Security Guidelines](#security-guidelines)
- [Documentation](#documentation)
- [Pull Request Process](#pull-request-process)
- [Issue Reporting](#issue-reporting)

## 🤝 Code of Conduct

This project follows a professional code of conduct. By participating, you agree to:

- Be respectful and inclusive in all interactions
- Focus on constructive feedback and collaboration
- Report any unacceptable behavior to the maintainers
- Follow professional standards in all communications

## 🚀 Getting Started

### Prerequisites

Ensure you have the following tools installed:

```bash
# Required tools
- Git (latest version)
- Docker (20.10+)
- Kubernetes CLI (kubectl 1.28+)
- Helm (3.13+)
- Google Cloud SDK (latest)
- Python 3.11+
- Node.js 18+ (for some tooling)

# Development tools
- pre-commit
- yamllint
- shellcheck
- trivy
```

### Initial Setup

1. **Fork the repository** on GitHub
2. **Clone your fork** locally:
   ```bash
   git clone https://github.com/YOUR_USERNAME/yugabytedb-multizone.git
   cd yugabytedb-multizone
   ```

3. **Add upstream remote**:
   ```bash
   git remote add upstream https://github.com/ORIGINAL_OWNER/yugabytedb-multizone.git
   ```

4. **Install pre-commit hooks**:
   ```bash
   pip install pre-commit
   pre-commit install
   pre-commit install --hook-type commit-msg
   ```

## 💻 Development Setup

### Environment Configuration

1. **Set up your development environment**:
   ```bash
   # Copy environment template
   cp .env.example .env.local
   
   # Edit with your values
   vim .env.local
   ```

2. **Install development dependencies**:
   ```bash
   # Python dependencies
   cd cloud-functions/bi-consumer
   pip install -r requirements.txt
   
   # Install security tools
   pip install bandit safety pip-audit black flake8 pytest
   ```

3. **Validate your setup**:
   ```bash
   # Run the validation script
   make validate
   
   # Run security checks
   bash scripts/security-scan.sh
   ```

## 🔄 Contribution Workflow

### Branch Strategy

We follow a **feature branch workflow**:

1. **Create a feature branch** from `main`:
   ```bash
   git checkout main
   git pull upstream main
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes** following the coding standards
3. **Commit your changes** with conventional commit messages:
   ```bash
   git add .
   git commit -m "feat: add new backup retention policy"
   ```

4. **Push to your fork**:
   ```bash
   git push origin feature/your-feature-name
   ```

5. **Create a Pull Request** on GitHub

### Commit Message Convention

We use [Conventional Commits](https://www.conventionalcommits.org/) for consistent commit messages:

```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

**Types:**
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `style`: Code style changes (formatting, etc.)
- `refactor`: Code refactoring
- `test`: Adding or updating tests
- `chore`: Maintenance tasks
- `security`: Security improvements
- `perf`: Performance improvements

**Examples:**
```bash
feat(backup): add automated daily backups
fix(security): remove hardcoded credentials
docs(readme): update installation instructions
security(rbac): implement least privilege access
```

## 📏 Coding Standards

### Python Code

We follow **PEP 8** with some project-specific guidelines:

```python
# Good practices
import os
from typing import Dict, List, Optional

def process_data(input_data: Dict[str, Any]) -> Optional[List[str]]:
    """
    Process input data and return results.
    
    Args:
        input_data: Dictionary containing input parameters
        
    Returns:
        List of processed results or None if processing fails
        
    Raises:
        ValueError: If input_data is invalid
    """
    if not input_data:
        raise ValueError("Input data cannot be empty")
    
    # Implementation here
    return processed_results
```

**Code Quality Tools:**
- **Black**: Code formatting
- **Flake8**: Linting
- **Bandit**: Security linting
- **MyPy**: Type checking (recommended)

### Shell Scripts

Follow these guidelines for shell scripts:

```bash
#!/bin/bash
# Script description and purpose

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly NC='\033[0m'

# Function with documentation
deploy_component() {
    local component_name="$1"
    local namespace="$2"
    
    echo -e "${GREEN}Deploying ${component_name} to ${namespace}${NC}"
    
    # Implementation here
}

# Main execution
main() {
    # Script logic here
}

# Only run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

### YAML/Kubernetes Manifests

Follow these standards for Kubernetes manifests:

```yaml
# Every manifest should have proper metadata
apiVersion: apps/v1
kind: Deployment
metadata:
  name: component-name
  namespace: target-namespace
  labels:
    app.kubernetes.io/name: component-name
    app.kubernetes.io/component: database
    app.kubernetes.io/part-of: yugabytedb
    app.kubernetes.io/version: "2.25.2"
spec:
  # Always specify resource limits
  containers:
  - name: container-name
    resources:
      requests:
        memory: "256Mi"
        cpu: "100m"
      limits:
        memory: "512Mi"
        cpu: "500m"
    # Security context
    securityContext:
      runAsNonRoot: true
      runAsUser: 1000
      allowPrivilegeEscalation: false
      capabilities:
        drop:
        - ALL
```

## 🧪 Testing Guidelines

### Python Testing

Use **pytest** for Python testing:

```python
import pytest
from unittest.mock import Mock, patch

class TestDataProcessor:
    """Test data processing functionality."""
    
    def test_process_valid_data(self):
        """Test processing with valid input data."""
        input_data = {"key": "value"}
        result = process_data(input_data)
        assert result is not None
        assert len(result) > 0
    
    def test_process_empty_data(self):
        """Test processing with empty input data."""
        with pytest.raises(ValueError):
            process_data({})
    
    @patch('module.external_service')
    def test_process_with_mock(self, mock_service):
        """Test processing with mocked external service."""
        mock_service.return_value = {"status": "success"}
        result = process_data({"test": "data"})
        assert result["status"] == "success"
```

### Kubernetes Testing

Test Kubernetes manifests:

```bash
# Validate YAML syntax
yamllint manifests/

# Validate Kubernetes resources
kubectl --dry-run=client --validate=true apply -f manifests/

# Use kubeval for additional validation
kubeval manifests/**/*.yaml

# Security scanning
checkov -f manifests/ --framework kubernetes
```

### Integration Testing

For integration tests:

```bash
# Test deployment scripts
make deploy-dev  # Deploy development environment

# Test connectivity
bash scripts/test-yugabytedb-connectivity.sh

# Test backup and restore
bash scripts/backup-test.sh
```

## 🔒 Security Guidelines

### Security Requirements

All contributions must follow these security practices:

1. **No hardcoded secrets** in any file
2. **Use environment variables** for configuration
3. **Implement least privilege** for RBAC
4. **Security contexts** for all containers
5. **Network policies** for network segmentation
6. **Resource limits** for all workloads

### Security Scanning

Before submitting code, run security scans:

```bash
# Run comprehensive security scan
bash scripts/security-scan.sh

# Python security
bandit -r cloud-functions/
safety check --json

# Container security
trivy fs .

# Infrastructure security
checkov -d manifests/ --framework kubernetes
```

### Handling Secrets

Use these patterns for secret management:

```python
# Good: Use environment variables
import os
password = os.environ.get('DB_PASSWORD')

# Good: Use Google Secret Manager
from google.cloud import secretmanager
secret = get_secret('db-password')

# Bad: Hardcoded secrets
password = "hardcoded-password"  # Never do this
```

## 📚 Documentation

### Documentation Standards

- **Code comments**: Explain why, not what
- **Docstrings**: For all public functions and classes
- **README updates**: When adding new features
- **CHANGELOG**: For all user-facing changes

### Documentation Format

Use this format for function documentation:

```python
def backup_database(database_name: str, backup_path: str) -> bool:
    """
    Create a backup of the specified database.
    
    This function creates a consistent backup of the YugabyteDB database
    and stores it in the specified location with proper metadata.
    
    Args:
        database_name: Name of the database to backup
        backup_path: Destination path for the backup file
        
    Returns:
        True if backup was successful, False otherwise
        
    Raises:
        BackupError: If backup operation fails
        PermissionError: If insufficient permissions for backup path
        
    Example:
        >>> success = backup_database('production', '/backups/prod.sql')
        >>> print(f"Backup successful: {success}")
        Backup successful: True
    """
```

## 🔄 Pull Request Process

### Before Submitting

1. **Run all tests**:
   ```bash
   make test
   ```

2. **Run security scans**:
   ```bash
   make security
   ```

3. **Update documentation** if needed

4. **Add tests** for new functionality

5. **Update CHANGELOG.md** for user-facing changes

### PR Guidelines

**Title Format:**
```
<type>: <short description>

Examples:
feat: add automated backup scheduling
fix: resolve network policy conflicts
docs: update installation guide
```

**Description Template:**
```markdown
## Description
Brief description of changes made.

## Type of Change
- [ ] Bug fix (non-breaking change)
- [ ] New feature (non-breaking change)
- [ ] Breaking change (fix or feature causing existing functionality to break)
- [ ] Documentation update

## Testing
- [ ] Unit tests pass
- [ ] Integration tests pass
- [ ] Security scans pass
- [ ] Manual testing completed

## Checklist
- [ ] Code follows project style guidelines
- [ ] Self-review completed
- [ ] Documentation updated
- [ ] Tests added for new functionality
- [ ] CHANGELOG updated
```

### Review Process

1. **Automated checks** must pass (CI/CD pipeline)
2. **Code review** by at least one maintainer
3. **Security review** for security-related changes
4. **Documentation review** for user-facing changes

## 🐛 Issue Reporting

### Bug Reports

Use this template for bug reports:

```markdown
**Bug Description**
Clear description of the bug.

**Steps to Reproduce**
1. Step one
2. Step two
3. Step three

**Expected Behavior**
What should happen.

**Actual Behavior**
What actually happens.

**Environment**
- OS: [e.g., Ubuntu 20.04]
- Kubernetes: [e.g., 1.28.0]
- YugabyteDB: [e.g., 2.25.2]

**Logs**
```
Relevant log output
```

**Additional Context**
Any other relevant information.
```

### Feature Requests

Use this template for feature requests:

```markdown
**Feature Description**
Clear description of the proposed feature.

**Use Case**
Why is this feature needed?

**Proposed Solution**
How should this feature work?

**Alternatives Considered**
Other approaches considered.

**Additional Context**
Any other relevant information.
```

## 🏷️ Release Process

### Versioning

We follow [Semantic Versioning](https://semver.org/):

- **MAJOR**: Incompatible API changes
- **MINOR**: Backward-compatible functionality additions
- **PATCH**: Backward-compatible bug fixes

### Release Checklist

1. Update version numbers
2. Update CHANGELOG.md
3. Run full test suite
4. Create release tag
5. Update documentation
6. Deploy to staging for validation
7. Create GitHub release

## 📞 Getting Help

### Communication Channels

- **GitHub Issues**: Bug reports and feature requests
- **GitHub Discussions**: General questions and discussions
- **Email**: security@yourdomain.com (security issues)
- **Email**: devops@yourdomain.com (technical questions)

### Resources

- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [YugabyteDB Documentation](https://docs.yugabyte.com/)
- [Helm Documentation](https://helm.sh/docs/)
- [Google Cloud Documentation](https://cloud.google.com/docs)

---

**Thank you for contributing!** Your efforts help make this project better for everyone. 🙏 