#Requires -Version 5.1

<#
.SYNOPSIS
    Updates parent work items from "Proposed" to "InProgress" state when child items are moved.

.DESCRIPTION
    This script monitors work item state changes and automatically updates parent work items
    from a "Proposed" state to the first available "InProgress" state when child work items
    are moved out of "Proposed" state. The functionality is process and state name agnostic.

.PARAMETER workitemID
    The ID of the work item that triggered the webhook

.PARAMETER token
    Personal Access Token with Work Item read/write permissions

.PARAMETER org
    Azure DevOps organization name

.PARAMETER project
    Azure DevOps project name

.PARAMETER WhatIf
    Run in simulation mode without making actual changes

.PARAMETER MaxRetries
    Maximum number of retry attempts for API calls (default: 3)

.PARAMETER RetryDelaySeconds
    Delay between retry attempts in seconds (default: 2)

.EXAMPLE
    .\WI-Updater.ps1 -workitemID 12345 -token $token -org "myorg" -project "myproject"

.EXAMPLE
    .\WI-Updater.ps1 -workitemID 12345 -token $token -org "myorg" -project "myproject" -WhatIf -Verbose
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory, HelpMessage = "Work item ID that triggered the update")]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^\d+$', ErrorMessage = "Work item ID must be numeric")]
    [string]$workitemID,

    [Parameter(Mandatory, HelpMessage = "Personal Access Token with Work Item permissions")]
    [ValidateNotNullOrEmpty()]
    [string]$token,

    [Parameter(Mandatory, HelpMessage = "Azure DevOps organization name")]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^[a-zA-Z0-9-]+$', ErrorMessage = "Organization name contains invalid characters")]
    [string]$org,

    [Parameter(Mandatory, HelpMessage = "Azure DevOps project name")]
    [ValidateNotNullOrEmpty()]
    [string]$project,

    [Parameter(HelpMessage = "Maximum number of retry attempts for API calls")]
    [ValidateRange(1, 10)]
    [int]$MaxRetries = 3,

    [Parameter(HelpMessage = "Delay between retry attempts in seconds")]
    [ValidateRange(1, 30)]
    [int]$RetryDelaySeconds = 2,

    [Parameter(HelpMessage = "API version for work items")]
    [ValidateNotNullOrEmpty()]
    [string]$ApiVersion = '6.0',

    [Parameter(HelpMessage = "API version for work item types")]
    [ValidateNotNullOrEmpty()]
    [string]$TypesApiVersion = '7.1-preview.1'
)

# Set strict mode and error handling
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # Suppress progress bars for cleaner output

# Script-level variables
$script:ApiCallCount = 0
$script:StartTime = Get-Date

#region Helper Functions

function Write-LogMessage {
    <#
    .SYNOPSIS
        Writes formatted log messages with timestamps and levels
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        
        [ValidateSet('Info', 'Warning', 'Error', 'Success', 'Debug')]
        [string]$Level = 'Info',
        
        [switch]$NoNewline
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $emoji = switch ($Level) {
        'Info'    { 'ℹ️' }
        'Warning' { '⚠️' }
        'Error'   { '❌' }
        'Success' { '✅' }
        'Debug'   { '🔍' }
    }
    
    $formattedMessage = "[$timestamp] $emoji $Message"
    
    switch ($Level) {
        'Warning' { Write-Warning $formattedMessage }
        'Error'   { Write-Error $formattedMessage }
        'Debug'   { Write-Verbose $formattedMessage }
        default   { 
            if ($NoNewline) {
                Write-Host $formattedMessage -NoNewline
            } else {
                Write-Host $formattedMessage
            }
        }
    }
}

function Test-ApiConnection {
    <#
    .SYNOPSIS
        Tests connectivity to Azure DevOps API
    #>
    param(
        [hashtable]$Headers,
        [string]$Organization,
        [string]$Project
    )
    
    try {
        $testUri = "https://dev.azure.com/$Organization/$Project/_apis/projects/$Project" + "?api-version=6.0"
        Write-LogMessage "Testing API connectivity..." -Level Debug
        
        $null = Invoke-RestMethod -Uri $testUri -Headers $Headers -Method Get -TimeoutSec 30
        Write-LogMessage "API connectivity test successful" -Level Success
        return $true
    }
    catch {
        Write-LogMessage "API connectivity test failed: $_" -Level Error
        return $false
    }
}

function Invoke-AdoApiWithRetry {
    <#
    .SYNOPSIS
        Invokes Azure DevOps API with retry logic and comprehensive error handling
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Uri,
        
        [Parameter(Mandatory)]
        [hashtable]$Headers,
        
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')]
        [string]$Method = 'GET',
        
        [string]$Body = $null,
        
        [string]$ContentType = 'application/json',
        
        [int]$MaxRetries = $script:MaxRetries,
        
        [int]$RetryDelaySeconds = $script:RetryDelaySeconds,
        
        [int]$TimeoutSeconds = 60
    )
    
    $script:ApiCallCount++
    $sanitizedUri = $Uri -replace $token, '***TOKEN***'
    
    $attempt = 0
    $lastException = $null
    
    do {
        $attempt++
        try {
            Write-LogMessage "API call #$script:ApiCallCount attempt $attempt/$MaxRetries`: $Method $sanitizedUri" -Level Debug
            
            $params = @{
                Uri         = $Uri
                Headers     = $Headers
                Method      = $Method
                TimeoutSec  = $TimeoutSeconds
            }
            
            if ($Body) {
                $params.Body = $Body
                $params.ContentType = $ContentType
                Write-LogMessage "Request body: $($Body.Length) characters" -Level Debug
            }
            
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-RestMethod @params
            $stopwatch.Stop()
            
            Write-LogMessage "API call successful in $($stopwatch.ElapsedMilliseconds)ms" -Level Debug
            return $result
        }
        catch {
            $lastException = $_
            $statusCode = $null
            $errorMessage = $_.Exception.Message
            
            # Extract HTTP status code and response details
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
                $statusDescription = $_.Exception.Response.StatusDescription
                
                # Try to get response content for more details
                try {
                    $responseStream = $_.Exception.Response.GetResponseStream()
                    $reader = New-Object System.IO.StreamReader($responseStream)
                    $responseContent = $reader.ReadToEnd()
                    if ($responseContent) {
                        $errorDetails = $responseContent | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if ($errorDetails.message) {
                            $errorMessage = $errorDetails.message
                        }
                    }
                }
                catch {
                    # Ignore errors when trying to read response content
                }
                
                Write-LogMessage "HTTP $statusCode $statusDescription on attempt $attempt`: $errorMessage" -Level Warning
            }
            else {
                Write-LogMessage "Network/connection error on attempt $attempt`: $errorMessage" -Level Warning
            }
            
            # Determine if error is retryable
            $nonRetryableErrors = @(400, 401, 403, 404, 409)  # Bad Request, Unauthorized, Forbidden, Not Found, Conflict
            $isRetryable = $statusCode -notin $nonRetryableErrors
            
            if (-not $isRetryable) {
                Write-LogMessage "Non-retryable error ($statusCode) - aborting retries" -Level Error
                throw $lastException
            }
            
            # If this was the last attempt, throw the error
            if ($attempt -eq $MaxRetries) {
                Write-LogMessage "API call failed after $MaxRetries attempts" -Level Error
                throw $lastException
            }
            
            # Calculate delay with exponential backoff
            $delay = $RetryDelaySeconds * [Math]::Pow(2, $attempt - 1)
            Write-LogMessage "Retrying in $delay seconds... (attempt $attempt of $MaxRetries)" -Level Warning
            Start-Sleep -Seconds $delay
        }
    } while ($attempt -lt $MaxRetries)
    
    # This should never be reached, but just in case
    throw $lastException
}

function Get-WorkItemDetails {
    <#
    .SYNOPSIS
        Retrieves work item details with validation
    #>
    param(
        [string]$WorkItemId,
        [hashtable]$Headers,
        [string]$BaseUri
    )
    
    $uri = "$BaseUri/workitems/$WorkItemId" + "?`$expand=relations&api-version=$ApiVersion"
    
    try {
        $response = Invoke-AdoApiWithRetry -Uri $uri -Headers $Headers
        
        # Validate response structure
        if (-not $response.fields) {
            throw "Invalid response structure: missing 'fields' property"
        }
        
        # Extract and validate required fields
        $workItem = @{
            Id = $WorkItemId
            State = $response.fields.'System.State'
            WorkItemType = $response.fields.'System.WorkItemType'
            ParentId = $response.fields.'System.Parent'
            Title = $response.fields.'System.Title'
            AssignedTo = $response.fields.'System.AssignedTo'.displayName
            CreatedDate = $response.fields.'System.CreatedDate'
        }
        
        # Validate required fields
        if (-not $workItem.State) {
            throw "Work item $WorkItemId is missing System.State field"
        }
        
        if (-not $workItem.WorkItemType) {
            throw "Work item $WorkItemId is missing System.WorkItemType field"
        }
        
        return $workItem
    }
    catch {
        Write-LogMessage "Failed to retrieve work item $WorkItemId`: $_" -Level Error
        throw
    }
}

function Get-WorkItemTypeStates {
    <#
    .SYNOPSIS
        Retrieves available states for a work item type
    #>
    param(
        [string]$WorkItemType,
        [hashtable]$Headers,
        [string]$BaseUri
    )
    
    $encodedType = [uri]::EscapeDataString($WorkItemType)
    $uri = "$BaseUri/workitemtypes/$encodedType/states?api-version=$TypesApiVersion"
    
    try {
        $response = Invoke-AdoApiWithRetry -Uri $uri -Headers $Headers
        
        if (-not $response.value -or $response.value.Count -eq 0) {
            throw "No states found for work item type '$WorkItemType'"
        }
        
        return $response.value
    }
    catch {
        Write-LogMessage "Failed to retrieve states for work item type '$WorkItemType'`: $_" -Level Error
        throw
    }
}

function Update-WorkItemState {
    <#
    .SYNOPSIS
        Updates a work item's state
    #>
    param(
        [string]$WorkItemId,
        [string]$NewState,
        [hashtable]$Headers,
        [string]$BaseUri,
        [string]$CurrentState
    )
    
    if ($PSCmdlet.ShouldProcess("Work Item $WorkItemId", "Update state from '$CurrentState' to '$NewState'")) {
        $updateBody = @(
            @{
                op = "add"
                path = "/fields/System.State"
                value = $NewState
            }
        ) | ConvertTo-Json -Depth 3 -Compress
        
        $uri = "$BaseUri/workitems/$WorkItemId" + "?api-version=$ApiVersion"
        
        try {
            $result = Invoke-AdoApiWithRetry -Uri $uri -Headers $Headers -Method 'PATCH' -Body $updateBody -ContentType 'application/json-patch+json'
            
            # Verify the update
            $actualNewState = $result.fields.'System.State'
            if ($actualNewState -eq $NewState) {
                Write-LogMessage "Work item $WorkItemId updated successfully to '$NewState'" -Level Success
                return $result
            }
            else {
                Write-LogMessage "Update verification failed. Expected '$NewState', got '$actualNewState'" -Level Warning
                return $result
            }
        }
        catch {
            Write-LogMessage "Failed to update work item $WorkItemId`: $_" -Level Error
            throw
        }
    }
    else {
        Write-LogMessage "[WHAT-IF] Would update work item $WorkItemId from '$CurrentState' to '$NewState'" -Level Info
        return $null
    }
}

function Get-StateCategory {
    <#
    .SYNOPSIS
        Gets the category for a specific state
    #>
    param(
        [string]$StateName,
        [array]$States,
        [string]$WorkItemType
    )
    
    $stateInfo = $States | Where-Object { $_.name -eq $StateName }
    if (-not $stateInfo) {
        throw "State '$StateName' not found in available states for work item type '$WorkItemType'"
    }
    
    return $stateInfo.category
}

function Get-FirstStateInCategory {
    <#
    .SYNOPSIS
        Gets the first state in a specific category
    #>
    param(
        [string]$Category,
        [array]$States
    )
    
    $categoryStates = $States | Where-Object { $_.category -eq $Category } | Sort-Object order
    return $categoryStates | Select-Object -First 1
}

#endregion Helper Functions

#region Main Script Logic

try {
    # Script initialization
    Write-LogMessage "🚀 Starting WI Parent Updater v2.0" -Level Info
    Write-LogMessage "Processing work item: $workitemID" -Level Info
    Write-LogMessage "Organization: $org, Project: $project" -Level Debug
    Write-LogMessage "What-If Mode: $($WhatIfPreference.IsPresent)" -Level Debug
    
    # Setup API components
    $baseUri = "https://dev.azure.com/$org/$project/_apis/wit"
    $headers = @{
        Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$token"))
        'User-Agent' = 'WI-Parent-Updater/2.0'
    }
    
    # Test API connectivity
    if (-not (Test-ApiConnection -Headers $headers -Organization $org -Project $project)) {
        throw "Failed to establish API connectivity. Please check your token, organization, and project settings."
    }
    
    # Step 1: Get child work item details
    Write-LogMessage "📋 Retrieving child work item details..." -Level Info
    $childWorkItem = Get-WorkItemDetails -WorkItemId $workitemID -Headers $headers -BaseUri $baseUri
    
    Write-LogMessage "Child work item details:" -Level Info
    Write-LogMessage "  ID: $($childWorkItem.Id)" -Level Info
    Write-LogMessage "  Title: $($childWorkItem.Title)" -Level Info
    Write-LogMessage "  Type: $($childWorkItem.WorkItemType)" -Level Info
    Write-LogMessage "  State: $($childWorkItem.State)" -Level Info
    Write-LogMessage "  Assigned To: $($childWorkItem.AssignedTo)" -Level Info
    
    # Check if work item has a parent
    if (-not $childWorkItem.ParentId) {
        Write-LogMessage "Work item $workitemID has no parent. Nothing to update." -Level Info
        Write-LogMessage "🎉 Script completed successfully (no action needed)" -Level Success
        exit 0
    }
    
    Write-LogMessage "Parent ID: $($childWorkItem.ParentId)" -Level Info
    
    # Step 2: Get child work item type states
    Write-LogMessage "🔍 Retrieving child work item type states..." -Level Info
    $childStates = Get-WorkItemTypeStates -WorkItemType $childWorkItem.WorkItemType -Headers $headers -BaseUri $baseUri
    Write-LogMessage "Found $($childStates.Count) states for child work item type '$($childWorkItem.WorkItemType)'" -Level Debug
    
    # Step 3: Get parent work item details
    Write-LogMessage "👆 Retrieving parent work item details..." -Level Info
    $parentWorkItem = Get-WorkItemDetails -WorkItemId $childWorkItem.ParentId -Headers $headers -BaseUri $baseUri
    
    Write-LogMessage "Parent work item details:" -Level Info
    Write-LogMessage "  ID: $($parentWorkItem.Id)" -Level Info
    Write-LogMessage "  Title: $($parentWorkItem.Title)" -Level Info
    Write-LogMessage "  Type: $($parentWorkItem.WorkItemType)" -Level Info
    Write-LogMessage "  State: $($parentWorkItem.State)" -Level Info
    Write-LogMessage "  Assigned To: $($parentWorkItem.AssignedTo)" -Level Info
    
    # Step 4: Get parent work item type states
    Write-LogMessage "🔍 Retrieving parent work item type states..." -Level Info
    $parentStates = Get-WorkItemTypeStates -WorkItemType $parentWorkItem.WorkItemType -Headers $headers -BaseUri $baseUri
    Write-LogMessage "Found $($parentStates.Count) states for parent work item type '$($parentWorkItem.WorkItemType)'" -Level Debug
    
    # Step 5: Analyze state categories
    Write-LogMessage "🔍 Analyzing work item state categories..." -Level Info
    
    $childCategory = Get-StateCategory -StateName $childWorkItem.State -States $childStates -WorkItemType $childWorkItem.WorkItemType
    $parentCategory = Get-StateCategory -StateName $parentWorkItem.State -States $parentStates -WorkItemType $parentWorkItem.WorkItemType
    
    Write-LogMessage "State analysis:" -Level Info
    Write-LogMessage "  Child category: $childCategory" -Level Info
    Write-LogMessage "  Parent category: $parentCategory" -Level Info
    
    # Step 6: Find target state for parent
    $firstInProgressState = Get-FirstStateInCategory -Category "InProgress" -States $parentStates
    
    if (-not $firstInProgressState) {
        Write-LogMessage "No InProgress state found for parent work item type '$($parentWorkItem.WorkItemType)'. Cannot update parent." -Level Warning
        Write-LogMessage "🎉 Script completed successfully (no InProgress state available)" -Level Success
        exit 0
    }
    
    $targetStateName = $firstInProgressState.name
    Write-LogMessage "Target parent state: $targetStateName" -Level Info
    
    # Step 7: Determine if update is needed
    $updateNeeded = ($childCategory -ne "Proposed") -and ($parentCategory -eq "Proposed")
    
    Write-LogMessage "Update decision:" -Level Info
    Write-LogMessage "  Child is not Proposed: $($childCategory -ne 'Proposed')" -Level Info
    Write-LogMessage "  Parent is Proposed: $($parentCategory -eq 'Proposed')" -Level Info
    Write-LogMessage "  Update needed: $updateNeeded" -Level Info
    
    # Step 8: Update parent if needed
    if ($updateNeeded) {
        Write-LogMessage "🔄 Updating parent work item..." -Level Info
        
        $updateResult = Update-WorkItemState -WorkItemId $parentWorkItem.Id -NewState $targetStateName -Headers $headers -BaseUri $baseUri -CurrentState $parentWorkItem.State
        
        if ($updateResult) {
            Write-LogMessage "✅ Parent work item $($parentWorkItem.Id) updated successfully" -Level Success
            Write-LogMessage "  Previous state: $($parentWorkItem.State)" -Level Info
            Write-LogMessage "  New state: $targetStateName" -Level Info
        }
    }
    else {
        Write-LogMessage "✅ No update needed. Parent is already in correct state or child is still proposed." -Level Success
        Write-LogMessage "  Reason: Child category='$childCategory', Parent category='$parentCategory'" -Level Info
    }
    
    # Script completion
    $duration = (Get-Date) - $script:StartTime
    Write-LogMessage "🎉 Script completed successfully in $($duration.TotalSeconds.ToString('F2')) seconds" -Level Success
    Write-LogMessage "📊 Total API calls made: $script:ApiCallCount" -Level Info
}
catch {
    $duration = (Get-Date) - $script:StartTime
    Write-LogMessage "❌ Script failed after $($duration.TotalSeconds.ToString('F2')) seconds: $_" -Level Error
    Write-LogMessage "📊 Total API calls made: $script:ApiCallCount" -Level Info
    
    # Log stack trace for debugging
    Write-LogMessage "Stack trace:" -Level Debug
    Write-LogMessage $_.ScriptStackTrace -Level Debug
    
    # Log additional error details
    if ($_.Exception.InnerException) {
        Write-LogMessage "Inner exception: $($_.Exception.InnerException.Message)" -Level Debug
    }
    
    exit 1
}
finally {
    # Cleanup
    Write-LogMessage "🧹 Cleaning up resources..." -Level Debug
    
    # Clear sensitive variables
    if (Get-Variable -Name 'token' -ErrorAction SilentlyContinue) {
        Remove-Variable -Name 'token' -Force -ErrorAction SilentlyContinue
    }
    
    if (Get-Variable -Name 'headers' -ErrorAction SilentlyContinue) {
        Remove-Variable -Name 'headers' -Force -ErrorAction SilentlyContinue
    }
    
    Write-LogMessage "Script execution completed" -Level Debug
}

#endregion Main Script Logic