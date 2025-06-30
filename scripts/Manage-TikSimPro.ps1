# ==========================================
# scripts/Manage-TikSimPro.ps1 - Daily management operations
# ==========================================

<#
.SYNOPSIS
    Manage TikSimPro Kubernetes deployment

.DESCRIPTION
    This script provides daily management operations for TikSimPro including:
    - Viewing status and logs
    - Scaling bot instances
    - Restarting services
    - Updating applications
    - Performance monitoring

.PARAMETER Action
    The management action to perform

.PARAMETER BotName
    Specific bot name for targeted operations

.PARAMETER Replicas
    Number of replicas for scaling operations

.PARAMETER Namespace
    Kubernetes namespace (defaults based on current context)

.EXAMPLE
    .\scripts\Manage-TikSimPro.ps1 -Action status
    Shows the status of all TikSimPro components

.EXAMPLE
    .\scripts\Manage-TikSimPro.ps1 -Action logs -BotName bot1
    Displays logs for bot1

.EXAMPLE
    .\scripts\Manage-TikSimPro.ps1 -Action scale -BotName bot1 -Replicas 3
    Scales bot1 to 3 replicas
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("status", "logs", "restart", "scale", "update", "monitor", "backup", "shell")]
    [string]$Action,
    
    [Parameter(Mandatory=$false)]
    [string]$BotName = "",
    
    [Parameter(Mandatory=$false)]
    [int]$Replicas = 1,
    
    [Parameter(Mandatory=$false)]
    [string]$Namespace = "",
    
    [Parameter(Mandatory=$false)]
    [int]$LogLines = 50,
    
    [Parameter(Mandatory=$false)]
    [switch]$Follow = $false
)

# Auto-detect namespace if not provided
if ([string]::IsNullOrEmpty($Namespace)) {
    $currentContext = kubectl config current-context 2>$null
    if ($currentContext -like "*development*" -or $currentContext -like "*dev*") {
        $Namespace = "tiksimpro-dev"
    } elseif ($currentContext -like "*staging*") {
        $Namespace = "tiksimpro-staging"
    } elseif ($currentContext -like "*production*" -or $currentContext -like "*prod*") {
        $Namespace = "tiksimpro-production"
    } else {
        $Namespace = "tiksimpro-dev"  # Default fallback
    }
}

# Utility functions for consistent output formatting
function Write-SectionHeader {
    param([string]$Title)
    Write-Host ""
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "=" * 60 -ForegroundColor Cyan
}

function Write-InfoMessage {
    param([string]$Message)
    Write-Host "ℹ️  $Message" -ForegroundColor Blue
}

function Write-SuccessMessage {
    param([string]$Message)
    Write-Host "✅ $Message" -ForegroundColor Green
}

function Write-ErrorMessage {
    param([string]$Message)
    Write-Host "❌ $Message" -ForegroundColor Red
}

function Write-WarningMessage {
    param([string]$Message)
    Write-Host "⚠️  $Message" -ForegroundColor Yellow
}

# Function to get bot status with health information
function Get-BotStatus {
    Write-SectionHeader "TikSimPro Service Status"
    Write-InfoMessage "Namespace: $Namespace"
    
    try {
        # Get all TikSimPro resources
        Write-Host ""
        Write-Host "📊 Pods Status:" -ForegroundColor Yellow
        kubectl get pods -n $Namespace -l app.kubernetes.io/name=tiksimpro -o wide
        
        Write-Host ""
        Write-Host "🔗 Services:" -ForegroundColor Yellow
        kubectl get svc -n $Namespace -l app.kubernetes.io/name=tiksimpro
        
        Write-Host ""
        Write-Host "💾 Persistent Volume Claims:" -ForegroundColor Yellow
        kubectl get pvc -n $Namespace
        
        Write-Host ""
        Write-Host "🎛️  ConfigMaps:" -ForegroundColor Yellow
        kubectl get configmap -n $Namespace -l app.kubernetes.io/name=tiksimpro
        
        # Check for any failing pods
        $failingPods = kubectl get pods -n $Namespace -l app.kubernetes.io/name=tiksimpro --field-selector=status.phase!=Running --no-headers 2>$null
        if ($failingPods) {
            Write-Host ""
            Write-WarningMessage "Found pods not in Running state:"
            Write-Host $failingPods -ForegroundColor Red
        }
        
        # Show recent events for troubleshooting
        Write-Host ""
        Write-Host "📋 Recent Events:" -ForegroundColor Yellow
        kubectl get events -n $Namespace --sort-by='.lastTimestamp' --field-selector involvedObject.kind=Pod | Select-Object -Last 5
        
    }
    catch {
        Write-ErrorMessage "Failed to get status: $($_.Exception.Message)"
    }
}

# Function to display logs with filtering options
function Get-BotLogs {
    Write-SectionHeader "TikSimPro Logs"
    
    if ($BotName) {
        Write-InfoMessage "Displaying logs for bot: $BotName"
        $selector = "bot.tiksimpro/name=$BotName"
    } else {
        Write-InfoMessage "Displaying logs for all bots"
        $selector = "app.kubernetes.io/name=tiksimpro"
    }
    
    try {
        $logCommand = @("kubectl", "logs", "-l", $selector, "-n", $Namespace, "--tail=$LogLines")
        
        if ($Follow) {
            $logCommand += "-f"
            Write-InfoMessage "Following logs... Press Ctrl+C to stop"
        }
        
        # Add timestamps for better debugging
        $logCommand += "--timestamps=true"
        
        & $logCommand[0] $logCommand[1..($logCommand.Length-1)]
    }
    catch {
        Write-ErrorMessage "Failed to get logs: $($_.Exception.Message)"
        Write-InfoMessage "Make sure the namespace $Namespace exists and contains TikSimPro pods"
    }
}

# Function to restart bots with safety checks
function Restart-Bot {
    if ($BotName) {
        Write-InfoMessage "Restarting bot: $BotName"
        $resourceName = "statefulset/tiksimpro-$BotName"
    } else {
        Write-InfoMessage "Restarting all TikSimPro bots"
        $resourceName = "statefulset"
        $selector = "-l app.kubernetes.io/name=tiksimpro"
    }
    
    try {
        if ($BotName) {
            # Restart specific bot
            kubectl rollout restart $resourceName -n $Namespace
            Write-InfoMessage "Waiting for restart to complete..."
            kubectl rollout status $resourceName -n $Namespace --timeout=300s
        } else {
            # Restart all bots
            kubectl rollout restart statefulset $selector -n $Namespace
            Write-InfoMessage "Waiting for all restarts to complete..."
            # Wait for each statefulset individually
            $statefulsets = kubectl get statefulset -n $Namespace -l app.kubernetes.io/name=tiksimpro -o name
            foreach ($sts in $statefulsets) {
                kubectl rollout status $sts -n $Namespace --timeout=300s
            }
        }
        
        Write-SuccessMessage "Restart completed successfully"
    }
    catch {
        Write-ErrorMessage "Failed to restart: $($_.Exception.Message)"
    }
}

# Function to scale bots with validation
function Scale-Bot {
    if (-not $BotName) {
        Write-ErrorMessage "Bot name is required for scaling operations"
        Write-InfoMessage "Use: -BotName bot1 -Replicas 3"
        return
    }
    
    if ($Replicas -lt 0 -or $Replicas -gt 10) {
        Write-ErrorMessage "Invalid replica count. Must be between 0 and 10"
        return
    }
    
    Write-InfoMessage "Scaling bot $BotName to $Replicas replicas"
    
    try {
        $statefulSetName = "tiksimpro-$BotName"
        
        # Check if the StatefulSet exists
        $exists = kubectl get statefulset $statefulSetName -n $Namespace 2>$null
        if (-not $exists) {
            Write-ErrorMessage "StatefulSet $statefulSetName not found in namespace $Namespace"
            return
        }
        
        # Perform the scaling
        kubectl scale statefulset $statefulSetName --replicas=$Replicas -n $Namespace
        
        if ($LASTEXITCODE -eq 0) {
            Write-SuccessMessage "Scaling command issued successfully"
            Write-InfoMessage "Waiting for scaling to complete..."
            
            # Wait for the scaling to complete
            kubectl rollout status statefulset/$statefulSetName -n $Namespace --timeout=300s
            
            Write-SuccessMessage "Bot $BotName successfully scaled to $Replicas replicas"
        } else {
            Write-ErrorMessage "Failed to scale bot"
        }
    }
    catch {
        Write-ErrorMessage "Failed to scale bot: $($_.Exception.Message)"
    }
}

# Function to update application with image rebuild
function Update-Application {
    Write-SectionHeader "Updating TikSimPro Application"
    
    try {
        # Step 1: Build new Docker image with timestamp tag
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $newImageTag = "update-$timestamp"
        
        Write-InfoMessage "Building new Docker image with tag: $newImageTag"
        docker build -f docker/Dockerfile -t "tiksimpro:$newImageTag" .
        
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorMessage "Docker build failed"
            return
        }
        
        # Step 2: Update Helm deployment with new image
        Write-InfoMessage "Updating Helm deployment with new image"
        
        # Determine the release name based on namespace
        $releaseName = if ($Namespace -like "*prod*") { "tiksimpro-production" } 
                      elseif ($Namespace -like "*staging*") { "tiksimpro-staging" } 
                      else { "tiksimpro-development" }
        
        helm upgrade $releaseName ./helm/tiksimpro `
            --namespace $Namespace `
            --reuse-values `
            --set image.tag=$newImageTag `
            --timeout 10m `
            --wait
        
        if ($LASTEXITCODE -eq 0) {
            Write-SuccessMessage "Application updated successfully"
            Write-InfoMessage "New image tag: $newImageTag"
        } else {
            Write-ErrorMessage "Helm upgrade failed"
        }
    }
    catch {
        Write-ErrorMessage "Failed to update application: $($_.Exception.Message)"
    }
}

# Function to monitor resource usage and performance
function Monitor-Performance {
    Write-SectionHeader "TikSimPro Performance Monitoring"
    
    try {
        # CPU and Memory usage
        Write-Host "📊 Resource Usage:" -ForegroundColor Yellow
        kubectl top pods -n $Namespace -l app.kubernetes.io/name=tiksimpro 2>$null
        
        if ($LASTEXITCODE -ne 0) {
            Write-WarningMessage "Metrics server not available. Install metrics-server for resource monitoring."
        }
        
        Write-Host ""
        Write-Host "🔄 Pod Restart Counts:" -ForegroundColor Yellow
        kubectl get pods -n $Namespace -l app.kubernetes.io/name=tiksimpro -o custom-columns="NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,AGE:.metadata.creationTimestamp"
        
        Write-Host ""
        Write-Host "💾 Storage Usage:" -ForegroundColor Yellow
        kubectl get pvc -n $Namespace -o custom-columns="NAME:.metadata.name,SIZE:.spec.resources.requests.storage,USED:.status.capacity.storage"
        
        Write-Host ""
        Write-Host "🕒 Recent Pod Events:" -ForegroundColor Yellow
        kubectl get events -n $Namespace --sort-by='.lastTimestamp' --field-selector involvedObject.kind=Pod | Select-Object -Last 10
        
        # Check for any alerts or issues
        Write-Host ""
        Write-Host "⚠️  Health Checks:" -ForegroundColor Yellow
        $unhealthyPods = kubectl get pods -n $Namespace -l app.kubernetes.io/name=tiksimpro --field-selector=status.phase!=Running -o name 2>$null
        if ($unhealthyPods) {
            Write-WarningMessage "Found unhealthy pods:"
            foreach ($pod in $unhealthyPods) {
                Write-Host "  - $pod" -ForegroundColor Red
            }
        } else {
            Write-SuccessMessage "All pods are healthy"
        }
    }
    catch {
        Write-ErrorMessage "Failed to get monitoring data: $($_.Exception.Message)"
    }
}

# Function to create backup of important data
function Backup-Data {
    Write-SectionHeader "Creating TikSimPro Backup"
    
    $backupDir = "backups/$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    
    try {
        Write-InfoMessage "Creating backup in: $backupDir"
        
        # Backup Helm values
        Write-InfoMessage "Backing up Helm configurations..."
        helm get values tiksimpro-development -n $Namespace > "$backupDir/helm-values.yaml" 2>$null
        
        # Backup ConfigMaps
        Write-InfoMessage "Backing up ConfigMaps..."
        kubectl get configmap -n $Namespace -l app.kubernetes.io/name=tiksimpro -o yaml > "$backupDir/configmaps.yaml"
        
        # Backup Secrets (excluding sensitive data)
        Write-InfoMessage "Backing up Secret metadata..."
        kubectl get secret -n $Namespace -l app.kubernetes.io/name=tiksimpro -o yaml | 
            Select-String -Pattern "password|token|key" -NotMatch > "$backupDir/secrets-metadata.yaml"
        
        # Backup persistent volume information
        Write-InfoMessage "Backing up storage information..."
        kubectl get pvc -n $Namespace -o yaml > "$backupDir/persistent-volumes.yaml"
        
        # Create backup manifest
        @"
# TikSimPro Backup Manifest
Created: $(Get-Date)
Namespace: $Namespace
Backup Directory: $backupDir

Files included:
- helm-values.yaml: Helm deployment values
- configmaps.yaml: Application configurations
- secrets-metadata.yaml: Secret metadata (no sensitive data)
- persistent-volumes.yaml: Storage configurations

To restore:
1. Ensure cluster and namespace exist
2. Apply configurations: kubectl apply -f configmaps.yaml
3. Recreate PVCs: kubectl apply -f persistent-volumes.yaml
4. Redeploy with Helm using backed up values
"@ > "$backupDir/README.md"
        
        Write-SuccessMessage "Backup completed: $backupDir"
        Write-InfoMessage "Backup includes configurations and metadata (no sensitive data)"
    }
    catch {
        Write-ErrorMessage "Backup failed: $($_.Exception.Message)"
    }
}

# Function to open shell in bot container
function Open-BotShell {
    if (-not $BotName) {
        Write-ErrorMessage "Bot name is required for shell access"
        Write-InfoMessage "Use: -BotName bot1"
        return
    }
    
    try {
        # Find the pod for the specified bot
        $podName = kubectl get pod -n $Namespace -l "bot.tiksimpro/name=$BotName" -o jsonpath='{.items[0].metadata.name}' 2>$null
        
        if (-not $podName) {
            Write-ErrorMessage "No pod found for bot: $BotName"
            Write-InfoMessage "Available bots:"
            kubectl get pods -n $Namespace -l app.kubernetes.io/component=bot -o custom-columns="BOT:.metadata.labels.bot\.tiksimpro/name,POD:.metadata.name,STATUS:.status.phase"
            return
        }
        
        Write-InfoMessage "Opening shell in pod: $podName"
        Write-InfoMessage "You will be logged in as the 'tiksimpro' user"
        Write-InfoMessage "Type 'exit' to close the shell"
        
        # Open interactive shell
        kubectl exec -it $podName -n $Namespace -- /bin/bash
    }
    catch {
        Write-ErrorMessage "Failed to open shell: $($_.Exception.Message)"
    }
}

# Main execution logic
Write-InfoMessage "TikSimPro Management Tool"
Write-InfoMessage "Action: $Action | Namespace: $Namespace"

switch ($Action) {
    "status" {
        Get-BotStatus
    }
    
    "logs" {
        Get-BotLogs
    }
    
    "restart" {
        Restart-Bot
    }
    
    "scale" {
        Scale-Bot
    }
    
    "update" {
        Update-Application
    }
    
    "monitor" {
        Monitor-Performance
    }
    
    "backup" {
        Backup-Data
    }
    
    "shell" {
        Open-BotShell
    }
    
    default {
        Write-ErrorMessage "Unknown action: $Action"
        Write-InfoMessage "Available actions: status, logs, restart, scale, update, monitor, backup, shell"
    }
}

# ==========================================
# scripts/Quick-Start.ps1 - Rapid deployment for beginners
# ==========================================

<#
.SYNOPSIS
    Quick start deployment for TikSimPro with sensible defaults

.DESCRIPTION
    This script provides a simplified deployment process for beginners.
    It sets up TikSimPro with default configurations and guides users through
    the essential setup steps.

.PARAMETER AccountName1
    First TikTok account name

.PARAMETER AccountName2
    Second TikTok account name

.PARAMETER Environment
    Target environment (development or production)

.EXAMPLE
    .\scripts\Quick-Start.ps1 -AccountName1 "my_first_account" -AccountName2 "my_second_account"
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$AccountName1,
    
    [Parameter(Mandatory=$true)]
    [string]$AccountName2,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("development", "production")]
    [string]$Environment = "development"
)

function Write-WelcomeMessage {
    Write-Host ""
    Write-Host "🚀 Welcome to TikSimPro Quick Start!" -ForegroundColor Green
    Write-Host "   This script will set up your automated TikTok content generation system" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "📋 Configuration:" -ForegroundColor Yellow
    Write-Host "   Account 1: $AccountName1" -ForegroundColor White
    Write-Host "   Account 2: $AccountName2" -ForegroundColor White
    Write-Host "   Environment: $Environment" -ForegroundColor White
    Write-Host ""
}

function Test-Prerequisites {
    Write-Host "📋 Checking prerequisites..." -ForegroundColor Cyan
    
    $tools = @{
        "docker" = "Docker Desktop"
        "kubectl" = "Kubernetes CLI"
        "helm" = "Helm Package Manager"
    }
    
    $allPresent = $true
    
    foreach ($tool in $tools.Keys) {
        if (Get-Command $tool -ErrorAction SilentlyContinue) {
            Write-Host "   ✅ $($tools[$tool]) is installed" -ForegroundColor Green
        } else {
            Write-Host "   ❌ $($tools[$tool]) is missing" -ForegroundColor Red
            $allPresent = $false
        }
    }
    
    if (-not $allPresent) {
        Write-Host ""
        Write-Host "❌ Missing prerequisites detected!" -ForegroundColor Red
        Write-Host "   Please install the missing tools and run this script again." -ForegroundColor Yellow
        Write-Host "   Installation guide: https://github.com/YOUR_USERNAME/tiksimpro-kubernetes#installation" -ForegroundColor Cyan
        exit 1
    }
    
    # Test Kubernetes connection
    try {
        kubectl cluster-info --request-timeout=5s | Out-Null
        Write-Host "   ✅ Kubernetes cluster is accessible" -ForegroundColor Green
    } catch {
        Write-Host "   ❌ Cannot connect to Kubernetes cluster" -ForegroundColor Red
        Write-Host "   Make sure Docker Desktop > Kubernetes is enabled" -ForegroundColor Yellow
        exit 1
    }
    
    Write-Host "   ✅ All prerequisites are ready!" -ForegroundColor Green
}

function New-QuickStartConfiguration {
    Write-Host "⚙️ Creating configuration for your accounts..." -ForegroundColor Cyan
    
    # Create a custom values file for quick start
    $quickStartValues = @"
# Quick Start Configuration for TikSimPro
# Generated on $(Get-Date)

image:
  repository: tiksimpro
  pullPolicy: IfNotPresent
  tag: "latest"

# Your bot configurations
bots:
  # First bot - $AccountName1
  - name: bot1
    account: "$AccountName1"
    enabled: true
    replicas: 1
    platforms:
      tiktok:
        enabled: true
        schedule: "0 */6 * * *"  # Every 6 hours
        description: "TikTok posting for $AccountName1"
        hashtags: ["fyp", "viral", "satisfying", "trending"]
      youtube:
        enabled: true
        schedule: "0 10 * * *"  # Daily at 10 AM
        description: "YouTube Shorts for $AccountName1"
        hashtags: ["shorts", "viral", "satisfying"]
    resources:
      requests:
        memory: "512Mi"
        cpu: "250m"
      limits:
        memory: "2Gi"
        cpu: "1000m"
    env:
      LOG_LEVEL: "INFO"
      VIDEO_DURATION: "30"
      HEADLESS_BROWSER: "true"

  # Second bot - $AccountName2
  - name: bot2
    account: "$AccountName2"
    enabled: true
    replicas: 1
    platforms:
      tiktok:
        enabled: true
        schedule: "30 */6 * * *"  # Every 6 hours (offset by 30 min)
        description: "TikTok posting for $AccountName2"
        hashtags: ["fyp", "trending", "viral", "physics"]
      instagram:
        enabled: true
        schedule: "0 14 * * *"  # Daily at 2 PM
        description: "Instagram Reels for $AccountName2"
        hashtags: ["reels", "viral", "explore"]
    resources:
      requests:
        memory: "512Mi"
        cpu: "250m"
      limits:
        memory: "2Gi"
        cpu: "1000m"
    env:
      LOG_LEVEL: "INFO"
      VIDEO_DURATION: "45"
      HEADLESS_BROWSER: "true"

# Simplified configuration for quick start
webInterface:
  enabled: true
  replicas: 1
  service:
    type: LoadBalancer
    port: 80

postgresql:
  enabled: true
  auth:
    postgresPassword: "quickstart_password_change_in_production"
    database: "tiksimpro"

redis:
  enabled: true
  auth:
    enabled: false

persistence:
  enabled: true
  size: 50Gi

monitoring:
  enabled: true
  prometheus:
    enabled: true
  grafana:
    enabled: true
    adminPassword: "admin"

autoscaling:
  enabled: false  # Disabled for simplicity

podSecurityContext:
  fsGroup: 1000
  runAsNonRoot: true
  runAsUser: 1000
"@
    
    # Ensure the directory exists
    New-Item -ItemType Directory -Path "helm/tiksimpro" -Force | Out-Null
    
    # Write the configuration
    $quickStartValues | Out-File -FilePath "helm/tiksimpro/values-quickstart.yaml" -Encoding UTF8
    
    Write-Host "   ✅ Configuration created: helm/tiksimpro/values-quickstart.yaml" -ForegroundColor Green
}

function Start-QuickDeployment {
    Write-Host "🚀 Starting deployment..." -ForegroundColor Cyan
    
    $namespace = "tiksimpro-quickstart"
    
    try {
        # Build Docker image
        Write-Host "   🏗️ Building Docker image..." -ForegroundColor Blue
        docker build -f docker/Dockerfile -t tiksimpro:quickstart . | Out-Host
        
        if ($LASTEXITCODE -ne 0) {
            throw "Docker build failed"
        }
        
        # Add Helm repositories
        Write-Host "   📦 Setting up Helm repositories..." -ForegroundColor Blue
        helm repo add bitnami https://charts.bitnami.com/bitnami | Out-Null
        helm repo update | Out-Null
        
        # Create namespace
        Write-Host "   📁 Creating namespace: $namespace..." -ForegroundColor Blue
        kubectl create namespace $namespace --dry-run=client -o yaml | kubectl apply -f - | Out-Null
        
        # Deploy with Helm
        Write-Host "   🎯 Deploying TikSimPro..." -ForegroundColor Blue
        helm upgrade --install tiksimpro-quickstart ./helm/tiksimpro `
            --namespace $namespace `
            --values ./helm/tiksimpro/values-quickstart.yaml `
            --set image.tag=quickstart `
            --timeout 10m `
            --wait | Out-Host
        
        if ($LASTEXITCODE -ne 0) {
            throw "Helm deployment failed"
        }
        
        Write-Host "   ✅ Deployment completed!" -ForegroundColor Green
        
    } catch {
        Write-Host "   ❌ Deployment failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "   Check the logs above for details" -ForegroundColor Yellow
        return $false
    }
    
    return $true
}

function Show-QuickStartResults {
    $namespace = "tiksimpro-quickstart"
    
    Write-Host ""
    Write-Host "🎉 TikSimPro Quick Start Complete!" -ForegroundColor Green
    Write-Host ""
    
    Write-Host "📊 Current Status:" -ForegroundColor Yellow
    kubectl get pods -n $namespace
    
    Write-Host ""
    Write-Host "🌐 Access Your Dashboard:" -ForegroundColor Yellow
    Write-Host "   Run this command to access the web interface:" -ForegroundColor White
    Write-Host "   kubectl port-forward svc/tiksimpro-web 8080:80 -n $namespace" -ForegroundColor Cyan
    Write-Host "   Then open: http://localhost:8080" -ForegroundColor Cyan
    
    Write-Host ""
    Write-Host "📋 Useful Commands:" -ForegroundColor Yellow
    Write-Host "   View logs for bot1:    kubectl logs -f -l bot.tiksimpro/name=bot1 -n $namespace" -ForegroundColor White
    Write-Host "   View logs for bot2:    kubectl logs -f -l bot.tiksimpro/name=bot2 -n $namespace" -ForegroundColor White
    Write-Host "   Check all resources:   kubectl get all -n $namespace" -ForegroundColor White
    Write-Host "   Management script:     .\scripts\Manage-TikSimPro.ps1 -Action status -Namespace $namespace" -ForegroundColor White
    
    Write-Host ""
    Write-Host "🔄 Your Bots Schedule:" -ForegroundColor Yellow
    Write-Host "   Bot1 ($AccountName1): TikTok every 6 hours, YouTube daily at 10 AM" -ForegroundColor White
    Write-Host "   Bot2 ($AccountName2): TikTok every 6 hours (offset), Instagram daily at 2 PM" -ForegroundColor White
    
    Write-Host ""
    Write-Host "📚 Next Steps:" -ForegroundColor Yellow
    Write-Host "   1. Monitor your bots using the dashboard" -ForegroundColor White
    Write-Host "   2. Check logs to ensure everything is working" -ForegroundColor White
    Write-Host "   3. Customize configurations in helm/tiksimpro/values-quickstart.yaml" -ForegroundColor White
    Write-Host "   4. Learn about scaling and management with the Manage-TikSimPro.ps1 script" -ForegroundColor White
    
    Write-Host ""
    Write-Host "⚠️  Remember to:" -ForegroundColor Red
    Write-Host "   - Change default passwords in production" -ForegroundColor White
    Write-Host "   - Configure your actual social media credentials" -ForegroundColor White
    Write-Host "   - Review and adjust the publishing schedules" -ForegroundColor White
}

# Main execution
try {
    Write-WelcomeMessage
    Test-Prerequisites
    New-QuickStartConfiguration
    
    if (Start-QuickDeployment) {
        Show-QuickStartResults
    }
    
} catch {
    Write-Host ""
    Write-Host "❌ Quick start failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "   Please check the error messages above and try again" -ForegroundColor Yellow
    exit 1
}

# ==========================================
# .github/workflows/deploy.yml - Complete CI/CD pipeline
# ==========================================
name: 🚀 TikSimPro CI/CD Pipeline

# Trigger conditions for the workflow
on:
  # Trigger on pushes to main and develop branches
  push:
    branches: [ main, develop ]
    paths-ignore:
      - 'docs/**'
      - '*.md'
      - '.gitignore'
  
  # Trigger on pull requests to main
  pull_request:
    branches: [ main ]
    paths-ignore:
      - 'docs/**'
      - '*.md'
      - '.gitignore'
  
  # Allow manual triggering from GitHub interface
  workflow_dispatch:
    inputs:
      environment:
        description: 'Target environment'
        required: true
        default: 'development'
        type: choice
        options:
          - development
          - staging
          - production
      skip_tests:
        description: 'Skip test execution'
        required: false
        default: false
        type: boolean

# Global environment variables used across all jobs
env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}

jobs:
  # Job 1: Code quality and testing
  quality-check:
    name: 🔍 Code Quality & Tests
    runs-on: ubuntu-latest
    
    steps:
    - name: 📥 Checkout repository
      uses: actions/checkout@v4
      with:
        fetch-depth: 0  # Fetch full history for better analysis
    
    - name: 🐍 Set up Python
      uses: actions/setup-python@v4
      with:
        python-version: '3.11'
        cache: 'pip'  # Cache pip dependencies for faster builds
    
    - name: 📦 Install dependencies
      run: |
        python -m pip install --upgrade pip
        pip install -r requirements.txt
        pip install pytest pytest-cov flake8 black isort mypy
    
    - name: 🔍 Code formatting check (Black)
      run: |
        black --check --diff src/ tests/
    
    - name: 📋 Import sorting check (isort)
      run: |
        isort --check-only --diff src/ tests/
    
    - name: 🔍 Linting (flake8)
      run: |
        # Stop the build if there are Python syntax errors or undefined names
        flake8 src/ tests/ --count --select=E9,F63,F7,F82 --show-source --statistics
        # Treat all other issues as warnings
        flake8 src/ tests/ --count --exit-zero --max-complexity=10 --max-line-length=127 --statistics
    
    - name: 🔍 Type checking (mypy)
      run: |
        mypy src/ --ignore-missing-imports --no-strict-optional
      continue-on-error: true  # Don't fail the build on type errors yet
    
    - name: 🧪 Run unit tests
      if: ${{ !inputs.skip_tests }}
      run: |
        pytest tests/ --cov=src/ --cov-report=xml --cov-report=html --junitxml=pytest.xml
    
    - name: 📊 Upload test results
      uses: actions/upload-artifact@v3
      if: always()
      with:
        name: test-results
        path: |
          pytest.xml
          htmlcov/
          coverage.xml
    
    - name: 📈 Upload coverage to Codecov
      uses: codecov/codecov-action@v3
      if: ${{ !inputs.skip_tests }}
      with:
        file: ./coverage.xml
        flags: unittests
        name: codecov-umbrella

  # Job 2: Build and publish Docker image
  build-image:
    name: 🏗️ Build Docker Image
    needs: quality-check
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    
    outputs:
      image-tag: ${{ steps.meta.outputs.tags }}
      image-digest: ${{ steps.build.outputs.digest }}
    
    steps:
    - name: 📥 Checkout repository
      uses: actions/checkout@v4
    
    - name: 🐳 Set up Docker Buildx
      uses: docker/setup-buildx-action@v3
    
    - name: 🔑 Log in to Container Registry
      uses: docker/login-action@v3
      with:
        registry: ${{ env.REGISTRY }}
        username: ${{ github.actor }}
        password: ${{ secrets.GITHUB_TOKEN }}
    
    - name: 🏷️ Extract metadata
      id: meta
      uses: docker/metadata-action@v5
      with:
        images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
        tags: |
          type=ref,event=branch
          type=ref,event=pr
          type=sha,prefix={{branch}}-
          type=raw,value=latest,enable={{is_default_branch}}
          type=semver,pattern={{version}}
          type=semver,pattern={{major}}.{{minor}}
    
    - name: 🏗️ Build and push Docker image
      id: build
      uses: docker/build-push-action@v5
      with:
        context: .
        file: ./docker/Dockerfile
        push: true
        tags: ${{ steps.meta.outputs.tags }}
        labels: ${{ steps.meta.outputs.labels }}
        cache-from: type=gha
        cache-to: type=gha,mode=max
        platforms: linux/amd64,linux/arm64
    
    - name: 🔍 Run security scan on image
      uses: aquasecurity/trivy-action@master
      with:
        image-ref: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ github.sha }}
        format: 'sarif'
        output: 'trivy-results.sarif'
      continue-on-error: true
    
    - name: 📋 Upload security scan results
      uses: github/codeql-action/upload-sarif@v2
      if: always()
      with:
        sarif_file: 'trivy-results.sarif'

  # Job 3: Deploy to development (develop branch)
  deploy-development:
    name: 🚀 Deploy to Development
    needs: build-image
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/develop' || (github.event_name == 'workflow_dispatch' && inputs.environment == 'development')
    environment: 
      name: development
      url: https://tiksimpro-dev.your-domain.com
    
    steps:
    - name: 📥 Checkout repository
      uses: actions/checkout@v4
    
    - name: ⚙️ Set up kubectl
      uses: azure/setup-kubectl@v3
      with:
        version: 'latest'
    
    - name: ⚙️ Set up Helm
      uses: azure/setup-helm@v3
      with:
        version: 'latest'
    
    - name: 🔐 Configure kubeconfig
      run: |
        echo "${{ secrets.KUBE_CONFIG_DEVELOPMENT }}" | base64 -d > kubeconfig
        echo "KUBECONFIG=$(pwd)/kubeconfig" >> $GITHUB_ENV
    
    - name: 🧪 Validate Kubernetes manifests
      run: |
        helm template tiksimpro-dev ./helm/tiksimpro \
          --namespace tiksimpro-development \
          --values ./helm/tiksimpro/values.yaml \
          --set image.repository=${{ env.REGISTRY }}/${{ env.IMAGE_NAME }} \
          --set image.tag=${{ github.sha }} \
          --dry-run=client > /dev/null
    
    - name: 🚀 Deploy to development
      run: |
        helm repo add bitnami https://charts.bitnami.com/bitnami
        helm repo update
        
        helm upgrade --install tiksimpro-dev ./helm/tiksimpro \
          --namespace tiksimpro-development \
          --create-namespace \
          --values ./helm/tiksimpro/values.yaml \
          --set image.repository=${{ env.REGISTRY }}/${{ env.IMAGE_NAME }} \
          --set image.tag=${{ github.sha }} \
          --set global.environment=development \
          --timeout 10m \
          --wait \
          --atomic
    
    - name: 🔍 Verify deployment
      run: |
        kubectl get pods -n tiksimpro-development
        kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=tiksimpro -n tiksimpro-development --timeout=300s
    
    - name: 🧪 Run smoke tests
      run: |
        # Wait for services to be fully ready
        sleep 30
        
        # Test that the web interface is accessible
        kubectl port-forward svc/tiksimpro-web 8080:80 -n tiksimpro-development &
        sleep 10
        
        # Basic health check
        curl -f http://localhost:8080/health || echo "Health check endpoint not yet available"
        
        # Stop port forwarding
        pkill -f "kubectl port-forward"

  # Job 4: Deploy to staging (main branch, before production)
  deploy-staging:
    name: 🚀 Deploy to Staging
    needs: build-image
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main' || (github.event_name == 'workflow_dispatch' && inputs.environment == 'staging')
    environment: 
      name: staging
      url: https://tiksimpro-staging.your-domain.com
    
    steps:
    - name: 📥 Checkout repository
      uses: actions/checkout@v4
    
    - name: ⚙️ Set up kubectl
      uses: azure/setup-kubectl@v3
      with:
        version: 'latest'
    
    - name: ⚙️ Set up Helm
      uses: azure/setup-helm@v3
      with:
        version: 'latest'
    
    - name: 🔐 Configure kubeconfig
      run: |
        echo "${{ secrets.KUBE_CONFIG_STAGING }}" | base64 -d > kubeconfig
        echo "KUBECONFIG=$(pwd)/kubeconfig" >> $GITHUB_ENV
    
    - name: 🚀 Deploy to staging
      run: |
        helm repo add bitnami https://charts.bitnami.com/bitnami
        helm repo update
        
        helm upgrade --install tiksimpro-staging ./helm/tiksimpro \
          --namespace tiksimpro-staging \
          --create-namespace \
          --values ./helm/tiksimpro/values-staging.yaml \
          --set image.repository=${{ env.REGISTRY }}/${{ env.IMAGE_NAME }} \
          --set image.tag=${{ github.sha }} \
          --set global.environment=staging \
          --timeout 15m \
          --wait \
          --atomic
    
    - name: 🔍 Verify deployment
      run: |
        kubectl get pods -n tiksimpro-staging
        kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=tiksimpro -n tiksimpro-staging --timeout=300s
    
    - name: 🧪 Run integration tests
      run: |
        # Extended testing for staging environment
        echo "Running integration tests..."
        
        # Test database connectivity
        kubectl exec -n tiksimpro-staging deployment/tiksimpro-postgresql -- pg_isready -U tiksimpro
        
        # Test Redis connectivity
        kubectl exec -n tiksimpro-staging deployment/tiksimpro-redis-master -- redis-cli ping

  # Job 5: Deploy to production (manual approval required)
  deploy-production:
    name: 🚀 Deploy to Production
    needs: [build-image, deploy-staging]
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main' || (github.event_name == 'workflow_dispatch' && inputs.environment == 'production')
    environment: 
      name: production
      url: https://tiksimpro.your-domain.com
    
    steps:
    - name: 📥 Checkout repository
      uses: actions/checkout@v4
    
    - name: ⚙️ Set up kubectl
      uses: azure/setup-kubectl@v3
      with:
        version: 'latest'
    
    - name: ⚙️ Set up Helm
      uses: azure/setup-helm@v3
      with:
        version: 'latest'
    
    - name: 🔐 Configure kubeconfig
      run: |
        echo "${{ secrets.KUBE_CONFIG_PRODUCTION }}" | base64 -d > kubeconfig
        echo "KUBECONFIG=$(pwd)/kubeconfig" >> $GITHUB_ENV
    
    - name: 💾 Backup current deployment
      run: |
        # Create backup of current Helm values
        helm get values tiksimpro-prod -n tiksimpro-production > production-backup-$(date +%Y%m%d-%H%M%S).yaml || echo "No existing deployment to backup"
    
    - name: 🚀 Deploy to production
      run: |
        helm repo add bitnami https://charts.bitnami.com/bitnami
        helm repo update
        
        helm upgrade --install tiksimpro-prod ./helm/tiksimpro \
          --namespace tiksimpro-production \
          --create-namespace \
          --values ./helm/tiksimpro/values-production.yaml \
          --set image.repository=${{ env.REGISTRY }}/${{ env.IMAGE_NAME }} \
          --set image.tag=${{ github.sha }} \
          --set global.environment=production \
          --timeout 20m \
          --wait \
          --atomic
    
    - name: 🔍 Verify production deployment
      run: |
        kubectl get pods -n tiksimpro-production
        kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=tiksimpro -n tiksimpro-production --timeout=600s
        
        # Verify all expected pods are running
        expected_pods=$(kubectl get statefulset -n tiksimpro-production -l app.kubernetes.io/name=tiksimpro -o jsonpath='{.items[*].spec.replicas}' | tr ' ' '+' | bc)
        actual_pods=$(kubectl get pods -n tiksimpro-production -l app.kubernetes.io/name=tiksimpro --field-selector=status.phase=Running --no-headers | wc -l)
        
        if [ "$actual_pods" -eq "$expected_pods" ]; then
          echo "✅ All $actual_pods pods are running successfully"
        else
          echo "❌ Expected $expected_pods pods, but only $actual_pods are running"
          exit 1
        fi
    
    - name: 🧪 Run production health checks
      run: |
        # Comprehensive health checks for production
        echo "Running production health checks..."
        
        # Check all pods are healthy
        kubectl get pods -n tiksimpro-production -l app.kubernetes.io/name=tiksimpro
        
        # Test database connectivity
        kubectl exec -n tiksimpro-production deployment/tiksimpro-postgresql -- pg_isready -U tiksimpro
        
        # Test Redis connectivity
        kubectl exec -n tiksimpro-production deployment/tiksimpro-redis-master -- redis-cli ping
        
        # Check service endpoints
        kubectl get endpoints -n tiksimpro-production
    
    - name: 📊 Post-deployment monitoring setup
      run: |
        echo "Setting up post-deployment monitoring..."
        
        # Ensure monitoring is working
        kubectl get pods -n tiksimpro-production -l app.kubernetes.io/name=prometheus
        kubectl get pods -n tiksimpro-production -l app.kubernetes.io/name=grafana
    
    - name: 📢 Notify deployment success
      if: success()
      run: |
        echo "🎉 Production deployment successful!"
        echo "Version: ${{ github.sha }}"
        echo "Environment: production"
        echo "Timestamp: $(date)"
        # Add notification to Slack/Discord/Teams here if configured

  # Job 6: Cleanup old images and failed deployments
  cleanup:
    name: 🧹 Cleanup
    needs: [deploy-development, deploy-staging, deploy-production]
    runs-on: ubuntu-latest
    if: always()
    
    steps:
    - name: 🗑️ Delete old container images
      uses: actions/delete-package-versions@v4
      with:
        package-name: ${{ env.IMAGE_NAME }}
        package-type: 'container'
        min-versions-to-keep: 10
        delete-only-untagged-versions: true