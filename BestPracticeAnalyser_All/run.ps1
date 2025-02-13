param($tenant)

# Prepare tokens, connections and variables that will be used multiple times later
$uri = "https://login.microsoftonline.com/$($Tenant)/oauth2/token"
$body = "resource=https://admin.microsoft.com&grant_type=refresh_token&refresh_token=$($ENV:ExchangeRefreshToken)"
try {
    $token = Invoke-RestMethod $uri -Body $body -ContentType "application/x-www-form-urlencoded" -ErrorAction SilentlyContinue -Method post
    Log-request -API "BestPracticeAnalyser" -tenant $tenant -message "Token retrieved for Best Practice Analyser on $($tenant)" -sev "Info"
}
catch {
    Log-request -API "BestPracticeAnalyser" -tenant $tenant -message "Unable to Retrieve token for Best Practice Analyser $($tenant) Error: $($_.exception.message)" -sev "Error"
}
$upn = "notRequired@required.com"

# Build up the result object that will be passed back to the durable function
$Result = [PSCustomObject]@{
    Tenant                           = $tenant
    GUID                             = $($Tenant.Replace('.', ''))
    LastRefresh                      = $(Get-Date (Get-Date).ToUniversalTime() -UFormat '+%Y-%m-%dT%H:%M:%S.000Z')
    SecureDefaultState               = ""
    PrivacyEnabled                   = ""
    UnifiedAuditLog                  = ""
    MessageCopyForSend               = ""
    MessageCopyForSendAsCount        = ""
    MessageCopyForSendOnBehalfCount  = ""
    MessageCopyForSendList           = ""
    ShowBasicAuthSettings            = ""
    EnableModernAuth                 = ""
    AllowBasicAuthActiveSync         = ""
    AllowBasicAuthImap               = ""
    AllowBasicAuthPop                = ""
    AllowBasicAuthWebServices        = ""
    AllowBasicAuthPowershell         = ""
    AllowBasicAuthAutodiscover       = ""
    AllowBasicAuthMapi               = ""
    AllowBasicAuthOfflineAddressBook = ""
    AllowBasicAuthRpc                = ""
    AllowBasicAuthSmtp               = ""
    AdminConsentForApplications      = ""
    DoNotExpirePasswords             = ""
    SelfServicePasswordReset         = ""
    DisabledSharedMailboxLogins      = ""
    DisabledSharedMailboxLoginsCount = ""
    UnusedLicensesCount              = ""
    UnusedLicensesResult             = ""
    UnusedLicenseList                = ""
}

# Starting the Best Practice Analyser
Log-request -API "BestPracticeAnalyser" -tenant $tenant -message "Started Best Practice Analyser Durable Function on $($tenant)" -sev "Info"

# Get the Secure Default State
try {
    $SecureDefaultsState = (New-GraphGetRequest -Uri "https://graph.microsoft.com/beta/policies/identitySecurityDefaultsEnforcementPolicy" -tenantid $tenant)
    $Result.SecureDefaultState = $SecureDefaultsState.IsEnabled

    Log-request -API "BestPracticeAnalyser" -tenant $tenant -message "Security Defaults State on $($tenant) is $($SecureDefaultsState.IsEnabled)" -sev "Debug"
}
catch {
    Log-request -API "BestPracticeAnalyser" -tenant $tenant -message "Security Defaults State on $($tenant) Error: $($_.exception.message)" -sev "Error"
}


# Get the Privacy Enabled State
try {
    $Result.PrivacyEnabled = Invoke-RestMethod -ContentType "application/json;charset=UTF-8" -Uri 'https://admin.microsoft.com/admin/api/reports/config/GetTenantConfiguration' -Method Get -Headers @{
        Authorization            = "Bearer $($token.access_token)";
        "x-ms-client-request-id" = [guid]::NewGuid().ToString();
        "x-ms-client-session-id" = [guid]::NewGuid().ToString()
        'x-ms-correlation-id'    = [guid]::NewGuid()
        'X-Requested-With'       = 'XMLHttpRequest' 
    } | Select-Object -ExpandProperty Output | ConvertFrom-Json | Select-Object -ExpandProperty PrivacyEnabled
    Log-request -API "BestPracticeAnalyser" -tenant $tenant -message "Privacy Enabled State on $($tenant) is $($Result.PrivacyEnabled)" -sev "Debug"
}
catch {
    Log-request -API "BestPracticeAnalyser" -tenant $tenant -message "Privacy Enabled State on $($tenant) Error: $($_.exception.message)" -sev "Error"
}


# Build up and enter an Exchange PSSession for the next section
try {
    $tokenvalue = ConvertTo-SecureString (Get-GraphToken -AppID 'a0c73c16-a7e3-4564-9a95-2bdf47383716' -RefreshToken $ENV:ExchangeRefreshToken -Scope 'https://outlook.office365.com/.default' -Tenantid $($Tenant)).Authorization -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($upn, $tokenValue)
    $session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri "https://ps.outlook.com/powershell-liveid?DelegatedOrg=$($Tenant)&BasicAuthToOAuthConversion=true" -Credential $credential -Authentication Basic -AllowRedirection -ErrorAction Continue
    Import-PSSession $session -ea Silentlycontinue -AllowClobber -CommandName "Get-Mailbox", "Set-mailbox", "Get-AdminAuditLogConfig", "Get-OrganizationConfig", "Enable-OrganizationCustomization" | Out-Null
    Log-request -API "BestPracticeAnalyser" -tenant $tenant -message "Exchange PS Sesssion Generated on $($tenant) is successful" -sev "Debug"
}
catch {
    Log-request -API "BestPracticeAnalyser" -tenant $tenant -message "Exchange PS Session on $($tenant) Error: $($_.exception.message)" -sev "Error"
}


# Get Send and Send Behalf Of
try {
    # Send and Send Behalf Of
    $MailboxBPA = Get-Mailbox -ResultSize Unlimited -RecipientTypeDetails UserMailbox, SharedMailbox
    $TotalMailboxes = $MailboxBPA | Measure-Object | Select-Object -ExpandProperty Count
    $TotalMessageCopyForSentAsEnabled = $MailboxBPA | Where-Object { $_.MessageCopyForSentAsEnabled -eq $true } | Measure-Object | Select-Object -ExpandProperty Count
    $TotalMessageCopyForSendOnBehalfEnabled = $MailboxBPA | Where-Object { $_.MessageCopyForSendOnBehalfEnabled -eq $true } | Measure-Object | Select-Object -ExpandProperty Count
    If (($TotalMailboxes -eq $TotalMessageCopyForSentAsEnabled) -and ($TotalMailboxes -eq $TotalMessageCopyForSendOnBehalfEnabled)) {
        $Result.MessageCopyForSend = "PASS"
        $Result.MessageCopyForSendAsCount = $TotalMessageCopyForSentAsEnabled
        $Result.MessageCopyForSendOnBehalfCount = $TotalMessageCopyForSendOnBehalfEnabled
    }
    else {
        $Result.MessageCopyForSend = "FAIL"
        $Result.MessageCopyForSendAsCount = $MailboxBPA | Where-Object { $_.MessageCopyForSentAsEnabled -eq $false } | Measure-Object | Select-Object -ExpandProperty Count
        $Result.MessageCopyForSendOnBehalfCount = $MailboxBPA | Where-Object { $_.MessageCopyForSendOnBehalfEnabled -eq $false } | Measure-Object | Select-Object -ExpandProperty Count
        $Result.MessageCopyForSendList = ($MailboxBPA | Where-Object { ($_.MessageCopyForSendOnBehalfEnabled -eq $false) -or ( $_.MessageCopyForSendOnBehalfEnabled -eq $false) } | Select-Object -ExpandProperty userPrincipalName) -join "<br />"
    }
    Log-request -API "BestPracticeAnalyser" -tenant $tenant -message "Send and Send Behalf Of on $($tenant) is $($Result.MessageCopyForSend)" -sev "Debug"
}
catch {
    Log-request -API "BestPracticeAnalyser" -tenant $tenant -message "Send and Send Behalf Of on $($tenant) Error: $($_.exception.message)" -sev "Error"
}


# Get Unified Audit Log
try {
    $Result.UnifiedAuditLog = Get-AdminAuditLogConfig | Select-Object -ExpandProperty UnifiedAuditLogIngestionEnabled
    Log-request -API "BestPracticeAnalyser" -tenant $tenant -message "Unified Audit Log on $($tenant) is $($Result.UnifiedAuditLog)" -sev "Debug"
    
}
catch {
    Log-request -API "BestPracticeAnalyser" -tenant $tenant -message "Unified Audit Log on $($tenant). Error: $($_.exception.message)" -sev "Error"
}


# Important to clean up the remote session
try {
    Get-PSSession | Remove-PSSession
}
catch {
    Log-request -API "BestPracticeAnalyser" -tenant $tenant -message "Error cleaning up PSSession on $($tenant). Error: $($_.exception.message)" -sev "Error"
}


# Get Basic Auth States
try {
    $BasicAuthDisable = Invoke-RestMethod -ContentType "application/json;charset=UTF-8" -Uri 'https://admin.microsoft.com/admin/api/services/apps/modernAuth' -Method GET -Headers @{
        Authorization            = "Bearer $($token.access_token)";
        "x-ms-client-request-id" = [guid]::NewGuid().ToString();
        "x-ms-client-session-id" = [guid]::NewGuid().ToString()
        'x-ms-correlation-id'    = [guid]::NewGuid()
        'X-Requested-With'       = 'XMLHttpRequest' 
    }



    $Result.ShowBasicAuthSettings = $BasicAuthDisable.ShowBasicAuthSettings
    $Result.EnableModernAuth = $BasicAuthDisable.EnableModernAuth
    $Result.AllowBasicAuthActiveSync = $BasicAuthDisable.AllowBasicAuthActiveSync
    $Result.AllowBasicAuthImap = $BasicAuthDisable.AllowBasicAuthImap
    $Result.AllowBasicAuthPop = $BasicAuthDisable.AllowBasicAuthPop
    $Result.AllowBasicAuthWebServices = $BasicAuthDisable.AllowBasicAuthWebServices
    $Result.AllowBasicAuthPowershell = $BasicAuthDisable.AllowBasicAuthPowershell
    $Result.AllowBasicAuthAutodiscover = $BasicAuthDisable.AllowBasicAuthAutodiscover
    $Result.AllowBasicAuthMapi = $BasicAuthDisable.AllowBasicAuthMapi
    $Result.AllowBasicAuthOfflineAddressBook = $BasicAuthDisable.AllowBasicAuthOfflineAddressBook
    $Result.AllowBasicAuthRpc = $BasicAuthDisable.AllowBasicAuthRpc
    $Result.AllowBasicAuthSmtp = $BasicAuthDisable.AllowBasicAuthSmtp
    Log-request -API "BestPracticeAnalyser" -tenant $tenant -message "Basic Auth States on $($tenant) run" -sev "Debug"
}
catch {
    Log-request -API "BestPracticeAnalyser" -tenant $tenant -message "Basic Auth States on $($tenant). Error: $($_.exception.message)" -sev "Error"
}


# Get OAuth Admin Consenst
try {
    $Result.AdminConsentForApplications = Invoke-RestMethod -ContentType "application/json;charset=UTF-8" -Uri 'https://admin.microsoft.com/admin/api/settings/apps/IntegratedApps' -Method GET -Headers @{
        Authorization            = "Bearer $($token.access_token)";
        "x-ms-client-request-id" = [guid]::NewGuid().ToString();
        "x-ms-client-session-id" = [guid]::NewGuid().ToString()
        'x-ms-correlation-id'    = [guid]::NewGuid()
        'X-Requested-With'       = 'XMLHttpRequest' 
    }
    Log-request -API "BestPracticeAnalyser" -tenant $tenant -message "OAuth Admin Consent on $($tenant). Admin Consent for Applications $($Result.AdminConsentForApplications) and password reset is $($Result.SelfServicePasswordReset)" -sev "Debug"
}
catch {
    Log-request -API "BestPracticeAnalyser" -tenant $tenant -message "OAuth Admin Consent on $($tenant). Error: $($_.exception.message)" -sev "Error"   
}

# Get Self Service Password Reset State
try {
    $bodypasswordresetpol = "resource=74658136-14ec-4630-ad9b-26e160ff0fc6&grant_type=refresh_token&refresh_token=$($ENV:ExchangeRefreshToken)"
    $tokensspr = Invoke-RestMethod $uri -Body $bodypasswordresetpol -ContentType "application/x-www-form-urlencoded" -ErrorAction SilentlyContinue -Method post
    $SSPRGraph = Invoke-RestMethod -ContentType "application/json;charset=UTF-8" -Uri 'https://main.iam.ad.ext.azure.com/api/PasswordReset/PasswordResetPolicies' -Method GET -Headers @{
        Authorization            = "Bearer $($tokensspr.access_token)";
        "x-ms-client-request-id" = [guid]::NewGuid().ToString();
        "x-ms-client-session-id" = [guid]::NewGuid().ToString()
        'x-ms-correlation-id'    = [guid]::NewGuid()
        'X-Requested-With'       = 'XMLHttpRequest' 
    }
    If ($SSPRGraph.enablementType -eq 0) { $Result.SelfServicePasswordReset = "Off" }
    If ($SSPRGraph.enablementType -eq 1) { $Result.SelfServicePasswordReset = "Specific Users" }
    If ($SSPRGraph.enablementType -eq 2) { $Result.SelfServicePasswordReset = "On" }
    If ([string]::IsNullOrEmpty($SSPRGraph.enablementType)) { $Result.SelfServicePasswordReset = "Unknown" }
    Log-request -API "BestPracticeAnalyser" -tenant $tenant -message "Basic Self Service Password State on $($tenant) is $($Result.SelfServicePasswordReset) run" -sev "Debug"
}
catch {
    Log-request -API "BestPracticeAnalyser" -tenant $tenant -message "Self Service Password Reset on $($tenant). Error: $($_.exception.message)" -sev "Error" 
}

# Get Passwords set to Never Expire
try {
    $Result.DoNotExpirePasswords = Invoke-RestMethod -ContentType "application/json; charset=utf-8" -Uri 'https://admin.microsoft.com/admin/api/Settings/security/passwordpolicy' -Method GET -Headers @{Authorization = "Bearer $($token.access_token)"; "x-ms-client-request-id" = [guid]::NewGuid().ToString(); "x-ms-client-session-id" = [guid]::NewGuid().ToString(); 'X-Requested-With' = 'XMLHttpRequest'; 'x-ms-correlation-id' = [guid]::NewGuid() } | Select-Object -ExpandProperty NeverExpire
    Log-request -API "BestPracticeAnalyser" -tenant $tenant -message "Passwords never expire setting on $($tenant). $($Result.DoNotExpirePasswords)" -sev "Debug"
}
catch {
    Log-request -API "BestPracticeAnalyser" -tenant $tenant -message "Passwords never expire setting on $($tenant). Error: $($_.exception.message)" -sev "Error" 
}


# Get Shared Mailbox Stuff
try {
    $SharedMailboxList = (New-GraphGetRequest -uri "https://outlook.office365.com/adminapi/beta/$($tenant)/Mailbox" -Tenantid $tenant -scope ExchangeOnline | Where-Object -propert RecipientTypeDetails -EQ "SharedMailbox")
    $AllUsersAccountState = New-GraphGetRequest -uri "https://graph.microsoft.com/beta/users?select=userPrincipalName,accountEnabled" -tenantid $Tenant
    $EnabledUsersWithSharedMailbox = foreach ($SharedMailbox in $SharedMailboxList) {
        # Match the User
        $User = $AllUsersAccountState | Where-Object { $_.userPrincipalName -eq $SharedMailbox.userPrincipalName } | Select-Object -First 1
        if ($User.accountEnabled) {
            $User.userPrincipalName
        }
    }
    
    if (($EnabledUsersWithSharedMailbox | Measure-Object | Select-Object -ExpandProperty Count) -gt 0) { $Result.DisabledSharedMailboxLogins = ($EnabledUsersWithSharedMailbox) -join "<br />" } else { $Result.DisabledSharedMailboxLogins = "PASS" } 
    $Result.DisabledSharedMailboxLoginsCount = $EnabledUsersWithSharedMailbox | Measure-Object | Select-Object -ExpandProperty Count
    Log-request -API "BestPracticeAnalyser" -tenant $tenant -message "Shared Mailbox Enabled Accounts on $($tenant). $($Result.DisabledSharedMailboxLogins)" -sev "Debug"
}
catch {
    Log-request -API "BestPracticeAnalyser" -tenant $tenant -message "Shared Mailbox Enabled Accounts on $($tenant). Error: $($_.exception.message)" -sev "Error"  
}

# Get unused Licenses
try {
    $LicenseUsage = Invoke-RestMethod -ContentType "application/json;charset=UTF-8" -Uri 'https://portal.office.com/admin/api/tenant/accountSkus' -Method GET -Headers @{
        Authorization            = "Bearer $($token.access_token)";
        "x-ms-client-request-id" = [guid]::NewGuid().ToString();
        "x-ms-client-session-id" = [guid]::NewGuid().ToString()
        'x-ms-correlation-id'    = [guid]::NewGuid()
        'X-Requested-With'       = 'XMLHttpRequest' 
    }

    $WhiteListedSKUs = "FLOW_FREE", "TEAMS_EXPLORATORY", "TEAMS_COMMERCIAL_TRIAL", "POWERAPPS_VIRAL", "POWER_BI_STANDARD", "DYN365_ENTERPRISE_P1_IW"
    $UnusedLicenses = $LicenseUsage | Where-Object { ($_.Purchased -ne $_.Consumed) -and ($WhiteListedSKUs -notcontains $_.AccountSkuId.SkuPartNumber) }
    $UnusedLicensesCount = $UnusedLicenses | Measure-Object | Select-Object -ExpandProperty Count
    $UnusedLicensesResult = if ($UnusedLicensesCount -gt 0) { "FAIL" } else { "PASS" }
    $Result.UnusedLicenseList = ($UnusedLicensesListBuilder = foreach ($License in $UnusedLicenses) {
            "SKU: $($License.AccountSkuId.SkuPartNumber), Purchased: $($License.Purchased), Consumed: $($License.Consumed)"
        }) -join "<br />"
    $Result.UnusedLicensesCount = $UnusedLicensesCount
    $Result.UnusedLicensesResult = $UnusedLicensesResult
    Log-request -API "BestPracticeAnalyser" -tenant $tenant -message "Unused Licenses on $($tenant). $($Result.UnusedLicensesCount) total not matching" -sev "Debug"
}
catch {
    Log-request -API "BestPracticeAnalyser" -tenant $tenant -message "Unused Licenses on $($tenant). Error: $($_.exception.message)" -sev "Error"
}


# Send Output of all the Results to the Stream
$Result