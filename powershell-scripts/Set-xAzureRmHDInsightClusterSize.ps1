<#
    .SYNOPSIS
    This script is used to scale HDInsight clusters out and in via Azure Automation or via a Scheduled Task running on a Windows server.

    .DESCRIPTION
    This script can be used to scale a cluster by adding or removing worker nodes. The script should be executed from Azure Automation on a schedule or a Windows scheduled task.

    .PARAMETER ConfigurationFile
    The URL to the XML configuration file stored in Azure Blob Storage that contains information on the cluster, the subscription in which it resides, min and max worker nodes.


    @"
<ClusterConfiguration>
     <SubscriptionName>MySubscriptionName</SubscriptionName>
     <ResourceGroupName>MY-RG-0001</ResourceGroupName>
     <ClusterName>vjt-hdi1</ClusterName>
     <MinWorkers>1</MinWorkers>
     <MaxWorkers>3</MaxWorkers>
     <Notify>hadoopsupport@acme.com,team@acme.com</Notify>
</ClusterConfiguration>
    "@ | Out-File DSO-ClusterConfigurationFile.xml
    

    .PARAMETER ScaleOperation

    This parameter accepts to values:
    ScaleOut - will scale out the cluster to the number of worker nodes as specified by the MaxWorkers tag in the XML configuration file
    ScaleIn - will scale in the cluster (reduce the number of worker nodes) as specified by the MinWorkers tag in the XML configuration file

    .PARAMETER StorageAccountSubscription

    The name of the subscription that contains the storage account which is used to store the XML configuration file that specifies the cluster name, the subscription in which the cluster resides and other information regarding the cluster to scale in or out.

    
    .PARAMETER EmailProvider
      This parmeter is used to control which email system to use for sending email alerts. Supported values are InternalUSMail, Office365 or SendGrid


    .PARAMETER EmailCredentialFile
    File containing the credentials to use to connect to send emails. This file should reside in the same directory as the script and be named email-credential.xml
    The contents of the file should be as follows  - this needs to be done under the context of the user that the script will run as (e.g. start powershell using runas and then execute the command below):

    <credentials> 
    <credential> 
    <username>emailaccount@acme.onmicrosoft.com</username>
    <password>ReplaceWithActualPassword</password> 
    </credential>      
    </credentials>

    For example, runas /user:SVC-RTE-PSAutomation powershell.exe
    PS C:\Scripts> ConvertTo-SecureString 'aRandomPassword' -AsPlainText -Force | ConvertFrom-SecureString

    The password should be created as follows - this needs to be done under the context of the user that the script will run as (e.g. start powershell using runas and then execute the command below):
    ConvertTo-SecureString 'notTheActualPassword' -AsPlainText -Force | ConvertFrom-SecureString
    OR
    $Password = Read-Host -assecurestring "Please enter your password"
    $Password | ConvertFrom-SecureString

    - and pasted into the password tag.This needs to be run under the context of the script that the script will run under.
    For example, runas /user:SVC-PSAutomationUser powershell.exe


    .PARAMETER Test
    If this switch is specified then no scaling operation will be performed the script will only output what actions would have been taken and send email notifications.

    .EXAMPLE

    .\Set-xAzureRmHDInsightClusterSize.ps1 -ConfigurationFileURL 'http://mystorageaccount.blob.core.windows.net/hdinsight/My-ClusterConfigurationFile.xml' -ScaleOperation ScaleOut -StorageAccountSubscription 'MySubscriptionName' -EmailProvider InternalUKMail -Test -Verbose
    
    .Notes
        To Do: 
            read internal email server information from a XML configuration file instead of hard coding in the script
            make the default email address a parameter

#>

[CmdletBinding()]
Param(
  [Parameter(Mandatory = $true)]
  [String]$ConfigurationFileURL,
  [Parameter(Mandatory = $true)]
  [ValidateSet('ScaleOut','ScaleIn')]
  [String]$ScaleOperation,
  [Parameter(Mandatory = $true)]
  [String]$StorageAccountSubscription,
  [Parameter(Mandatory=$true)]
  [ValidateSet('Office365','SendGrid','InternalUSMail','InternalUKMail')]
  [string]$EmailProvider,
  [Parameter(Mandatory=$false)]
  [String]$EmailCredentialFile,
  [Parameter(Mandatory = $false)]
  [Switch]$Test = $false
)

#region --- VARIABLES ---

$StorageAccountName = ''
$StorageAccountKey = ''
$StorageAccountContainer = ''
$BlobURL = ''

$MinClusterSizeHardLimit = 1
$MaxClusterSizeHardLimit = 32

$ClusterSubscription = ''
$ClusterResourceGroup = ''
$ClusterName = ''


$EmailUsername = $null
$EmailPassword = $null
$EmailRecipients = $null

$Message = $null

$InternalDomainList = @('acme.int', 'blah.acme.int') 

#endregion

#region --- FUNCTIONS ---


Function Get-ConfigurationFileStorageAccountKey
{
  [CmdletBinding()]
  Param(
    [Parameter(Mandatory = $true)]
    [String]$StorageAccountName,
    [Parameter(Mandatory = $true)]
    [String]$StorageAccountSubscription
  )
  
  #$CredentialObject = Get-AutomationPSCredential -Name $CredentialName 
  #$CredentialObject
  #'Logging in to Azure (ARM)...'
  #Add-AzureRmAccount -Credential $CredentialObject
  Set-AzureRmContext -SubscriptionName $StorageAccountSubscription
  Write-Verbose -Message "Subscription is $StorageAccountSubscription"
  $StorageAccount = Get-AzureRmStorageAccount | Where-Object -FilterScript {
    $_.StorageAccountName -eq $StorageAccountName 
  }
  
  If($StorageAccount -eq $null)
  {
    Write-Verbose -Message "The storage account $StorageAccountName is a classic storage account"
    Set-AzureSubscription -SubscriptionName $StorageAccountSubscription
    Select-AzureSubscription -SubscriptionName $StorageAccountSubscription
    $StorageAccountKey = (Get-AzureStorageKey -StorageAccountName $StorageAccountName).Secondary
    #$Resource = Get-AzureRmResource  | ? { $_.Name -eq "automationrepository" }
    #$StorageAccountKey = (Get-AzureRmStorageAccountKey -ResourceGroupName $Resource.ResourceGroupName -Name $Resource.Name)[1].Value
  }
  Else
  {
    Write-Verbose -Message "The storage account $StorageAccountName is a ARM storage account"
    $StorageAccountKey = (Get-AzureRmStorageAccountKey -ResourceGroupName $StorageAccount.ResourceGroupName -Name $StorageAccount.StorageAccountName )[1].Value
  }
 
  #Write-Verbose -Message "Storage Account Key is:$($StorageAccountKey)"
  $Script:StorageAccountKey = $StorageAccountKey
}#End Function Get-ConfigurationFileStorageAccountKey


Function Get-AzureStorageAccountNameAndContainerFromURL
{
  [CmdletBinding()]
  Param(
    [Parameter(Mandatory = $true,HelpMessage = 'Specify the URL to the blob/file in the storage account container')]
    [String]$BlobURL
  )
  
  Write-Verbose -Message "Blob URL: $BlobURL"
  $StorageAccountDomain = "$(($BlobURL -split '/')[2])"
  Write-Verbose -Message "Storage Account Domain $($StorageAccountDomain)"
  $Script:StorageAccountContainer = "$(($BlobURL -split '/')[3])"
  Write-Verbose -Message "Storage Account Container $($Script:StorageAccountContainer)"
  $Script:StorageAccountName = "$((($StorageAccountDomain -split '\.')[0]).Trim())"
  Write-Verbose -Message "Storage Account Name $($Script:StorageAccountName)"
  $Length = ($BlobURL -split '/').Length
  $Script:BlobURL = "$(($BlobURL -split '/')[4..$Length])"
  Write-Verbose -Message "Storage Blob $($Script:BlobURL) "
}#End Function Get-AzureStorageAccountName

Function Get-ClusterScalingConfigurationFile
{
  [CmdletBinding()]
  Param(
    [Parameter(Mandatory = $true)]
    [String]$ConfigurationFileURL
  )
  
  Get-ConfigurationFileStorageAccountKey -StorageAccountName "$($Script:StorageAccountName)" -StorageAccountSubscription $Script:StorageAccountSubscription
  $StorageAccountContext = New-AzureStorageContext -StorageAccountName "$($Script:StorageAccountName)" -StorageAccountKey $Script:StorageAccountKey
  $BlobReference = Get-AzureStorageBlob -Container $Script:StorageAccountContainer -Blob $Script:BlobURL -Context $StorageAccountContext 
  #$BlobContent = $BlobReference.ICloudBlob.DownloadText()
  # This doesn't work well if the encoding is not UTF8
  [byte[]] $myByteArray = New-Object -TypeName byte[] -ArgumentList ($BlobReference.Length)
  $null = $BlobReference.ICloudBlob.DownloadToByteArray($myByteArray,0)
  [xml] $BlobContent = [xml] ([System.Text.Encoding]::UTF8.GetString($myByteArray))

  #$BlobReference | Get-AzureStorageBlobContent -Destination $BlobContent

  return $BlobContent
}#End Function Get-ClusterScalingConfigurationFile


Function Get-HDInsightQuota
{
  [CmdletBinding()]
  Param(
    [Parameter(Mandatory = $true)]
    [String]$Location
  )
  
  $QuotaObject = @{}
  (Get-AzureRmHDInsightProperties -Location $Location).QuotaCapability.RegionalQuotas | ForEach-Object -Process {
    If( $_.RegionName -eq $Location )
    {
      $QuotaObject.Add('CoresAvailable',$_.CoresAvailable)
      $QuotaObject.Add('CoresUsed',$_.CoresUsed)
    }
  }
  return $QuotaObject
}#End Function Get-HDInsightQuota


Function Get-EmailCredential
{
  [CmdletBinding()]
  Param(
    [Parameter(Mandatory=$true,ValueFromPipeline=$true)]
    [ValidateScript({
          $vr = Test-Path $_ -PathType leaf
          if(!$vr){Write-Error "The provided credential file $_ does not exist!"}  
          $vr  
    })]
    [String]$CredentialFile
  )

  Write-Verbose "Parsing $CredentialFile XML configuration for credentials to use in connecting to email server."
  $CredentialList = (Get-Content $CredentialFile) -as [xml]
    
  ForEach( $Credential in $CredentialList.Credentials )
  {
    $Script:EmailUsername = $Credential.credential.username
    $Script:EmailPassword = $Credential.credential.password | ConvertTo-SecureString
  }
  Write-Debug "Retrieved credentials from XML file, Username: $($Script:EmailUsername), Password: $($Script:EmailPassword)"
}#End Function Get-EmailCredential


Function Test-IsValidEmailAddress
{
  [CmdletBinding()]
  Param(
    [Parameter(Mandatory = $true)]
    [String]$EmailAddress
  )

  #Validate Email Address Parameter
  If (!([regex]::ismatch($EmailAddress,'\b[A-Za-z0-9._%-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,4}\b'))) 
  {
    Write-Error -Message "$($EmailAddress) is not a valid email address!`nEmaill address must be in the format 'xxxx@xxxxx.xxx'"
    return $false
  }
    
  return $true
}#End Function Test-IsValidEmailAddress


Function Send-EmailAlert
{
  [CmdletBinding()]
  Param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Office365','SendGrid','InternalUSMail','InternalUKMail')]
    [string]$EmailProvider,
    [Parameter(Mandatory = $true)]
    [String]$Message,
    [Parameter()]
    [String]$EmailSubject = 'HDInsight Cluster Scaling Alert',
    [Parameter(Mandatory = $true)]
    [String[]]$EmailRecipients = @('default@acme.com')
  )
  #$EmailProvider = $Script:EmailProvider

  $SendEmailParameters = @{}
  $SendEmailParameters.Add('Subject',$EmailSubject)
  
  # Internally the mail servers do not require auth so we don't need to bother with adding credentials (!!!)
  If($EmailProvider -eq 'Office365')
  { 
    $SendEmailParameters.Add('smtpServer','smtp.office365.com')
    $SendEmailParameters.Add('Port',587)
    $SendEmailParameters.Add('from','myo365email@acme.onmicrosoft.com')
    try
    {    
        $EmailCredentials = Get-AutomationPSCredential -Name 'Office365EmailAccount'
    }
    catch
    {
         Write-Error -Message "Unable to obtain Office365 Email Account Credentials from Azure Automation Asset. Exception: $($_.Exception)"
         throw $_.Exception
    }
    $SendEmailParameters.Add('Credential',$EmailCredentials)
  }
  ElseIf($EmailProvider -eq 'SendGrid')
  {
    $SendEmailParameters.Add('smtpServer','smtp.sendgrid.net')
    $SendEmailParameters.Add('Port',587)
    $SendEmailParameters.Add('from','mysendgridemail@azure.com')
    try
    {
        $EmailCredentials = Get-AutomationPSCredential -Name 'SendGridEmailAccount'
    }
    catch
    {
         Write-Error -Message "Unable to obtain SendGrid Email Account Credentials from Azure Automation Asset. Exception: $($_.Exception)"
         throw $_.Exception
    }
    $SendEmailParameters.Add('Credential',$EmailCredentials)
  }
  ElseIf($EmailProvider -eq 'InternalUSMail')
  { 
      $SendEmailParameters.Add('smtpServer','mail.us.acme.com')
      $SendEmailParameters.Add('Port',25)
      $SendEmailParameters.Add('from','support@acme.com')        
  }
  ElseIf($EmailProvider -eq 'InternalUKMail')
  { 
      $SendEmailParameters.Add('smtpServer','mail.uk.acme.com')
      $SendEmailParameters.Add('Port',25)
      $SendEmailParameters.Add('from','support@acme.com')        
  }
    
  
  If( $EmailProvider -eq 'Office365' -or $EmailProvider -eq 'SendGrid')
  {
    $SendEmailParameters.Add('UseSsl',$true)
  }

  $EmailBody = @"
Subscription: $($Script:ClusterSubscription)
Cluster Name: $($Script:ClusterName)
ResourceGroup:  $($Script:ClusterResourceGroup)

$Message
"@
  $SendEmailParameters.Add('body',$EmailBody)

  $ValidatedEmailRecipients = @()
  ForEach($EmailRecipient in $EmailRecipients)
  {
    If(Test-IsValidEmailAddress($EmailRecipient))
    {
      $ValidatedEmailRecipients += @($EmailRecipient)
    }
  }

  If($ValidatedEmailRecipients.Count -eq 0)
  {
    $ValidatedEmailRecipients = @('default@acme.com')
  }

  $SendEmailParameters.Add('To',$ValidatedEmailRecipients)

  Write-Verbose "Send-MailMessage parameters are $(($SendEmailParameters | out-string) -split "`n")"

  Send-MailMessage @SendEmailParameters
}#End Function Send-EmailAlert




#endregion

#region --- MAIN PROGRAM ---

If( -not($PSPrivateMetadata.JobId) ) 
{
    $Domain = (Get-WmiObject WIN32_ComputerSystem).Domain
}
Else
{
    # We are running in Azure Automation
    $Domain = 'NoDomain'
}

$CredentialName = 'AzureAutomationAccount'
try
{
    'Logging in to Azure (ARM)...'
    If( $InternalDomainList -contains $Domain )
    {
        try
        {
            Write-Output 'Checking if you have been authenticated against Azure using Login-AzureRmAccount.'        
            $AuthCheck1 = Get-AzureRmContext -ErrorAction Stop            
        }
        catch
        {
            Add-AzureRmAccount
        }
    }
    Else
    {
        $CredentialObject = Get-AutomationPSCredential -Name $CredentialName 
        Add-AzureRmAccount -Credential $CredentialObject
    }
}
catch 
{
    Write-Error -Message $_.Exception
    throw $_.Exception    
}
  
try
{
    'Logging in to Azure (Classic)...'
    If( $InternalDomainList -contains $Domain )
    {
        try
        {
            Write-Output 'Checking if you have been authenticated against Azure using Add-AzureAccont.'        
            $AuthCheck1 = Get-AzureSubscription -ExtendedDetails -Current -ErrorAction Continue
        }
        catch
        {
            Add-AzureAccont
        }
    }
    Else
    {
        $CredentialObject = Get-AutomationPSCredential -Name $CredentialName 
        Add-AzureAccount -Credential  $CredentialObject
    }

}
catch 
{
    Write-Error -Message $_.Exception
    throw $_.Exception    
}



# If we're not running in Azure automation and we're using SendGrid or Office365 then a email credential XML file must be provided as a parameter
If( ( $InternalDomainList -contains $Domain ) -and ($EmailProvider -eq 'SendGrid' -or $EmailProvider -eq 'Office365' ) )
{
  If($EmailCredentialFile -ne $null -and $EmailCredentialFile -ne '')
  {
    Get-EmailCredential -CredentialFile $EmailCredentialFile    
  }
  Else
  {
    throw "This script is NOT running in Azure Automation - you must specify the EmailCredentialFile parameter."
  } 
}


# Retrieve the XML configuration file which describes the HDInsight cluster
Get-AzureStorageAccountNameAndContainerFromURL -BlobURL $ConfigurationFileURL

$ConfigurationXML = (Get-ClusterScalingConfigurationFile -ConfigurationFileURL $ConfigurationFileURL)


$ClusterSubscription = $ConfigurationXML.ClusterConfiguration.SubscriptionName
$ClusterResourceGroup = $ConfigurationXML.ClusterConfiguration.ResourceGroupName
$ClusterName = $ConfigurationXML.ClusterConfiguration.ClusterName
$ClusterMinWorkers = [int] $ConfigurationXML.ClusterConfiguration.MinWorkers
$ClusterMaxWorkers = [int] $ConfigurationXML.ClusterConfiguration.MaxWorkers
$EmailRecipients = $ConfigurationXML.ClusterConfiguration.Notify -split ','

If($EmailRecipients -eq $null)
{
    $EmailRecipients = @('default@acme.com')
}

$ConfigurationInfo = (@'

Subscription: {0}
Cluster Name: {1}
Resource Group: {2}
Minimum Worker Nodes: {3} 
Maximum Worker Nodes: {4}
'@ -f $ClusterSubscription, $ClusterName, $ClusterResourceGroup, $ClusterMinWorkers, $ClusterMaxWorkers)

Write-Output -InputObject $ConfigurationInfo

# Check that the subscription name is valid / accessible
try
{
  Set-AzureRmContext -SubscriptionName $ClusterSubscription -ErrorAction Stop
}
catch 
{
  $Message = "The specified subscription $ClusterSubscription was not found. Please verify that it exists in this tenant and that you have permissions to access it."
  Send-EmailAlert -EmailProvider SendGrid -Message $Message -EmailRecipients $EmailRecipients
  Write-Error $Message
}

# Check the current number of nodes in the cluster

$HDInsightClusterDetails = Get-AzureRmHDInsightCluster | Where-Object {
  $_.Name -eq $ClusterName 
}
$ClusterSpec = Get-AzureRmResource -ResourceId $HDInsightClusterDetails.Id |
Select-Object -ExpandProperty Properties |
Select-Object -ExpandProperty computeProfile
#$ClusterSpec.roles
 
$WorkerNodeSpec = $ClusterSpec.roles | Where-Object {
  $_.name -eq 'workernode' 
}
$WorkerNodeRole = Get-AzureRoleSize | Where-Object {
  $_.InstanceSize -eq $WorkerNodeSpec.hardwareProfile.vmSize 
}

$HeadNodeSpec = $ClusterSpec.roles | Where-Object {
  $_.name -eq 'headnode' 
}
$HeadNodeRole = Get-AzureRoleSize | Where-Object {
  $_.InstanceSize -eq $WorkerNodeSpec.hardwareProfile.vmSize 
}
$HeadNodeInstanceCount = $HeadNodeSpec.targetInstanceCount

# There may be more than one spec for edge nodes
# $EdgeNodeSpec = $ClusterSpec.roles | ? { $_.name -like "edgenode*" }
# $EdgeNodeRole = Get-AzureRoleSize | ? { $_.InstanceSize -eq  $WorkerNodeSpec.hardwareProfile.vmSize }


# Default limit is 48 cores per https://docs.microsoft.com/en-us/azure/azure-subscription-service-limits
$QuotaInfo = Get-HDInsightQuota -Location $HDInsightClusterDetails.Location 

$CurrentWorkerNodeInstanceCount = [int] $WorkerNodeSpec.targetInstanceCount

$Message = (@'

Cluster currently consists of:
 {0} x {1} worker nodes with {2} cores each.
 {3} x {4} worker nodes with {5} cores each.
 Total cores used: {6}.
 Total core quota: {7}.
'@ -f $CurrentWorkerNodeInstanceCount, $WorkerNodeSpec.hardwareProfile.vmSize, $WorkerNodeRole.Cores, $HeadNodeInstanceCount, $HeadNodeSpec.hardwareProfile.vmSize, $HeadNodeRole.Cores, $HDInsightClusterDetails.CoresUsed, ($QuotaInfo['CoresAvailable']))

Write-Output $Message

#$HDInsightClusterDetails.CoresUsed

If( $ScaleOperation -eq 'ScaleOut' )
{
  If( $CurrentWorkerNodeInstanceCount -lt $ClusterMaxWorkers )
  {
    $TotalCoresAfterScaling = ( $HeadNodeInstanceCount * $HeadNodeRole.Cores ) + ( $ClusterMaxWorkers * $WorkerNodeRole.Cores )
    Write-Output "Total cluster cores after scaling $TotalCoresAfterScaling."
    If( $TotalCoresAfterScaling -gt $QuotaInfo['CoresAvailable'])
    {
      $Message = "Unable to scale the cluster to $ClusterMaxWorkers nodes, this operation will exceed the subscription quota."
      Send-EmailAlert -EmailProvider $EmailProvider -Message $Message -EmailRecipients $EmailRecipients 
      Write-Error $Message
    }
    Else
    {
      If( $Script:Test )
      {
        $Message = "TEST MODE: scaling operation will NOT be performed, but the cluster would have been scaled out to $ClusterMaxWorkers"          
        Send-EmailAlert -EmailProvider $EmailProvider -Message $Message -EmailRecipients $EmailRecipients
        Write-Output ''          
      }
      Else
      {
        $Message = "Scaling cluster out to $ClusterMaxWorkers nodes."
          
        Write-Output $Message
        Set-AzureRmHDInsightClusterSize -ClusterName $ClusterName -TargetInstanceCount $ClusterMaxWorkers -ResourceGroupName $ClusterResourceGroup
      }
    }
  }
  Else
  {
    $Message = "Cannot scale the cluster out further, the current instance count of $CurrentWorkerNodeInstanceCount nodes, is already at the maximum specified in the XML configuration ($ClusterMaxWorkers)."
    Send-EmailAlert -EmailProvider $EmailProvider -Message $Message -EmailRecipients $EmailRecipients
    Write-Error $Message 
  }
}
ElseIf( $ScaleOperation -eq 'ScaleIn' )
{
  If( $CurrentWorkerNodeInstanceCount -gt $ClusterMinWorkers )
  {
    If( $Script:Test )
    {
      $Message = "TEST MODE: scaling operation will NOT be performed, but the cluster would have been scaled in (reduced in size) to $ClusterMinWorkers"          
      Send-EmailAlert -EmailProvider $EmailProvider -Message $Message -EmailRecipients $EmailRecipients
      Write-Output ''          
    }
    Else
    {
      $Message = "Scaling cluster in - reducing the number of nodes to $ClusterMinWorkers."
      Send-EmailAlert -EmailProvider $EmailProvider -Message $Message -EmailRecipients $EmailRecipients
      Write-Output $Message
      Set-AzureRmHDInsightClusterSize -ClusterName $ClusterName -TargetInstanceCount $ClusterMinWorkers -ResourceGroupName $ClusterResourceGroup
    }
  }
  Else
  {
    $Message = "Cannot scale the cluster, as the cluster only consists of $CurrentWorkerNodeInstanceCount nodes."
    Send-EmailAlert -EmailProvider $EmailProvider -Message $Message -EmailRecipients $EmailRecipients
    Write-Error $Message
  }    
}

#endregion
