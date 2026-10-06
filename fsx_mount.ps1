#Run following command to map FSx with Z drive:

$DriveLetter = "Z:"
$NetworkPath = "\\amznfsxefgaexqz.beta.ymc.local\share"
# Use the COM object for a 'hard' mapping
$net = New-Object -ComObject WScript.Network
# Remove existing mapping if it exists to prevent 'Device already in use' errors
if (Test-Path $DriveLetter) {
    $net.RemoveNetworkDrive($DriveLetter, $true, $true)
}
# Map the drive (the $true, $true ensures it is persistent and saved to the profile)
$net.MapNetworkDrive($DriveLetter, $NetworkPath, $true)
#Write-Host "Successfully mapped $DriveLetter to $NetworkPath" -ForegroundColor Greens




