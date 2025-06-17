# YugabyteDB Multi-Environment Setup for Windows
# This PowerShell script helps Windows users deploy YugabyteDB environments

param(
    [Parameter(Mandatory=$false)]
    [string]$Action = "help"
)

function Show-Help {
    Write-Host "🚀 YugabyteDB Multi-Environment Setup for Windows" -ForegroundColor Green
    Write-Host ""
    Write-Host "Usage: .\scripts\setup-windows.ps1 -Action <action>"
    Write-Host ""
    Write-Host "Actions:"
    Write-Host "  help          - Show this help message"
    Write-Host "  check         - Check prerequisites"
    Write-Host "  install       - Install YugabyteDB operator"
    Write-Host "  deploy        - Deploy all environments"
    Write-Host "  rbac          - Setup database RBAC"
    Write-Host "  status        - Check deployment status"
    Write-Host "  scale         - Scale a cluster (interactive)"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  .\scripts\setup-windows.ps1 -Action check"
    Write-Host "  .\scripts\setup-windows.ps1 -Action install"
    Write-Host "  .\scripts\setup-windows.ps1 -Action deploy"
}

function Test-Prerequisites {
    Write-Host "🔍 Checking prerequisites..." -ForegroundColor Yellow
    
    $tools = @{
        "kubectl" = "kubectl version --client"
        "helm" = "helm version"
        "psql" = "psql --version"
        "gcloud" = "gcloud version"
    }
    
    $allGood = $true
    
    foreach ($tool in $tools.Keys) {
        try {
            $result = Invoke-Expression $tools[$tool] 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  ✅ $tool - OK" -ForegroundColor Green
            } else {
                Write-Host "  ❌ $tool - Not found or not working" -ForegroundColor Red
                $allGood = $false
            }
        } catch {
            Write-Host "  ❌ $tool - Not found" -ForegroundColor Red
            $allGood = $false
        }
    }
    
    Write-Host ""
    Write-Host "🔍 Checking Kubernetes cluster access..." -ForegroundColor Yellow
    
    try {
        $clusterInfo = kubectl cluster-info 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ✅ Kubernetes cluster - Connected" -ForegroundColor Green
        } else {
            Write-Host "  ❌ Kubernetes cluster - Cannot connect" -ForegroundColor Red
            $allGood = $false
        }
    } catch {
        Write-Host "  ❌ Kubernetes cluster - Cannot connect" -ForegroundColor Red
        $allGood = $false
    }
    
    if ($allGood) {
        Write-Host ""
        Write-Host "🎉 All prerequisites met! You can proceed with the deployment." -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "⚠️  Some prerequisites are missing. Please install them before proceeding." -ForegroundColor Yellow
    }
    
    return $allGood
}

function Install-Operator {
    Write-Host "🚀 Installing YugabyteDB Operator..." -ForegroundColor Green
    
    # Check if operator namespace exists
    $operatorExists = kubectl get namespace yb-operator 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "⚠️  YugabyteDB operator namespace already exists. Skipping..." -ForegroundColor Yellow
        return
    }
    
    # Create operator namespace
    Write-Host "📦 Creating YugabyteDB operator namespace..." -ForegroundColor Cyan
    kubectl apply -f manifests/operator/namespace.yaml
    
    # Add Helm repository
    Write-Host "📥 Adding YugabyteDB Helm repository..." -ForegroundColor Cyan
    helm repo add yugabytedb https://charts.yugabyte.com
    helm repo update
    
    # Install operator
    Write-Host "⚙️  Installing YugabyteDB operator..." -ForegroundColor Cyan
    helm install yugabyte-operator yugabytedb/yugabyte-k8s-operator --namespace yb-operator --create-namespace --wait --timeout=10m
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✅ YugabyteDB operator installed successfully!" -ForegroundColor Green
    } else {
        Write-Host "❌ Operator installation failed" -ForegroundColor Red
        exit 1
    }
}

function Deploy-Environments {
    Write-Host "🚀 Deploying all YugabyteDB environments..." -ForegroundColor Green
    
    # Check if operator is running
    $operatorRunning = kubectl get pods -n yb-operator | Select-String "Running"
    if (-not $operatorRunning) {
        Write-Host "❌ YugabyteDB operator is not running. Please run install first." -ForegroundColor Red
        exit 1
    }
    
    # Create namespaces
    Write-Host "📦 Creating namespaces..." -ForegroundColor Cyan
    kubectl apply -f manifests/namespaces/environments.yaml
    
    # Deploy environments
    $environments = @("dev", "staging", "prod")
    
    foreach ($env in $environments) {
        Write-Host "🔧 Deploying $env environment..." -ForegroundColor Cyan
        kubectl apply -f "manifests/clusters/codet-$env-yb-cluster.yaml"
    }
    
    Write-Host "⏳ Deployment initiated. Use 'status' action to check progress." -ForegroundColor Yellow
}

function Setup-RBAC {
    Write-Host "🔐 Setting up Database RBAC..." -ForegroundColor Green
    Write-Host "⚠️  This requires port-forwarding and may take several minutes." -ForegroundColor Yellow
    Write-Host ""
    
    $environments = @("dev", "staging", "prod")
    
    foreach ($env in $environments) {
        Write-Host "🔧 Setting up RBAC for $env environment..." -ForegroundColor Cyan
        
        $namespace = "codet-$env-yb"
        $service = "codet-$env-yb-yb-tserver-service"
        
        # Check if cluster is ready
        $pods = kubectl get pods -n $namespace | Select-String "tserver.*Running"
        if (-not $pods) {
            Write-Host "⚠️  $env environment not ready. Skipping..." -ForegroundColor Yellow
            continue
        }
        
        Write-Host "🔌 Setting up port-forward for $env..." -ForegroundColor Cyan
        $portForwardJob = Start-Job -ScriptBlock {
            param($namespace, $service)
            kubectl port-forward -n $namespace "svc/$service" 5433:5433
        } -ArgumentList $namespace, $service
        
        Start-Sleep -Seconds 5
        
        # Create RBAC SQL
        $rbacSQL = @"
-- RBAC Setup for $env environment
CREATE ROLE codet_${env}_admin WITH LOGIN PASSWORD 'admin-${env}-$(Get-Date -Format 'yyyyMMdd')' SUPERUSER;
CREATE ROLE codet_${env}_app WITH LOGIN PASSWORD 'app-${env}-$(Get-Date -Format 'yyyyMMdd')';
CREATE DATABASE codet_${env} OWNER codet_${env}_admin;
\c codet_${env}
CREATE SCHEMA IF NOT EXISTS app_schema AUTHORIZATION codet_${env}_admin;
GRANT USAGE ON SCHEMA app_schema TO codet_${env}_app;
"@
        
        $tempSQL = "$env:TEMP\rbac_$env.sql"
        $rbacSQL | Out-File -FilePath $tempSQL -Encoding UTF8
        
        # Execute SQL
        $env:PGPASSWORD = "yugabyte"
        $result = psql -h localhost -p 5433 -U yugabyte -d yugabyte -f $tempSQL 2>$null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✅ RBAC setup completed for $env" -ForegroundColor Green
        } else {
            Write-Host "❌ RBAC setup failed for $env" -ForegroundColor Red
        }
        
        # Clean up
        Stop-Job $portForwardJob -Force
        Remove-Job $portForwardJob -Force
        Remove-Item $tempSQL -ErrorAction SilentlyContinue
    }
}

function Show-Status {
    Write-Host "📋 YugabyteDB Deployment Status" -ForegroundColor Green
    Write-Host "===============================" -ForegroundColor Green
    Write-Host ""
    
    # Operator status
    Write-Host "🔧 Operator Status:" -ForegroundColor Cyan
    kubectl get pods -n yb-operator
    Write-Host ""
    
    # Environment status
    $environments = @("dev", "staging", "prod")
    
    foreach ($env in $environments) {
        $namespace = "codet-$env-yb"
        Write-Host "🌟 $env Environment ($namespace):" -ForegroundColor Cyan
        
        $cluster = kubectl get ybcluster -n $namespace 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Cluster: ✅ Deployed" -ForegroundColor Green
            kubectl get pods -n $namespace | Select-String "(master|tserver)" | Select-Object -First 5
        } else {
            Write-Host "  Cluster: ❌ Not deployed" -ForegroundColor Red
        }
        Write-Host ""
    }
    
    Write-Host "📍 Access URLs:" -ForegroundColor Cyan
    Write-Host "  Dev:     kubectl port-forward -n codet-dev-yb svc/codet-dev-yb-yb-master-ui 7000:7000"
    Write-Host "  Staging: kubectl port-forward -n codet-staging-yb svc/codet-staging-yb-yb-master-ui 7001:7000"
    Write-Host "  Prod:    kubectl port-forward -n codet-prod-yb svc/codet-prod-yb-yb-master-ui 7002:7000"
}

function Start-ScaleCluster {
    Write-Host "⚖️  Interactive Cluster Scaling" -ForegroundColor Green
    Write-Host ""
    
    $env = Read-Host "Enter environment (dev/staging/prod)"
    if ($env -notin @("dev", "staging", "prod")) {
        Write-Host "❌ Invalid environment" -ForegroundColor Red
        return
    }
    
    $replicas = Read-Host "Enter new tserver replica count"
    if (-not ($replicas -match '^\d+$') -or [int]$replicas -lt 1) {
        Write-Host "❌ Invalid replica count" -ForegroundColor Red
        return
    }
    
    $namespace = "codet-$env-yb"
    $clusterName = "codet-$env-yb"
    
    Write-Host "🚀 Scaling $env to $replicas replicas..." -ForegroundColor Cyan
    
    # Get current manifest and update it
    $manifestPath = "manifests/clusters/codet-$env-yb-cluster.yaml"
    $content = Get-Content $manifestPath
    $updatedContent = $content -replace 'replicas: \d+( # [^`n]*)?', "replicas: $replicas # Scaled to $replicas nodes"
    $updatedContent | Set-Content $manifestPath
    
    # Apply the update
    kubectl apply -f $manifestPath
    
    Write-Host "✅ Scaling operation initiated. Monitor with 'status' action." -ForegroundColor Green
}

# Main script logic
switch ($Action.ToLower()) {
    "help" { Show-Help }
    "check" { Test-Prerequisites }
    "install" { 
        if (Test-Prerequisites) {
            Install-Operator
        } else {
            Write-Host "❌ Prerequisites not met. Run 'check' action first." -ForegroundColor Red
        }
    }
    "deploy" { Deploy-Environments }
    "rbac" { Setup-RBAC }
    "status" { Show-Status }
    "scale" { Start-ScaleCluster }
    default { 
        Write-Host "❌ Unknown action: $Action" -ForegroundColor Red
        Show-Help
    }
}

Write-Host ""
Write-Host "💡 For detailed instructions, see DEPLOYMENT-GUIDE.md" -ForegroundColor Blue 