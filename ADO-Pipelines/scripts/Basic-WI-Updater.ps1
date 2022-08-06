param (
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$workitemID,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$token, # Pass in a token with Work Item permissions for the API calls.

    [ValidateNotNullOrEmpty()]
    [string]$org, # Needed for API call

    [ValidateNotNullOrEmpty()]
    [string]$project # Needed for API call
    ) 


# Make API Call for WI information
$URI = 'https://dev.azure.com/' + $org + '/' + $project + '/_apis/wit/workitems/' + $workitemID + '?$expand=relations&api-version=6.0'

$Header = @{
        Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($token)"))
        }

$response = Invoke-RestMethod -Uri $URI -Headers $Header 

#Parse response information for needed info.
$parentID = $response.fields.'System.Parent'
$childState = $response.fields.'System.State'

# get parent state
$ParentURI = 'https://dev.azure.com/' + $org + '/' + $project + '/_apis/wit/workitems/' + $parentID + '?$expand=relations&api-version=6.0'
$parentjson = Invoke-RestMethod -Uri $ParentURI -Headers $Header
$parentState = $parentjson.fields.'System.State'

# Output for testing
Write-Host "The requested WI number is $workitem and the state is $childState"
Write-host "The parent WI number is $parentID and the state is $parentState"

# fix parent if necessary
if (($childState -ne "To Do") -and ($parentState -eq "To Do")) {
    Write-Host "Needs fixing"
        
    $fixBody = @"
    [{  "op": "add", 
        "path": "/fields/System.State", 
        "value": "Doing" }]
"@ 

    $ParentURI = 'https://dev.azure.com/Motion-IT/DevSecOps/_apis/wit/workitems/' + $parentID + '?api-version=6.0'

    Invoke-RestMethod -Uri $ParentURI -Method Patch -Headers $Header -Body $fixBody -ContentType application/json-patch+json
    Write-Host "Parent updated"
} else {
    Write-Host "All good here."
    }
