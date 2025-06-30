# ==========================================
# scripts/Deploy-TikSimPro.ps1 - Windows deployment script
# ==========================================
<#
.SYNOPSIS
    Deploy TikSimPro to Kubernetes cluster

.DESCRIPTION
    This script deploys the TikSimPro application to a Kubernetes cluster using Helm.
    It supports multiple environments (development, staging, production) and includes
    comprehensive error checking and validation.

.PARAMETER Environment
    The target environment (development, staging, production)

.PARAMETER Namespace
    The Kubernetes namespace to deploy to

.PARAMETER ImageTag
    The Docker image tag to deploy

.PARAMETER DryRun
    Perform a dry run without actually deploying

.EXAMPLE
    .\scripts\Deploy-TikSimPro.ps1 -Environment production -Namespace tiksimpro-prod

.EXAMPLE
    .\scripts\Deploy-TikSimPro.ps1 -Environment development -DryRun
#>

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("development", "staging", "production")]
    [string]$Environment = "development",
    
    [Parameter(Mandatory=$false)]
    [string]$Namespace = "",
    
    [Parameter(Mandatory=$false)]
    [string]$ImageTag = "latest",
    
    [Parameter(Mandatory=$false)]
    [switch]$DryRun = $false
)

# Set namespace based on environment if not specified
if ([string]::IsNullOrEmpty($Namespace)) {
    $Namespace = "tiksimpro-$Environment"
}

# Color-coded logging functions for better readability
function Write-InfoMessage {
    param([string]$Message)
    Write-Host "ℹ️  $Message" -ForegroundColor Cyan
}

function Write-SuccessMessage {
    param([string]$Message)
    Write-Host "✅ $Message" -ForegroundColor Green
}

function Write-WarningMessage {
    param([string]$Message)
    Write-Host "⚠️  $Message" -ForegroundColor Yellow
}

function Write-ErrorMessage {
    param([string]$Message)
    Write-Host "❌ $Message" -ForegroundColor Red
}

function Write-SectionHeader {
    param([string]$Title)
    Write-Host ""
    Write-Host "=" * 60 -ForegroundColor Magenta
    Write-Host "  $Title" -ForegroundColor Magenta
    Write-Host "=" * 60 -ForegroundColor Magenta
}

# Function to check if a command exists
function Test-CommandExists {
    param([string]$Command)
    
    try {
        if (Get-Command $Command -ErrorAction SilentlyContinue) {
            return $true
        }
        return $false
    }
    catch {
        return $false
    }
}

# Function to validate Docker image build
function Test-DockerBuild {
    param([string]$ImageName)
    
    Write-InfoMessage "Building Docker image: $ImageName"
    
    if ($DryRun) {
        Write-WarningMessage "Dry run mode - skipping Docker build"
        return $true
    }
    
    try {
        $buildResult = docker build -f docker/Dockerfile -t $ImageName . 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorMessage "Docker build failed"
            Write-Host $buildResult -ForegroundColor Red
            return $false
        }
        
        Write-SuccessMessage "Docker image built successfully"
        return $true
    }
    catch {
        Write-ErrorMessage "Error during Docker build: $($_.Exception.Message)"
        return $false
    }
}

# Function to validate Kubernetes cluster connectivity
function Test-KubernetesConnection {
    Write-InfoMessage "Testing Kubernetes cluster connectivity"
    
    try {
        $clusterInfo = kubectl cluster-info --request-timeout=10s 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorMessage "Cannot connect to Kubernetes cluster"
            Write-Host $clusterInfo -ForegroundColor Red
            Write-WarningMessage "Make sure Docker Desktop > Kubernetes is enabled"
            return $false
        }
        
        Write-SuccessMessage "Kubernetes cluster connection verified"
        return $true
    }
    catch {
        Write-ErrorMessage "Error testing Kubernetes connection: $($_.Exception.Message)"
        return $false
    }
}

# Function to setup Helm repositories
function Initialize-HelmRepositories {
    Write-InfoMessage "Setting up Helm repositories"
    
    try {
        # Add required repositories
        helm repo add bitnami https://charts.bitnami.com/bitnami 2>&1 | Out-Null
        helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>&1 | Out-Null
        helm repo add grafana https://grafana.github.io/helm-charts 2>&1 | Out-Null
        
        # Update repositories
        Write-InfoMessage "Updating Helm repositories"
        helm repo update 2>&1 | Out-Null
        
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorMessage "Failed to update Helm repositories"
            return $false
        }
        
        Write-SuccessMessage "Helm repositories configured successfully"
        return $true
    }
    catch {
        Write-ErrorMessage "Error setting up Helm repositories: $($_.Exception.Message)"
        return $false
    }
}

# Function to create and configure namespace
function New-KubernetesNamespace {
    param([string]$NamespaceName, [string]$EnvironmentType)
    
    Write-InfoMessage "Creating namespace: $NamespaceName"
    
    if ($DryRun) {
        Write-WarningMessage "Dry run mode - would create namespace $NamespaceName"
        return $true
    }
    
    try {
        # Create namespace if it doesn't exist
        kubectl create namespace $NamespaceName --dry-run=client -o yaml | kubectl apply -f - 2>&1 | Out-Null
        
        # Label the namespace for better organization
        kubectl label namespace $NamespaceName `
            app.kubernetes.io/name=tiksimpro `
            app.kubernetes.io/instance=$EnvironmentType `
            environment=$EnvironmentType `
            --overwrite 2>&1 | Out-Null
        
        Write-SuccessMessage "Namespace $NamespaceName configured successfully"
        return $true
    }
    catch {
        Write-ErrorMessage "Error creating namespace: $($_.Exception.Message)"
        return $false
    }
}

# Function to deploy with Helm
function Invoke-HelmDeployment {
    param(
        [string]$ReleaseName,
        [string]$ChartPath,
        [string]$NamespaceName,
        [string]$ValuesFile,
        [string]$ImageTag
    )
    
    Write-InfoMessage "Deploying with Helm"
    Write-InfoMessage "Release: $ReleaseName"
    Write-InfoMessage "Chart: $ChartPath"
    Write-InfoMessage "Values: $ValuesFile"
    Write-InfoMessage "Image Tag: $ImageTag"
    
    if ($DryRun) {
        Write-WarningMessage "Dry run mode - would deploy to $NamespaceName"
        
        # Perform Helm template rendering for validation
        $templateResult = helm template $ReleaseName $ChartPath `
            --namespace $NamespaceName `
            --values $ValuesFile `
            --set image.tag=$ImageTag 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorMessage "Helm template validation failed"
            Write-Host $templateResult -ForegroundColor Red
            return $false
        }
        
        Write-SuccessMessage "Helm template validation passed"
        return $true
    }
    
    try {
        $deployResult = helm upgrade --install $ReleaseName $ChartPath `
            --namespace $NamespaceName `
            --create-namespace `
            --values $ValuesFile `
            --set image.tag=$ImageTag `
            --timeout 10m `
            --wait `
            --atomic 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorMessage "Helm deployment failed"
            Write-Host $deployResult -ForegroundColor Red
            return $false
        }
        
        Write-SuccessMessage "Helm deployment completed successfully"
        return $true
    }
    catch {
        Write-ErrorMessage "Error during Helm deployment: $($_.Exception.Message)"
        return $false
    }
}

# Function to verify deployment
function Test-Deployment {
    param([string]$NamespaceName)
    
    Write-InfoMessage "Verifying deployment health"
    
    if ($DryRun) {
        Write-WarningMessage "Dry run mode - skipping deployment verification"
        return $true
    }
    
    try {
        # Wait for pods to be ready
        Write-InfoMessage "Waiting for pods to be ready (timeout: 5 minutes)"
        $waitResult = kubectl wait --for=condition=ready pod `
            -l app.kubernetes.io/name=tiksimpro `
            -n $NamespaceName `
            --timeout=300s 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorMessage "Pods failed to become ready within timeout"
            Write-Host $waitResult -ForegroundColor Red
            
            # Show pod status for debugging
            Write-InfoMessage "Current pod status:"
            kubectl get pods -n $NamespaceName -l app.kubernetes.io/name=tiksimpro
            
            return $false
        }
        
        Write-SuccessMessage "All pods are ready and healthy"
        return $true
    }
    catch {
        Write-ErrorMessage "Error verifying deployment: $($_.Exception.Message)"
        return $false
    }
}

# Function to display deployment information
function Show-DeploymentInfo {
    param([string]$NamespaceName, [string]$ReleaseName)
    
    Write-SectionHeader "Deployment Information"
    
    # Show Helm release status
    Write-InfoMessage "Helm Release Status:"
    helm status $ReleaseName -n $NamespaceName
    
    Write-InfoMessage "Kubernetes Resources:"
    kubectl get all -n $NamespaceName -l app.kubernetes.io/name=tiksimpro
    
    Write-InfoMessage "Persistent Volumes:"
    kubectl get pvc -n $NamespaceName
    
    Write-SectionHeader "Access Information"
    
    Write-Host "🌐 To access the web dashboard:" -ForegroundColor Yellow
    Write-Host "   kubectl port-forward svc/tiksimpro-web 8080:80 -n $NamespaceName" -ForegroundColor White
    Write-Host "   Then open: http://localhost:8080" -ForegroundColor White
    Write-Host ""
    
    Write-Host "📋 Useful commands:" -ForegroundColor Yellow
    Write-Host "   View all resources:  kubectl get all -n $NamespaceName" -ForegroundColor White
    Write-Host "   View bot logs:       kubectl logs -f -l app.kubernetes.io/component=bot -n $NamespaceName" -ForegroundColor White
    Write-Host "   Scale bot1:          kubectl scale statefulset tiksimpro-bot1 --replicas=2 -n $NamespaceName" -ForegroundColor White
    Write-Host "   Delete deployment:   helm uninstall $ReleaseName -n $NamespaceName" -ForegroundColor White
}

# Main deployment logic
function Start-Deployment {
    Write-SectionHeader "TikSimPro Kubernetes Deployment"
    
    Write-InfoMessage "Environment: $Environment"
    Write-InfoMessage "Namespace: $Namespace"
    Write-InfoMessage "Image Tag: $ImageTag"
    if ($DryRun) {
        Write-WarningMessage "DRY RUN MODE - No actual changes will be made"
    }
    
    # Step 1: Verify prerequisites
    Write-SectionHeader "Prerequisites Check"
    
    $requiredTools = @("docker", "kubectl", "helm")
    foreach ($tool in $requiredTools) {
        if (Test-CommandExists $tool) {
            Write-SuccessMessage "$tool is available"
        } else {
            Write-ErrorMessage "$tool is not installed or not in PATH"
            Write-InfoMessage "Please install $tool before continuing"
            exit 1
        }
    }
    
    # Step 2: Test Kubernetes connectivity
    if (-not (Test-KubernetesConnection)) {
        exit 1
    }
    
    # Step 3: Build Docker image
    Write-SectionHeader "Docker Image Build"
    $imageName = "tiksimpro:$ImageTag"
    if (-not (Test-DockerBuild $imageName)) {
        exit 1
    }
    
    # Step 4: Setup Helm repositories
    Write-SectionHeader "Helm Configuration"
    if (-not (Initialize-HelmRepositories)) {
        exit 1
    }
    
    # Step 5: Create namespace
    Write-SectionHeader "Namespace Configuration"
    if (-not (New-KubernetesNamespace $Namespace $Environment)) {
        exit 1
    }
    
    # Step 6: Determine values file
    $valuesFile = "helm/tiksimpro/values.yaml"
    $environmentValuesFile = "helm/tiksimpro/values-$Environment.yaml"
    
    if (Test-Path $environmentValuesFile) {
        $valuesFile = $environmentValuesFile
        Write-InfoMessage "Using environment-specific values: $valuesFile"
    } else {
        Write-WarningMessage "Environment-specific values file not found, using default: $valuesFile"
    }
    
    # Step 7: Deploy with Helm
    Write-SectionHeader "Helm Deployment"
    $releaseName = "tiksimpro-$Environment"
    
    if (-not (Invoke-HelmDeployment $releaseName "helm/tiksimpro" $Namespace $valuesFile $ImageTag)) {
        exit 1
    }
    
    # Step 8: Verify deployment
    Write-SectionHeader "Deployment Verification"
    if (-not (Test-Deployment $Namespace)) {
        Write-ErrorMessage "Deployment verification failed"
        Write-InfoMessage "You may want to check the logs with:"
        Write-InfoMessage "kubectl logs -f -l app.kubernetes.io/name=tiksimpro -n $Namespace"
        exit 1
    }
    
    # Step 9: Show deployment information
    if (-not $DryRun) {
        Show-DeploymentInfo $Namespace $releaseName
    }
    
    Write-SectionHeader "Deployment Complete"
    Write-SuccessMessage "TikSimPro has been successfully deployed to $Environment environment!"
    
    if ($DryRun) {
        Write-InfoMessage "This was a dry run. Run the script without -DryRun to perform the actual deployment."
    }
}

# Error handling and execution
try {
    Start-Deployment
}
catch {
    Write-ErrorMessage "Deployment failed with error: $($_.Exception.Message)"
    Write-InfoMessage "Stack trace:"
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    exit 1
}