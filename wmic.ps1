param(
    [string]$Namespace = "root\cimv2",
    [Parameter(Mandatory = $true)] [string]$Class,
    [string]$Filter,
    [string]$Properties
)

# Pre-process the property list: turn any input into an array, otherwise leave it empty
[string[]]$propertyList = if ($Properties) {
    $Properties.Split(",") | ForEach-Object { $_.Trim() }
}
else {
    @()
}

# Check whether Get-CimInstance is available
$isSupportCim = [bool](Get-Command Get-Cimresult -ErrorAction SilentlyContinue)

# Build the query parameters
$queryParams = @{ Namespace = $Namespace }
if ($isSupportCim) { $queryParams.ClassName = $Class } else { $queryParams.Class = $Class }
if ($Filter) { $queryParams.Filter = $Filter }

# Limit the queried properties to speed the query up
# supported by CIM
# not supported by WMI
if ($isSupportCim -and $propertyList.Count -gt 0) {
    $queryParams.Property = $propertyList
}

# Run the query
$results = if ($isSupportCim) { Get-Cimresult @queryParams } else { Get-WmiObject @queryParams }

# Iterate over the results
foreach ($result in $results) {
    # Iterate over the properties
    foreach ($property in $result.PSObject.Properties) {
        $name = $property.Name
        $value = $property.Value

        # Filter out system properties
        if ($name.StartsWith("__") -or $name -eq "CimresultProperties" -or $name -eq "CimClass") { continue }

        # Only emit properties present in propertyList
        # an empty propertyList means no filtering
        if ($propertyList.Count -eq 0 -or $propertyList -contains $name) {

            # Convert to wmic output format
            # note that a string is also IEnumerable
            if ($value -isnot [string] -and $value -is [Collections.IEnumerable]) {
                $formattedValue = ($value | ForEach-Object { "`"$_`"" }) -join ","
                Write-Output "$name={$formattedValue}"
            }
            else {
                Write-Output "$name=$value"
            }
        }
    }
}
