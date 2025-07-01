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

