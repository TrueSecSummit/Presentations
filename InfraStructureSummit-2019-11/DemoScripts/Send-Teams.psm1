<#	
	===========================================================================
	 Created with: 	Visual Studio Code
	 Created on:   	05/09/2018 11:13 AM
	 Created by:   	Jordan Benzing
	 Organization: 	Problem Resolution
	 Filename:     	UpdateADR.Ps1
	-------------------------------------------------------------------------
	 Script Name: Update ADR
	===========================================================================
#>


function Get-CMModule
{
    Try
    {
        Write-Verbose -Message "Attempting to import SCCM Module"
        Import-Module (Join-Path $(Split-Path $ENV:SMS_ADMIN_UI_PATH) ConfigurationManager.psd1)
    }
    Catch
    {
        Throw "Failure to import SCCM Cmdlets."
    } 
}



function Get-ADRInfo
{
    [CMdletbinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        [string]$ADRName,
        [Parameter(Mandatory = $true)]
		[string]$SiteCode
    )
    try 
    {
        $Namespace = "root/sms/site_" + $siteCode
        [wmi]$ADR = (Get-WmiObject -Class SMS_AutoDeployment -Namespace $Namespace | Where-Object -FilterScript {$_.Name -eq $ADRName}).__PATH
        return $ADR 
    }
    catch 
    {
        throw 'Failed to Get ADRInfo'
    }
} 

function Set-ADRDeploymentPackage
{
    [CMdletbinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        [wmi]$ADRObject,
        [Parameter(Mandatory = $true)]
        [string]$PackageID
        
    )
    try {
        [xml]$ContentTemplateXML = $ADRObject.ContentTemplate
        $ContentTemplateXML.ContentActionXML.PackageID = $PackageID
        $ADRObject.ContentTemplate = $ContentTemplateXML.OuterXml
        $ADRObject.Put() | Out-Null
        Write-Verbose "Succesfully commited updated PackageID"
    }
    catch {
        throw "Something went wrong setting the value"
    }

}

function New-ADRDeploymentPackage
{
    [CMdletbinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        [String]$PackageName,
        [Parameter(Mandatory = $true)]
        [String]$Path,
        [Parameter(Mandatory = $true)]
        [String]$Description
    )
    if(Test-Module -ModuleName ConfigurationManager)
    {
        write-Verbose "ConfigurationManager Module is loaded"
        Write-Verbose "Checking if current drive is a CMDrive"
        if((Get-location).Path -ne (Get-location -PSProvider 'CmSite').Path){throw "You are not currently connected to a CMSite Provider Please Connect and try again"}
        write-Verbose "Succesfully validated connection to a CMProvider"
        $PSFriendlyNetworkPath = "FileSystem::" + $Path
        If(Test-path -path $PSFriendlyNetworkPath)
        {
            write-Verbose "Path Exists continue on"
        }
        else
        {
            try
            {
                write-Verbose "Path Does not Exist attempting to create"
                new-item -ItemType Directory -ErrorAction Stop -path $PSFriendlyNetworkPath | out-Null
                write-Verbose "Create new folder for content to exist in"
            }
            catch
            {
                throw "Could not create directory for the new pacakge."
            }
        }
        $PackageName = [String](Get-Date).Year + " - " + [string](Get-Culture).DateTimeFormat.GetMonthName((Get-Date).Month) + " - $PackageName" 
        Try 
            {
                Write-Verbose "Attempting to create new package in ConfigMgr"
                $NewPackageID = New-CMSoftwareUpdateDeploymentPackage -Name $PackageName -Description $Description -Path $Path -verbose:$false
                write-Verbose "Package created succesfully"
                return $NewPackageID.PackageID
            }
        catch
            {
                Throw "The Package likely already exists please troubleshoot the existing package."
            }

    }
}

function Send-TeamsMessage 
{    
    [CMdletbinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        [string]$url,
        [Parameter(Mandatory = $false)]
        [array]$UpdateList
    )
    write-verbose "Generating HASH table with list of updates" 
    $HashArray = @()
    #Create Hash Array for presentation of information. 
    Foreach ($Update in $UpdateList)
    {
        $Hash = @{
            Name = ''
            Value = ''
        }
        #Assign the value to be the localized display name or title of the update.
        $Hash.Name = $Update.ArticleID
        #makes the the .NAME field become the article ID in the hash table.
        #Create the merged information to make link clicable.
        $UpateInfo = '[' + $Update.LocalizedDisplayName + '](' +$Update.LocalizedInformativeURL + ')'
        $Hash.Value = $UpateInfo
        #$Update.LocalizedInformativeURL
        #adds the value (Display name to the row in the hash)
        #Add hash to hash array
        $HashArray += $Hash
    }
    write-verbose "Completed creation of HASH now converting to JSON and sending to teams."
    $body = ConvertTo-Json -Depth 4 @{
        title    = "The following updates are slated for deployment"
        #Modify as desired for the Title of the message
        text   = "Please review the below updates"
        #Subsection Message modify as desired for the subtitle of the message.
        sections = @(
          @{
            facts = $HashArray
            #post the hash array value as the facts of the update for the section.
          }
        )
      }
      $Results = Invoke-RestMethod -uri $url -Method Post -body $body -ContentType 'application/json' -ErrorAction Stop
      #Capture the response from the webURL if 1 then succesfully sent.
      if($Results -eq 1)
      {
          write-verbose "Succesfully send list of updates to teams"
      }
      if($Results -ne 1)
      {
          write-verbose "The message was not sent"
      }
}

function Send-CMContent
{
    [CMdletbinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        [string]$PackageID,
        [Parameter(Mandatory = $false)]
        [string]$DPName,
        [Parameter(Mandatory = $false)]
        [string]$DPGroupName
    )
    if($DPGroupName -and $DPName -eq $false)
    {
        throw "You must choose either DPName or DPGroupName to have content replicated to"
    }
    if($DPGroupName -and $DPName)
    {
        throw "You must chose either DPname OR DpGroupName to have content replicated to you cannot do both"
    }
    try
    {
        if($DPGroupName)
        {
            Get-CMDisttributionPointGroup -DistributionPointGroupName $DPGroupName -ErrorAction Stop
            start-CMContentDistribution -DistributionPointGroupName $DpGroupName -DeploymentPackageID $PackageID -ErrorAction Stop
            write-verbose "Package Was succesfully added to the distribution point group."
        }
        if($DPName)
        {
            write-verbose "Getting or confirming FQDN of site server with DP Role installed"
            $DPName = Get-CMSite | Select-Object ServerName | Where-Object{$_.Servername -match $DPName}
            if($DPName.Servername)
            {
                write-verbose "Validating the DP Role is installed on the server"
                Get-CMDistributionPoint -SiteSystemServerName $DPName.Servername -ErrorAction Stop
                write-verbose "Distribution Point is Installed on this Server "
            }
            start-CMContentDistribution -DistributionPointName $DpName.Servername -DeploymentPackageID $PackageID -ErrorAction Stop
            write-verbose "Package was succesfully added to the distribution point, see distrmgr.log for content status."
        }
    }
    catch
    {
        Throw "Something went wrong with sending the content to the distribution point."
    }
}

function Test-ConfigMgrAvailable
{
    [CMdletbinding()]
    Param
    (

    )
        try
        {
            if((Test-Module -ModuleName ConfigurationManager) -eq $false){throw "You have not loaded the configuration manager module please load the appropriate module and try again."}
            write-Verbose "ConfigurationManager Module is loaded"
            Write-Verbose "Checking if current drive is a CMDrive"
            if((Get-location).Path -ne (Get-location -PSProvider 'CmSite').Path){throw "You are not currently connected to a CMSite Provider Please Connect and try again"}
            write-Verbose "Succesfully validated connection to a CMProvider"
            write-verbose "Passed all connection tests"
            return $true
        }
        catch
        {
            $errorMessage = $_.Exception.Message
            write-error -Exception CMPatching -Message $errorMessage
            return $false
        }
}
function Test-Module
{
    [CMdletbinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        [String]$ModuleName
    )
    If(Get-Module -Name $ModuleName)
    {
        return $true
    }
    If((Get-Module -Name $ModuleName) -ne $true)
    {
        return $false
    }
}

function Get-CMUpdatesinGroup
{
        [CMdletbinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        [string]$SUGName
    )
    if(Test-ConfigMgrAvailable)
    {
        try
        {
            write-verbose "The ConfigMgr Cmdlet Library is present retrieving CI_ID of SUG"
            $SugInfo = Get-CMSoftwareUpdateGroup -Name $SUGName -verbose:$false | Select-Object -ExpandProperty CI_ID
            write-verbose "Retrieved the CI_ID of the SUG $SugName the CI_ID is $SugInfo"
            write-verbose "Attempting to retreive update information"
            $UpdateInfo = Get-CMSoftwareUpdate -UpdateGroupID $SugInfo -fast -verbose:$false | Select-Object articleID,LocalizedInformativeURL,LocalizedDisplayName
            return $UpdateInfo
        }
        catch
        {
            $errorMessage = $_.Exception.Message
            write-error -Exception CMPatching -Message $errorMessage
        }
    }
}