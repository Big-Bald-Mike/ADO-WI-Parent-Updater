param (
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$workitemID,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$token, # Pass in a token with Work Item permissions for the API calls.

    [ValidateNotNullOrEmpty()]
    [string]$org, # Needed for API call.

    [ValidateNotNullOrEmpty()]
    [string]$project # Needed for API call.
    ) 

# Make API Call for WI information.
$URI = 'https://dev.azure.com/' + $org + '/' + $project + '/_apis/wit/workitems/' + $workitemID + '?$expand=relations&api-version=6.0'
$Header = @{
        Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($token)"))
        }
Write-Host "Accessing URI: $URI"
$response = Invoke-RestMethod -Uri $URI -Headers $Header 

#Parse response information for needed info.
$parentID = $response.fields.'System.Parent'
$childState = $response.fields.'System.State'
$childType = $response.fields.'System.WorkItemType'

# Get Categories for child WI type.
$URI2 = 'https://dev.azure.com/' + $org + '/' + $project + '/_apis/wit/workitemtypes/' + $childType + '/states?api-version=7.1-preview.1'
$cstates = Invoke-RestMethod -Uri $URI2 -Headers $Header 

# Get parent state.
$ParentURI = 'https://dev.azure.com/' + $org + '/' + $project + '/_apis/wit/workitems/' + $parentID + '?$expand=relations&api-version=6.0'
$parentjson = Invoke-RestMethod -Uri $ParentURI -Headers $Header
$parentState = $parentjson.fields.'System.State'
$parentType = $parentjson.fields.'System.WorkItemType'

# Get Categories for parent WI type.
$URI2 = 'https://dev.azure.com/' + $org + '/' + $project + '/_apis/wit/workitemtypes/' + $parentType + '/states?api-version=7.1-preview.1'
$pstates = Invoke-RestMethod -Uri $URI2 -Headers $Header 

# Output for testing.
Write-Host "The requested WI number is $workitemID and the state is $childState"
Write-host "The parent WI number is $parentID and the state is $parentState"

# Line up state names to state categories for child.
foreach ($row in $cstates.value) {
    if ($row.name -eq $childState) {
        $childCat = $row.category
    }
}

# Line up state names to state categories for parent.
foreach ($row in $pstates.value) {
    if ($row.name -eq $parentState) {
        $parentCat = $row.category
    }
}

# Get first In Progress state for parent type
foreach ($row in $pstates.value) {
    if ($row.category -eq "InProgress") {
        $firstActive = $row.name
        break
    }
}

# Fix parent if necessary
if (($childCat -ne "Proposed") -and ($parentCat -eq "Proposed")) {
    Write-Host "Needs fixing"
        
    $fixBody = @"
    [{  "op": "add", 
        "path": "/fields/System.State", 
        "value": "$($firstActive)" }]
"@ 

    $ParentURI = 'https://dev.azure.com/' + $org + '/' + $project + '/_apis/wit/workitems/' + $parentID + '?api-version=6.0'

    Invoke-RestMethod -Uri $ParentURI -Method Patch -Headers $Header -Body $fixBody -ContentType application/json-patch+json
    Write-Host "Parent updated"
} else {
    Write-Host "All good here."
    }
