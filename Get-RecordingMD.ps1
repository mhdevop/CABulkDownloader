	<#
.SYNOPSIS
Retrieve the meta-data of PSM recordings

.DESCRIPTION
Returns the details of recordings of PSM, PSMP or OPM sessions and most importantly the GUID for use with PACLI.

.INPUTS
Make sure you edit the variables before running to match your environment

.OUTPUTS
CSV for reference later and videos/txt files to a folder of your choosing

.NOTES
Minimum CyberArk Version 9.10
Big credit to pspete for his PS Module for the Restful API! (https://github.com/pspete/psPAS)

#>

#CHANGE ME!!!! You need to change these variables to match your environment 
Import-Module 'E:\yourpathhere\psPAS' -Force # import the amazing psPAS module where you have it stored
Import-Module 'E:\yourpathhere\PoShPACLI' -Force # import the amazing poshpacli module where you have it stored
$basepamrurl ='https://yoururl.com' #your base CyberArk URL for PVWA. Should be a Load Balanced address.
$exportpath = 'E:\yourpathhere\ExportedRecordings' #path you want to save all the exports
$useRadius = $true #true or false if you use Radius for RestFUL API, NOT PACLI
$pathToPACLIFolder = 'E:\PACLI-v9.8' #I only had luck with 9.8 myself.
$vaultServerFQDN = "primaryvault.yours.com"
$vaultName = "Production Vault" 

#PowerShell method of semi-securing a credential
$pscredentialvar = Get-Credential

#NOTE: you can alternatively use a more automate approach using AIM with PowerShell's native credential object:
# $pscredentialvar = New-Object System.Management.Automation.PSCredential("domain\samid",$(YOURAIMCALLHERE | ConvertTo-SecureString -AsPlainText -Force))

#use psPAS module to connect. You may need to remove/change the radius switch for your version
$token = New-PASSession -Credential $pscredentialvar -BaseURI $basepamrurl -useRadiusAuthentication $useRadius -Verbose

#CHANGE ME !!!
#get and download bulk metadata recording info by specifing your own critera
# to see how you can specify criteria use: get-help Get-PASPSMRecording -Full
$recs = $token | Get-PASPSMRecording -FromTime 100 -Search 'servernameinquestion' -Limit 999 -ToTime 0 -Verbose

#Unix Time to .NET datetime object (http://codeclimber.net.nz/archive/2007/07/10/convert-a-unix-timestamp-to-a-net-datetime/) There's probably a better way of doing it.
$origin = New-Object -Type DateTime -ArgumentList 1970, 1, 1, 0, 0, 0, 0

#OPTIONAL: humans don't "natively" understand Unix Time so I use expressions to translate to the "local time" where the script is being run from. In my case MT.
#Notice the "select *" which is where the entire object gets expanded and you can see the GUID which is needed for PACLI to "guess" the file path of the object you want to download
$filteredRecs = $recs | select *,@{Name='StartTime(MT)'; Expression={$origin.AddSeconds([int]$_.start).ToLocalTime()}},@{Name='EndTime(MT)'; Expression={$origin.AddSeconds([int]$_.end).ToLocalTime()}}

#store the sheet manually if desired or comment out the next 2 lines
$filteredRecs | Export-Csv "$($env:TEMP)\Recordings.csv" -NoTypeInformation -Force
ii $env:TEMP

#kill the token variable as it's used later for sanity
$token = $null


#start PACLI where it's located
Initialize-PoShPACLI -pacliFolder $pathToPACLIFolder

#use try, catch, finally to ensure the PACLI process gets properly closed out no matter what happens to ensure it's thread safe.
#if PACLI is already running you run in to issues so ensure it always exits.
try{

    #connect to PACLI and get a token to make future commands easy
    #CHANGE ME!!!! I use a local account because I can't get PACLI to work with Radius but you can change this line to suite your needs (or use AIM again here or a cred file)
    $token = Start-PVPACLI -sessionID 43 | New-PVVaultDefinition -address $vaultServerFQDN -vault $vaultName | Connect-PVVault -user YOURLOCALCAACCOUNTNAME -password (Read-Host 'pass' -AsSecureString)
    
    #opens the PSMRecordings safe. REMEMBER: The account you use for this PACLI script must have "list and retrieve" for this to work.
    $token | Open-PVSafe -safe 'PSMRecordings' -Verbose

    #human run counter variable for loop that goes through all the "rows" of the array retrieved from the Restful API earlier
    $counter = 1
    foreach ($row in $filteredRecs)
    {

     #OPTION - you can customze the file name to be whatever you like. This just seemed to work for us.
     $formattedFileName = "$(($origin.AddSeconds([int]$row.start)).ToLocalTime().ToString( "yyyy-MM-ddTHH-mm-ssZ" ))-$($row.User)-$($row.AccountUsername)"

     #I know there's a debate on write-host but comment it out if you don't like it ;)
     write-host "Processing $($row.SessionGuid): $counter of $($filteredRecs.count)" -ForegroundColor Green

     #this is the "magic" of this whole script. Since we have the GUID from the Restful API we can now reasonably "guess" as to what CyberArk calls the "file name" of the recording objects.
     #video have the extension ".VID.avi" and text is "SSH.txt" (Unix). It doesn't always work but it's oh so close.
     $token | Get-PVFile -safe 'PSMRecordings' -folder root -localFolder "$exportpath" -localFile "$formattedFileName.avi" -file "$($row.SessionGuid).VID.avi" # -Verbose
     $token | Get-PVFile -safe 'PSMRecordings' -folder root -localFolder "$exportpath" -localFile "$formattedFileName.txt" -file "$($row.SessionGuid).SSH.txt" # -Verbose
     
     #OPTION - you can comment out this whole section if you want. It exists to parse the aweful "human format" of the logs to only show "interactive keys typed"
     $file = Get-Content "$exportpath\$formattedFileName.txt"
     Write-Host "Cleaning file..." -ForegroundColor Yellow
     
     #loop through the non-human-friendly log for auditors and pull out only "keys" values (you can substitue this value for the other types in the log if you want)
     foreach ($line in $file)
     {
        #again, you can change this if you're interested in other things like output for example
        if ($line -like "*|KEYS|*")
        {
            #split the lines in a nice human friendly format and dump it back out with the added "cleaned" extension that will make your auditors smile
            $line.split('|')[3] | Out-File "$exportpath\$formattedFileName.CLEANED.txt" -Encoding ascii -Append -Force
        }

     }
     
     #sanity check - probably not needed but keeping for further development in the ISE ensuring no stale values in my cache
     $file = $null
     
     #increase coutner for human runs of this script
     $counter++
    }


}
#catch and show any error along with exporting it to a CSV for the Vault Admin to manually review later. 
#most common failures is the "file does not exist" which means manual effort to figure out why.
catch
{
    $error
    $error | export-csv "$exportpath\PACLIMASTERERRORS.csv" -NoTypeInformation -Force
}
#VERY important - ensure PACLI process stops or else you'll get errors when you attempt to run it again.
finally
{
    $token | Stop-PVPacli -Verbose
}
