using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

# Write to the Azure Functions log stream.
Write-Host "PowerShell HTTP trigger function processed a request."

# Interact with query parameters or the body of the request.
$name = $Request.Query.Name
if (-not $name) {    $name = $Request.Body.Name}

$name2 = $Request.Query.Name2
if (-not $name) {    $name2 = $Request.Body.Name2}

####################################################################################################################
<#
 .Synopsis
     Runs multiple instances of a command in parallel.
 .Description
     This script will allow mutliple instances of a command to run at the same time with different argumnets,
     each using its own runspace from a pool of runspaces - runspaces get their own seperate thread.
     Parts of this use the work of Ryan Witschger - http://www.get-blog.com/?p=189
     and of Boe Prox https://learn-powershell.net/2012/05/13/using-background-runspaces-instead-of-psjobs-for-better-performance/
 .PARAMETER Command
     The PowerShell Command to run multiple instances of; it must be self contained -
     instances can't share variables or functions with each other or the session which launches them.
     The command can be a cmdlet, function, EXE or .ps1 file.
 .PARAMETER ScriptBlock
     Either a PowerShell scriptblock or the path to a file which can be read and executed as a script block.
 .PARAMETER InputObject
     The InputObject contains the argument(s) for the command. This can either be single item or an array,
     and can take input from the pipeline. It must either be a string , in which case the command will be run as
     Command <string>
     Or a hash table in which case the the command will be run as
     Command -Key1 value1 -key2 value 2 ....
     Or a psObject in which case the the command will be run as
     Command -PropertyName1 value1 -PropertyName2 value 2 ....
 .PARAMETER MaxThreads
     This is the maximum number of runspaces (threads) to run at any given time. The default value is 50.
 .PARAMETER MilliSecondsDelay
      When looping waiting for commands to complete, this value introduces a delay between each check to prevent
      excessive CPU utilization. The default value is 200ms. For long runnng processes, this value can be increased.
 .PARAMETER MaxRunSeconds
      The total time that can be spent looping waiting for the commands to complete.
      This will terminate the run if all threads have not completed within 5 minutes (300 seconds) by default.
 .EXAMPLE
     $xpmachines = Get-ADComputer -LDAPFilter "(operatingsystem=Windows XP*)" | select -expand name ; Start-parallel -InputObject $xpmachines -Command "Test-Connection"
     Gets Computers in Active directory which AD thinks are Windows XP and pings them using the default settings for Test-Connection.
 .EXAMPLE
     Get-ADComputer -LDAPFilter "(operatingsystem=Windows XP*)" | select -expand name | Start-parallel -Command "Test-Connection"
     More efficient than the previous example, because threads are started before Get-ADComputer has returned all the computers
 .EXAMPLE
     Get-ADComputer -LDAPFilter "(operatingsystem=Windows XP*)" | select -expand name | Start-parallel -Scriptblock {PARAM ($a) ; Test-Connection -ComputerName $a -Count 1}
     Changes the previous example to use a script block where the default parameters for Test-Connection are specified
 .EXAMPLE
     Get-ADComputer -LDAPFilter "(operatingsystem=Windows XP*)" | foreach {@{computerName=$_.name;Count=1}} | Start-parallel -Command "Test-Connection" -MaxThreads 20 -MaxRunSeconds 120
     Develops the previous example to run test-connection with the computername and count parameters explicitly passed.
     Reduces the maximum number of threads to 20 and the maxiumum processing time to 2 minutes.
 .EXAMPLE
     1..10 | Start-Parallel -Scriptblock ${Function:\quickping}
     In this example QuickPing is a function which accepts the last octet of an IP address to ping.
     Calling it as a script block in this way avoids any problems with function being a scope where start-parallel can't access it.
#>
Function Start-Parallel {
    [CmdletBinding(DefaultParameterSetName='Command')]
    Param  (
          [parameter(Mandatory=$true,ParameterSetName="Command",HelpMessage="Enter the command to process",Position=0)]
          $Command , 
          [parameter(Mandatory=$true,ParameterSetName="Block")]
          $Scriptblock,
          $TaskDisplayName = "Tasks", 
          [Parameter(ValueFromPipeline=$true)]$InputObject,
          [int]$MaxThreads           = 50,
          [int]$MilliSecondsDelay    = 200,
          [int]$MaxRunSeconds        = 300
    )
    Begin  { #Figure out what it is we have to run: did we get -command or -scriptblock and was either a file name ?
        #Write-Progress -Activity "Setting up $TaskDisplayName"  -Status "Initializing"    
        if ($PSCmdlet.ParameterSetName -eq "Command") {
            try   { $Command = Get-Command -Name  $Command  }
            catch { Throw "$command does not appear to be a valid command."}
        }
        else {  if ($Scriptblock -isnot [scriptblock] -and   (Test-Path -Path  $Scriptblock) )  {
                    $ScriptBlock      = [scriptblock]::create((Get-Item -Path  $Scriptblock).OpenText().ReadToEnd()) }
                if ($Scriptblock -isnot [scriptblock]) {Throw "Invalid Scriptblock"}          
        }
        #Prepare the pool of worker threads: note that runspaces don't inherit anything from the session they're launched from,
        #So the command / script block must be self contained.
        $taskList     = @()
        $runspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads)
        $runspacePool.Open()
        Write-Verbose -Message ("Runspace pool opened at " + ([datetime]::Now).ToString("HH:mm:ss.ffff"))
    }
    Process{ #Usually we're going to recieve parameters via the pipeline, so the threads get set up here.
         ForEach  ($object in $InputObject)  { #setup a PowerShell pipeline ; set-up what will be run and the parameters and add it to the pool
            if    ($ScriptBlock )            { $newThread = [powershell]::Create().AddScript($ScriptBlock)  }
            else                             { $newThread = [powershell]::Create().AddCommand($Command)     } 
            if      ($object -is [Int] -or
                     $object -is [string]   ) { $newThread.AddArgument($object)             | Out-Null  }
            elseif  ($object -is [hashtable]) {
                ForEach ($key in $object.Keys){ $newThread.AddParameter($key, $object.$key) | Out-Null  }
            }
            elseif  ($object -is [psobject])  {
                Foreach ($key in (Get-Member -InputObject $object -MemberType NoteProperty).Name) {
                                                $newThread.AddParameter($key, $object.$key) | Out-Null 
                }
            }
 
            $newThread.RunspacePool = $runspacePool
            #BeginInvoke runs the thread asyncronously - i.e. it gets its turn when there is a free runspace
            $handle                 = $newThread.BeginInvoke()
            #Keep a list of tasks so we can get them back in the end{} block
            $taskList              += New-Object -TypeName psobject -Property @{"Handle"=$handle; "Thread"=$newThread;}
            #Write-Progress -Activity "Setting up $TaskDisplayName"  -Status ("Created: " + $taskList.Count + " tasks" )
        }
        $taskList | Where-Object {$_.Handle.IsCompleted } | ForEach-Object {
                $_.Thread.EndInvoke($_.Handle)
                $_.Thread.Dispose()
                $_.Thread = $_.Handle = $Null
        }
    }
    End    {#We have a bunch of threads running. Keep looping round until they all complete or we hit our time out,
        Write-Verbose  -Message ("Last of $($tasklist.count) threads started: " + ([datetime]::Now).ToString("HH:mm:ss.ffff"))
        Write-Verbose  -Message ("Waiting for " + $TaskList.where({ $_.Handle.IsCompleted -eq $false}).count.tostring()  + " to complete.") 
        #Write-Progress -Activity "Setting up $TaskDisplayName"  -Completed
        #We need to to know when to stop if a thread hangs. Until that time, while there are threads still going ....
        $endBy = (Get-Date).AddSeconds($MaxRunSeconds) 
        While ($TaskList.where({$_.Handle}) -and (Get-Date) -lt $endBy)  {
            $UnFinishedCount = $TaskList.where({ $_.Handle.IsCompleted -eq $false}).count
            #Write-Progress -Activity "Waiting for $TaskDisplayName to complete" -Status "$UnFinishedCount tasks remaining" -PercentComplete (100 * ($TaskList.count - $UnFinishedCount)  / $TaskList.Count) 
            #For the tasks that have finished; call EndInovoke() - to receive the Output from the runspace and send it to our output.
            # and get rid of the thread
            $TaskList | Where-Object {$_.Handle.IsCompleted } | ForEach-Object {
                $_.Thread.EndInvoke($_.Handle)
                $_.Thread.Dispose()
                $_.Thread = $_.Handle = $Null
            }
            #Don't run in too tight a loop
            Start-Sleep -Milliseconds $MilliSecondsDelay        
        } 
        Write-Verbose -Message ("Wait for threads ended at " + ([datetime]::Now).ToString("HH:mm:ss.ffff"))
        Write-Verbose -Message ("Leaving " + $TaskList.where({ $_.Handle.IsCompleted -eq $false}).count + " incomplete.")
        #Clean up.
        #Write-Progress -Activity "Waiting for $TaskDisplayName to complete" -Completed
        [void]$RunspacePool.Close()   
        [void]$RunspacePool.Dispose() 
        [gc]::Collect()
   } 
}

#https://github.com/ssllabs/ssllabs-scan/blob/master/ssllabs-api-docs-v3.md
#https://docs.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-grid-visualizations
Clear-Host

#Install-Module -Name Start-parallel -Scope CurrentUser
#Import-Module -Name Start-parallel -ErrorAction Stop -Verbose:$false

#$name = "'edit.healthspan.co.uk'"
#$name = "'www.healthspan.co.uk','www.healthspan.ie','edit.healthspanelite.co.uk'"
#$name = "authoring.healthspan.co.uk!healthspan-sc930-authoring-prod-uks-webapp-1.azurewebsites.net"

if ($null -ne $name2) {$name = "$name,$name2"}
$name = $name -replace "'" #-replace "(\s|]|[)"
$URLs = $name -split ","


$Scriptblock = {

# Get results about input url using openssl
#https://slproweb.com/products/Win32OpenSSL.html
# Get results about input url using openssl
#https://slproweb.com/products/Win32OpenSSL.html
function Test-SSL {
                [CmdletBinding()]
                param(
                $url = "",
                $endpoint=$null,
                $opensslfolder = "C:\Program Files\OpenSSL-Win64\bin",
                $downloads=$null,
                $CAfile="microsoft_windows.pem"
                #[switch]$debug=$false
                )

if ($endpoint -notmatch ".+"){$endpoint=$url}

if ($env:OS -match "windows")
{
if ($env:Path -notmatch "$([Regex]::Escape($opensslfolder))") {$env:path = "$env:path;$opensslfolder"}
if ($null -eq $downloads)    {    $downloads="$($PSCommandPath | Split-Path -Parent)"    }

$certslocalpath="$downloads\trust_stores_as_pem.tar.gz"
cd $downloads
if (-not(Test-Path "$certslocalpath")){  Invoke-WebRequest "https://nabla-c0d3.github.io/trust_stores_observatory/trust_stores_as_pem.tar.gz" -OutFile "$certslocalpath"  }
if (-not(Test-Path "$downloads\$CAfile")){ tar -xzf $certslocalpath $CAfile }

$scan=echo "GET /" | openssl s_client -CAfile "$downloads\$CAfile" -servername $url -connect "$($endpoint):443" 2>&1 -ignore_unexpected_eof
}
else
{$scan=echo "GET /" | openssl s_client -servername $url -connect "$($endpoint):443" -crlf
}

####$scan=echo "GET /" | openssl s_client -CAfile "$downloads\$CAfile" -servername www.healthspan.co.uk -connect healthspan-prod-afd-1.azurefd.net:443 2>$scanerrror -ignore_unexpected_eof #-status #-quiet # | openssl x509 -noout -dates -subject
$string= $scan -join "`n" -replace "\r\n","\n"
#$string= $scan -join "`r`n" -replace "\r\n","`n"

Write-Debug "$string========================================================================"

$matches = $null
if ($string -match "(?ms)CONNECTED.*\n---\nCertificate chain\n(?<Chain>.*?)---\nServer certificate\n(?<Cert64>-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----)\n(?<Cert>subject.*?)\n---\n(?<Peer>.*?)\n---\n(?<Handshake>SSL handshake.*?)\n---\n(?<Connection>.*?)\n---")
{
$cert64=$matches.cert64
$handshake=$matches.Handshake
$certstr=($cert64 | openssl x509 -noout -dates -subject -fingerprint -serial) -join "`n" #| Out-String
if ($certstr -match 'notBefore\s*(:|=)\s*(.*)'){    if ($matches[2] -match "(?<Month>\S+)\s+(?<Day>\S+)\s+(?<Time>\S+)\s+(?<Year>\S+) ") {$NotBefore= Get-Date $(Get-Date -Date "$($matches.Day)-$($matches.Month)-$($matches.Year) $($matches.Time)") -Format "yyyy-MM-dd HH:mm:ss"     }}
else {$NotBefore='not found'}
if ($certstr -match 'notAfter\s*(:|=)\s*(.*)'){if ($matches[2] -match "(?<Month>\S+)\s+(?<Day>\S+)\s+(?<Time>\S+)\s+(?<Year>\S+) ") {$NotAfter= Get-Date $(Get-Date -Date "$($matches.Day)-$($matches.Month)-$($matches.Year) $($matches.Time)") -Format "yyyy-MM-dd HH:mm:ss" }else{Write-Host "not found"}}
else {$NotAfter='not found'}
if ($certstr -match 'Fingerprint\s*(:|=)\s*(.*)'){$thumbprint = $matches[2] -replace ":"}
else {$thumbprint='not found'}

$objcert= "" | Select-Object @{n='URL';e={$url}}`
                            ,@{n='Endpoint';e={$endpoint}}`
                            ,@{n='CN';e={"$(if ($certstr -match ' ?(CN = .*)'){$matches[1]}else {'not found'})"}}`
                            ,@{n='NotBefore';e={$NotBefore}}`
                            ,@{n='NotAfter';e={$NotAfter}}`
                            ,@{n='thumbprint';e={$thumbprint}}`
                            ,@{n='Verification';e={"$(if ($handshake -match 'Verification(.*)'){$matches[1] -replace "^: |^ "}else {'not found'})"}}`
                            | Select-Object *,@{n='Daysleft';e={ ($(Get-Date -date $NotAfter) - $(Get-Date)).Days }}
}
elseif($string -match ":error:.*:(.*)" )
{
Write-Debug "Error connection $($matches[1])"
$objcert= "" | Select-Object @{n='URL';e={$url}}`
                            ,@{n='Endpoint';e={$endpoint}}`
                            ,@{n='Verification';e={$matches[1]}}`
}
else {Write-Error "BAD responce";$string}


$objcert = $objcert| Select-Object -Property *,@{n='Status';e={switch ( $_.Verification ){ OK { 'success' };"calling connect" { 'unknown' };default { 'error' } }}}
#$objcert = $objcert| Select-Object -Property *,@{n='Debug';e={$cert64}}
$objcert = $objcert| Select-Object -Property *,@{n='UNI';e={"$($_.URL)!$($_.Endpoint)"}}
return $objcert
}

$delimiter = "!"
$var = $args -split "$delimiter"
Test-SSL -url $var[0] -endpoint $var[1] -downloads C:\Users\Vitalii\Scripts\https

}

#$Scriptblock = { $args }

$results = @()
$results = Start-Parallel -InputObject $URLs -Scriptblock $Scriptblock -Verbose:$false
$results = $results | Sort-Object -Property URL

#$results | ConvertTo-Json -Depth 100






####################################################################################################################
$body = $results | ConvertTo-Json -Depth 100

#$body = "This HTTP triggered function executed successfully. Pass a name in the query string or in the request body for a personalized response."
#if ($name) {    $body = "Hello, $name. This HTTP triggered function executed successfully."}

# Associate values to output bindings by calling 'Push-OutputBinding'.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body = $body
})
