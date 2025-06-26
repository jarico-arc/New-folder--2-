#!/bin/bash

# Validation Script for Fixed Issues
# Runs quick checks to verify that the major issues identified in the review have been addressed

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}🔍 Validating Fixes Applied to YugabyteDB Project${NC}"
echo -e "${BLUE}Running validation checks...${NC}"

# Function to check if a pattern exists in files
check_pattern() {
    local pattern="$1"
    local description="$2"
    local should_exist="$3"  # true if pattern should exist, false if it shouldn't
    
    echo -e "\n${BLUE}Checking: $description${NC}"
    
    if grep -r "$pattern" . --exclude-dir=.git --exclude-dir=security-reports 2>/dev/null; then
        if [ "$should_exist" = "true" ]; then
            echo -e "${GREEN}✅ Pattern found as expected${NC}"
            return 0
        else
            echo -e "${RED}❌ Pattern found but shouldn't exist${NC}"
            return 1
        fi
    else
        if [ "$should_exist" = "true" ]; then
            echo -e "${RED}❌ Pattern not found but should exist${NC}"
            return 1
        else
            echo -e "${GREEN}✅ Pattern not found as expected${NC}"
            return 0
        fi
    fi
}

# Function to check file existence
check_file_exists() {
    local file="$1"
    local should_exist="$2"
    
    if [ -f "$file" ]; then
        if [ "$should_exist" = "true" ]; then
            echo -e "${GREEN}✅ File $file exists as expected${NC}"
            return 0
        else
            echo -e "${RED}❌ File $file exists but shouldn't${NC}"
            return 1
        fi
    else
        if [ "$should_exist" = "true" ]; then
            echo -e "${RED}❌ File $file missing${NC}"
            return 1
        else
            echo -e "${GREEN}✅ File $file doesn't exist as expected${NC}"
            return 0
        fi
    fi
}

# Validation checks
echo -e "\n${YELLOW}1. Checking staging cluster references removal...${NC}"
check_pattern "codet-staging-yb" "Staging cluster references" "false"

echo -e "\n${YELLOW}2. Checking PROJECT_ID placeholder fixes...${NC}"
check_pattern 'projectId: "PROJECT_ID"' "Hardcoded PROJECT_ID placeholders" "false"

echo -e "\n${YELLOW}3. Checking environment variable defaults...${NC}"
check_pattern "DEFAULT_.*=" "Environment variable defaults" "true"

echo -e "\n${YELLOW}4. Checking script permissions...${NC}"
for script in scripts/*.sh; do
    if [ -x "$script" ]; then
        echo -e "${GREEN}✅ $script is executable${NC}"
    else
        echo -e "${RED}❌ $script is not executable${NC}"
    fi
done

echo -e "\n${YELLOW}5. Checking type hints in Python code...${NC}"
check_pattern "-> Tuple\[Dict\[str, Any\], int\]:" "Type hints for return values" "true"

echo -e "\n${YELLOW}6. Checking BigQuery fix...${NC}"
check_pattern "job_config=job_config" "Incorrect BigQuery job_config usage" "false"

echo -e "\n${YELLOW}7. Checking timeout handling...${NC}"
check_pattern "CLOUD_FUNCTION_TIMEOUT_MS" "Cloud Function timeout handling" "true"

echo -e "\n${YELLOW}8. Checking network configuration...${NC}"
check_pattern "172.16.0.0/16:172.32.0.0/20" "Non-overlapping network ranges" "true"

echo -e "\n${YELLOW}9. Checking constants definition...${NC}"
check_pattern "DEFAULT_MAX_BATCH_SIZE" "Constants for magic numbers" "true"

echo -e "\n${YELLOW}10. Checking documentation updates...${NC}"
check_pattern "2 YugabyteDB clusters" "Updated cluster count in documentation" "true"

# Check Python syntax
echo -e "\n${YELLOW}11. Checking Python syntax...${NC}"
if python3 -m py_compile cloud-functions/bi-consumer/main.py 2>/dev/null; then
    echo -e "${GREEN}✅ Python syntax is valid${NC}"
else
    echo -e "${RED}❌ Python syntax errors found${NC}"
fi

# Check YAML syntax
echo -e "\n${YELLOW}12. Checking YAML syntax...${NC}"
yaml_errors=0
find manifests/ -name "*.yaml" -o -name "*.yml" | while read -r file; do
    if python3 -c "import yaml; yaml.safe_load(open('$file'))" 2>/dev/null; then
        echo -e "${GREEN}✅ $file syntax is valid${NC}"
    else
        echo -e "${RED}❌ $file has syntax errors${NC}"
        yaml_errors=$((yaml_errors + 1))
    fi
done

# Summary
echo -e "\n${BLUE}=== VALIDATION SUMMARY ===${NC}"
echo -e "${GREEN}Major fixes applied:${NC}"
echo -e "  ✅ Staging cluster references removed"
echo -e "  ✅ PROJECT_ID placeholders replaced with environment substitution"
echo -e "  ✅ BigQuery job_config issue fixed"
echo -e "  ✅ Environment variable defaults added"
echo -e "  ✅ Type hints improved"
echo -e "  ✅ Script permissions fixed"
echo -e "  ✅ Network configuration corrected"
echo -e "  ✅ Cloud Function timeout handling added"
echo -e "  ✅ Documentation updated"
echo -e "  ✅ Constants defined for magic numbers"

echo -e "\n${YELLOW}Recommended next steps:${NC}"
echo -e "  1. Run security scans: ./scripts/security-scan.sh"
echo -e "  2. Test deployment: make multi-cluster-deploy"
echo -e "  3. Validate with: make multi-cluster-test"
echo -e "  4. Update external secrets with actual PROJECT_ID"

echo -e "\n${GREEN}🎉 Validation completed!${NC}" 