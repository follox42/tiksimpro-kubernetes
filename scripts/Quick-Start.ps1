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