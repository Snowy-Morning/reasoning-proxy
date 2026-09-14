# Shared logic for the "sync models" button in proxy-gui.ps1.
# Deliberately free of WPF types so it can be exercised on its own, and written
# to behave the same under Windows PowerShell 5.1 and PowerShell 7.

# The only file this tool writes: VS Code's own chat model registry. An explicit
# LM_CONFIG_PATH still wins, which covers portable installs and test sandboxes.
function Select-LmTargetPaths {
    param(
        [string]$ConfigPath
    )

    if ($ConfigPath) {
        return ,@([System.IO.Path]::GetFullPath($ConfigPath))
    }
    if ($env:APPDATA) {
        return ,@((Join-Path $env:APPDATA 'Code\User\chatLanguageModels.json'))
    }
    return ,@()
}

# ...\AppData\Roaming\Code\User\chatLanguageModels.json -> "Code"
function Split-LmEditorLabel([string]$Path) {
    try {
        $userDir = Split-Path -Parent $Path
        $editorDir = Split-Path -Parent $userDir
        $label = Split-Path -Leaf $editorDir
        if ($label) {
            return $label
        }
    } catch {}
    return $Path
}

# Where a backup for $Path belongs. Writing it next to the editor's own config
# would leave our litter in someone else's folder, so the default root is this
# tool's own directory and --uninstall clears it with everything else. An empty
# result means "nowhere better to go", and the caller keeps the old sibling copy.
function Resolve-LmBackupDir {
    param(
        [string]$Path,
        [string]$Root
    )

    if (-not $Root) {
        if (-not $env:LOCALAPPDATA) {
            return ''
        }
        $Root = Join-Path $env:LOCALAPPDATA 'ReasoningProxy\backups'
    }

    try {
        $full = [System.IO.Path]::GetFullPath($Path)
    } catch {
        $full = $Path
    }

    $label = [string](Split-LmEditorLabel $full)
    if (-not $label -or $label -eq $full) {
        $label = Split-Path -Leaf (Split-Path -Parent $full)
    }
    $label = (($label -replace '[^\w.-]', '_') -replace '^[._]+', '')
    if (-not $label) {
        $label = 'target'
    }

    # The digest keeps two installs that happen to share a folder name from writing
    # into one pile, and doubles as the record of which targets were ever synced.
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = ([System.BitConverter]::ToString(
            $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($full))
        )).Replace('-', '').Substring(0, 8).ToLowerInvariant()
        return [System.IO.Path]::GetFullPath((Join-Path $Root ($label + '-' + $digest)))
    } catch {
        return ''
    } finally {
        $sha.Dispose()
    }
}

# Union of every model id already configured in the given files, so the picker can
# tell "would be added" apart from "already there".
function Get-LmExistingIdSet {
    param([string[]]$Paths)

    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($Paths)) {
        if (-not $path -or -not (Test-Path -LiteralPath $path)) {
            continue
        }
        try {
            $parsed = Read-LmJsonFile $path
            if ($null -eq $parsed) {
                continue
            }
            $isList = $parsed -is [System.Array]
            if (-not $isList -and $parsed -is [System.Management.Automation.PSCustomObject]) {
                $isList = @($parsed.PSObject.Properties.Name) -contains 'models'
            }
            if (-not $isList) {
                continue
            }
            foreach ($id in (Get-LmKnownIdSet -Providers (Get-LmFlatArray $parsed))) {
                [void]$set.Add([string]$id)
            }
        } catch {}
    }
    return ,$set
}

function ConvertTo-LmJsonStringLiteral([string]$Value) {
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    foreach ($char in $Value.ToCharArray()) {
        $code = [int]$char
        if ($char -eq '"') {
            [void]$builder.Append('\"')
        } elseif ($char -eq '\') {
            [void]$builder.Append('\\')
        } elseif ($char -eq "`b") {
            [void]$builder.Append('\b')
        } elseif ($char -eq "`f") {
            [void]$builder.Append('\f')
        } elseif ($char -eq "`n") {
            [void]$builder.Append('\n')
        } elseif ($char -eq "`r") {
            [void]$builder.Append('\r')
        } elseif ($char -eq "`t") {
            [void]$builder.Append('\t')
        } elseif ($code -lt 32) {
            [void]$builder.Append('\u')
            [void]$builder.Append($code.ToString('x4'))
        } else {
            [void]$builder.Append($char)
        }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-LmJsonNumberLiteral([object]$Value) {
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        $number = [double]$Value
        if ([math]::Abs($number - [math]::Truncate($number)) -lt 1e-9) {
            return ([long]$number).ToString($culture)
        }
        return $number.ToString('R', $culture)
    }
    return [Convert]::ToInt64($Value, $culture).ToString($culture)
}

# ConvertTo-Json differs between PowerShell versions (5.1 wraps top level arrays
# and indents them oddly), so the payload is written by hand: 2-space indent,
# original key order, no BOM.
function ConvertTo-LmJson {
    param(
        [object]$Value,
        [int]$Indent = 0
    )

    $pad = ' ' * $Indent
    $innerPad = ' ' * ($Indent + 2)

    if ($null -eq $Value) {
        return 'null'
    }
    if ($Value -is [bool]) {
        return $(if ($Value) { 'true' } else { 'false' })
    }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [long] -or
        $Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        return ConvertTo-LmJsonNumberLiteral $Value
    }
    if ($Value -is [string]) {
        return ConvertTo-LmJsonStringLiteral ([string]$Value)
    }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Count -eq 0) {
            return '{}'
        }
        $lines = @()
        foreach ($key in $Value.Keys) {
            $child = ConvertTo-LmJson -Value $Value[$key] -Indent ($Indent + 2)
            $lines += "$innerPad$(ConvertTo-LmJsonStringLiteral ([string]$key)): $child"
        }
        return "{`n$($lines -join ",`n")`n$pad}"
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $names = @($Value.PSObject.Properties.Name)
        if ($names.Count -eq 0) {
            return '{}'
        }
        $lines = @()
        foreach ($name in $names) {
            $child = ConvertTo-LmJson -Value $Value.$name -Indent ($Indent + 2)
            $lines += "$innerPad$(ConvertTo-LmJsonStringLiteral $name): $child"
        }
        return "{`n$($lines -join ",`n")`n$pad}"
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value)
        if ($items.Count -eq 0) {
            return '[]'
        }
        $lines = @()
        foreach ($item in $items) {
            $lines += "$innerPad$(ConvertTo-LmJson -Value $item -Indent ($Indent + 2))"
        }
        return "[`n$($lines -join ",`n")`n$pad]"
    }

    return ConvertTo-LmJsonStringLiteral ([string]$Value)
}

function Read-LmJsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    $raw = [System.IO.File]::ReadAllText($Path)
    if (-not $raw -or -not $raw.Trim()) {
        return $null
    }
    $parsed = ConvertFrom-Json -InputObject $raw
    # The comma keeps the value intact: without it PowerShell unrolls a
    # single-element JSON array into a bare object on the way out.
    return ,$parsed
}

# A JSON array read by ConvertFrom-Json can arrive as Object[], as a nested
# Object[], or as one bare object depending on how it was passed around.
# Callers that walk providers and models always want a flat Object[].
function Get-LmFlatArray([object]$Value) {
    $items = New-Object System.Collections.ArrayList
    if ($null -ne $Value) {
        if ($Value -is [System.Array]) {
            foreach ($item in $Value) {
                $nested = Get-LmFlatArray $item
                foreach ($inner in $nested) {
                    [void]$items.Add($inner)
                }
            }
        } else {
            [void]$items.Add($Value)
        }
    }
    return ,$items.ToArray()
}

function Write-LmJsonFile {
    param(
        [string]$Path,
        [object]$Value,
        # Backup names carry a second resolution, so an unattended autosync can
        # otherwise leave one file per run forever. Zero or less keeps everything.
        [int]$KeepBackups = 10,
        # Empty selects the default root under %LOCALAPPDATA%\ReasoningProxy.
        [string]$BackupRoot = ''
    )

    $json = ConvertTo-LmJson $Value
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $fileName = [System.IO.Path]::GetFileName($Path)
    $backupDir = Resolve-LmBackupDir -Path $Path -Root $BackupRoot
    if (-not $backupDir) {
        $backupDir = $parent
    }

    $backupPath = $null
    if (Test-Path -LiteralPath $Path) {
        $original = [System.IO.File]::ReadAllText($Path)
        # VS Code writes this file without a trailing newline; keep that cue.
        if ($original -and $original.EndsWith("`n")) {
            $json += "`n"
        }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        if ($backupDir -and -not (Test-Path -LiteralPath $backupDir)) {
            New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
        }
        $backupPath = Join-Path $backupDir ($fileName + '.bak-' + $stamp)
        Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    } else {
        $json += "`n"
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $encoding)

    if ($KeepBackups -gt 0 -and $backupDir -and (Test-Path -LiteralPath $backupDir)) {
        # Match on this file's own name plus the exact stamp we write, so a folder
        # holding several targets never loses something that is not ours.
        $prefix = $fileName + '.bak-'
        try {
            $staleBackups = @(Get-ChildItem -LiteralPath $backupDir -File -Force |
                Where-Object {
                    $_.Name.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) -and
                    $_.Name.Substring($prefix.Length) -match '^\d{8}-\d{6}$'
                } |
                Sort-Object Name -Descending |
                Select-Object -Skip $KeepBackups)
            foreach ($old in $staleBackups) {
                try { Remove-Item -LiteralPath $old.FullName -Force -ErrorAction Stop } catch {}
            }
        } catch {}
    }

    return $backupPath
}

# Accept the proxy envelope, an OpenAI style {data:[{id}]}, or a bare id array.
function Get-LmModelIds([object]$Payload) {
    $source = $Payload
    while ($source -is [System.Management.Automation.PSCustomObject]) {
        $names = @($source.PSObject.Properties.Name)
        if ($names -contains 'models') {
            $source = $source.models
        } elseif ($names -contains 'data') {
            $source = $source.data
        } elseif ($names -contains 'list') {
            $source = $source.list
        } else {
            $source = @($source)
        }
    }

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $ids = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in (Get-LmFlatArray $source)) {
        if ($null -eq $item) {
            continue
        }
        $value = $null
        if ($item -is [string]) {
            $value = $item
        } elseif ($item -is [System.Management.Automation.PSCustomObject] -and @($item.PSObject.Properties.Name) -contains 'id') {
            $value = [string]$item.id
        } elseif ($item -is [System.Management.Automation.PSCustomObject]) {
            continue
        } else {
            $value = [string]::Format($culture, '{0}', $item)
        }
        $value = ([string]$value).Trim()
        if ($value -and $seen.Add($value)) {
            [void]$ids.Add($value)
        }
    }
    return ,$ids.ToArray()
}

function Split-LmList([string]$Value) {
    if (-not $Value) {
        return ,@()
    }
    return ,@($Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-LmMatchAnyPattern {
    param(
        [string]$Id,
        [string[]]$Patterns
    )
    foreach ($pattern in @($Patterns)) {
        if ($pattern -and $Id.IndexOf($pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }
    return $false
}

function New-LmModelEntry {
    param(
        [string]$Id,
        [string]$Url,
        [int]$MaxInputTokens,
        [int]$MaxOutputTokens,
        [bool]$ToolCalling,
        [bool]$Vision
    )
    $entry = [ordered]@{}
    $entry['id'] = $Id
    $entry['name'] = $Id
    $entry['url'] = $Url
    $entry['toolCalling'] = $ToolCalling
    $entry['vision'] = $Vision
    $entry['maxInputTokens'] = $MaxInputTokens
    $entry['maxOutputTokens'] = $MaxOutputTokens
    return ,$entry
}

# "1M" / "200K" / "1000000" / "" -> token count. Empty keeps the fallback.
function ConvertFrom-LmTokenSize {
    param(
        [string]$Text,
        [int]$Fallback
    )
    $value = ([string]$Text).Trim().ToLowerInvariant()
    if (-not $value) {
        return $Fallback
    }
    if ($value -match '^([0-9]+(?:\.[0-9]+)?)k$') {
        return [int]([double]$Matches[1] * 1000)
    }
    if ($value -match '^([0-9]+(?:\.[0-9]+)?)m$') {
        return [int]([double]$Matches[1] * 1000000)
    }
    if ($value -match '^[0-9]+$') {
        return [int]$value
    }
    return $Fallback
}

# 256000 -> "256K", 1000000 -> "1M". Used only for display in the picker.
function Format-LmTokenSize([int]$Tokens) {
    if ($Tokens -le 0) {
        return ''
    }
    if (($Tokens % 1000000) -eq 0) {
        return "$([int]($Tokens / 1000000))M"
    }
    if (($Tokens % 1000) -eq 0) {
        return "$([int]($Tokens / 1000))K"
    }
    return [string]$Tokens
}

# LM_MODEL_CONTEXT="claude=1M,gpt-6=1M" -> ordered @{ Pattern; Tokens } rows.
# The upstream /v1/models payload carries no context metadata at all, so this is
# the one place where a real per-family number can come from without guessing.
function Get-LmContextHints {
    param([string]$Value)

    $hints = New-Object System.Collections.ArrayList
    foreach ($pair in (Split-LmList $Value)) {
        $index = $pair.IndexOf('=')
        if ($index -lt 1) {
            continue
        }
        $pattern = $pair.Substring(0, $index).Trim().ToLowerInvariant()
        if (-not $pattern) {
            continue
        }
        $tokens = ConvertFrom-LmTokenSize -Text $pair.Substring($index + 1) -Fallback 0
        if ($tokens -gt 0) {
            [void]$hints.Add([pscustomobject]@{ Pattern = $pattern; Tokens = $tokens })
        }
    }
    return ,$hints.ToArray()
}

# First match wins, so a specific family can be listed before a broad one.
function Resolve-LmContextHint {
    param(
        [object[]]$Hints,
        [string]$Id
    )

    $needle = ([string]$Id).ToLowerInvariant()
    foreach ($hint in (Get-LmFlatArray $Hints)) {
        if ($needle.Contains([string]$hint.Pattern)) {
            return [int]$hint.Tokens
        }
    }
    return 0
}

# Read back what each editor already configured, so the picker can show a real
# context window and image setting instead of the global defaults.
function Get-LmModelCatalog {
    param([string[]]$Paths)

    $catalog = @{}
    foreach ($path in @($Paths)) {
        if (-not $path -or -not (Test-Path -LiteralPath $path)) {
            continue
        }
        try {
            $parsed = Read-LmJsonFile $path
            if ($null -eq $parsed) {
                continue
            }
            $isList = $parsed -is [System.Array]
            if (-not $isList -and $parsed -is [System.Management.Automation.PSCustomObject]) {
                $isList = @($parsed.PSObject.Properties.Name) -contains 'models'
            }
            if (-not $isList) {
                continue
            }
        } catch {
            continue
        }

        $editor = Split-LmEditorLabel $path
        foreach ($provider in (Get-LmFlatArray $parsed)) {
            foreach ($model in (Get-LmFlatArray (Get-LmModelProperty $provider 'models'))) {
                $id = ([string](Get-LmModelProperty $model 'id')).Trim()
                if (-not $id -or $catalog.ContainsKey($id)) {
                    continue
                }
                $catalog[$id] = [pscustomobject]@{
                    MaxInputTokens = [int](Get-LmModelProperty $model 'maxInputTokens')
                    Vision = [bool](Get-LmModelProperty $model 'vision')
                    ToolCalling = [bool](Get-LmModelProperty $model 'toolCalling')
                    Editor = $editor
                }
            }
        }
    }
    return $catalog
}

function Get-LmModelProperty([object]$Object, [string]$Name) {
    if ($null -eq $Object) {
        return $null
    }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }
        return $null
    }
    if (@($Object.PSObject.Properties.Name) -contains $Name) {
        return $Object.$Name
    }
    return $null
}

function Set-LmModelProperty([object]$Object, [string]$Name, [object]$Value) {
    if ($Object -is [System.Collections.IDictionary]) {
        $Object[$Name] = $Value
        return
    }
    if (@($Object.PSObject.Properties.Name) -contains $Name) {
        $Object.$Name = $Value
        return
    }
    $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
}

function Get-LmKnownIdSet([object[]]$Providers) {
    $ids = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($provider in (Get-LmFlatArray $Providers)) {
        foreach ($model in (Get-LmFlatArray (Get-LmModelProperty $provider 'models'))) {
            $id = ([string](Get-LmModelProperty $model 'id')).Trim()
            if ($id) {
                [void]$ids.Add($id)
            }
        }
    }
    # Comma keeps the set itself instead of letting PowerShell unroll it.
    return ,$ids
}

# Model ids currently configured, in file order.
function Get-LmConfiguredIds([object[]]$Providers) {
    $ids = New-Object System.Collections.ArrayList
    foreach ($provider in (Get-LmFlatArray $Providers)) {
        foreach ($model in (Get-LmFlatArray (Get-LmModelProperty $provider 'models'))) {
            $id = ([string](Get-LmModelProperty $model 'id')).Trim()
            if ($id) {
                [void]$ids.Add($id)
            }
        }
    }
    return ,$ids.ToArray()
}

# Prefer the provider already wired to this proxy, then any custom endpoint
# provider, then a name match, then whatever is first in the file.
function Select-LmHostProvider {
    param(
        [object[]]$Providers,
        [string]$Url,
        [string]$ProviderName
    )

    $authority = $null
    if ($Url) {
        try {
            $authority = ([System.Uri]$Url).Authority
        } catch {}
    }

    if ($authority) {
        foreach ($provider in (Get-LmFlatArray $Providers)) {
            foreach ($model in (Get-LmFlatArray (Get-LmModelProperty $provider 'models'))) {
                $modelUrl = [string](Get-LmModelProperty $model 'url')
                if ($modelUrl -and $modelUrl.Contains($authority)) {
                    return ,$provider
                }
            }
        }
    }
    foreach ($provider in (Get-LmFlatArray $Providers)) {
        if (([string](Get-LmModelProperty $provider 'vendor')) -eq 'customendpoint') {
            return ,$provider
        }
    }
    if ($ProviderName) {
        foreach ($provider in (Get-LmFlatArray $Providers)) {
            if (([string](Get-LmModelProperty $provider 'name')) -eq $ProviderName) {
                return ,$provider
            }
        }
    }
    return $(Get-LmFlatArray $Providers | Select-Object -First 1)
}

# True only when the block is unambiguously this proxy's own: one of its models
# points at the proxy, or it carries the provider name we were given. Guarding the
# delete path with this keeps Select-LmHostProvider's convenience fallbacks from
# ever reaching somebody else's provider.
function Test-LmOwnedProvider {
    param(
        [object]$Provider,
        [string]$Url,
        [string]$ProviderName = 'Reasoning Proxy'
    )

    $authority = $null
    if ($Url) {
        try { $authority = ([System.Uri]$Url).Authority } catch {}
    }
    if ($authority) {
        foreach ($model in (Get-LmFlatArray (Get-LmModelProperty $Provider 'models'))) {
            $modelUrl = [string](Get-LmModelProperty $model 'url')
            if ($modelUrl -and $modelUrl.Contains($authority)) {
                return $true
            }
        }
    }
    if ($ProviderName -and (([string](Get-LmModelProperty $Provider 'name')) -eq $ProviderName)) {
        return $true
    }
    return $false
}

# Model ids living inside the block this proxy owns. Anything outside it belongs to
# another provider, so it is never marked as ours and never pruned.
function Get-LmHostModelIds {
    param(
        [string[]]$Paths,
        [string]$Url,
        [string]$ProviderName = 'Reasoning Proxy'
    )

    $ids = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($Paths)) {
        if (-not $path -or -not (Test-Path -LiteralPath $path)) {
            continue
        }
        try {
            $parsed = Read-LmJsonFile $path
        } catch {
            continue
        }
        if ($null -eq $parsed) {
            continue
        }
        $provider = Select-LmHostProvider -Providers (Get-LmFlatArray $parsed) -Url $Url -ProviderName $ProviderName
        if ($null -eq $provider) {
            continue
        }
        foreach ($model in (Get-LmFlatArray (Get-LmModelProperty $provider 'models'))) {
            $id = ([string](Get-LmModelProperty $model 'id')).Trim()
            if ($id) {
                [void]$ids.Add($id)
            }
        }
    }
    return ,$ids
}

# Reconcile the provider block this proxy owns with the list the caller wants.
# With -Prune the given ids become the whole desired set, so anything checked out
# of the list is dropped from that block; without it the merge only ever appends.
function Merge-LmModels {
    param(
        [object]$Providers,
        [string[]]$ModelIds,
        # Full upstream list used only for the "no longer visible upstream"
        # report, so a picker that adds a subset does not flag the rest as stale.
        [string[]]$UpstreamIds = @(),
        # Per-model edits from the picker: id -> @{ MaxInputTokens; Vision }.
        # Anything absent falls back to the caller's global defaults.
        [hashtable]$Overrides = @{},
        # Treat ModelIds as the complete desired set and delete the rest.
        [bool]$Prune = $false,
        [string]$Url,
        [string]$ProviderName = 'Reasoning Proxy',
        [int]$MaxInputTokens = 1000000,
        [int]$MaxOutputTokens = 128000,
        [bool]$ToolCalling = $true,
        [bool]$Vision = $true,
        [string[]]$SkipPatterns = @(),
        [string[]]$IncludePatterns = @()
    )

    $providerList = New-Object System.Collections.ArrayList
    foreach ($provider in (Get-LmFlatArray $Providers)) {
        if ($null -ne $provider) {
            [void]$providerList.Add($provider)
        }
    }

    $target = Select-LmHostProvider -Providers $providerList.ToArray() -Url $Url -ProviderName $ProviderName
    if ($null -eq $target) {
        $target = [ordered]@{}
        $target['name'] = $ProviderName
        $target['vendor'] = 'customendpoint'
        $target['apiType'] = 'chat-completions'
        $target['models'] = @()
        [void]$providerList.Add($target)
    }

    # Existing entries are copied out before appending: the array that
    # ConvertFrom-Json produced is fixed size, and a provider may hold none.
    $existingIds = New-Object System.Collections.ArrayList
    foreach ($model in (Get-LmFlatArray (Get-LmModelProperty $target 'models'))) {
        if ($null -ne $model) {
            [void]$existingIds.Add($model)
        }
    }

    # id -> model object for the block this proxy owns, so a checked row that is
    # already configured can be edited in place instead of being waved away.
    $hostModels = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($model in $existingIds) {
        $mid = ([string](Get-LmModelProperty $model 'id')).Trim()
        if ($mid -and -not $hostModels.ContainsKey($mid)) {
            $hostModels[$mid] = $model
        }
    }

    $checked = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @($ModelIds)) {
        $trimmed = ([string]$id).Trim()
        if ($trimmed) {
            [void]$checked.Add($trimmed)
        }
    }

    # Deleting is only allowed inside a block that is unambiguously this proxy's.
    # Select-LmHostProvider has deliberate fallbacks that can land on somebody
    # else's provider, and pruning through one of those would be data loss.
    $canPrune = $false
    if ($Prune) {
        $canPrune = Test-LmOwnedProvider -Provider $target -Url $Url -ProviderName $ProviderName
    }

    $known = Get-LmKnownIdSet -Providers $providerList.ToArray()
    $added = New-Object System.Collections.ArrayList
    $skipped = New-Object System.Collections.ArrayList
    $already = New-Object System.Collections.ArrayList
    $updated = New-Object System.Collections.ArrayList
    $removed = New-Object System.Collections.ArrayList

    # First pass walks what is already in the block, so order and untouched fields
    # survive: an entry nobody unchecked and nobody edited is written back as is.
    $kept = New-Object System.Collections.ArrayList
    foreach ($model in $existingIds) {
        $mid = ([string](Get-LmModelProperty $model 'id')).Trim()
        if (-not $mid) {
            [void]$kept.Add($model)
            continue
        }
        if (-not $checked.Contains($mid)) {
            if ($canPrune) {
                [void]$removed.Add($mid)
                continue
            }
            [void]$kept.Add($model)
            continue
        }
        [void]$kept.Add($model)
        $override = $null
        if ($Overrides -and $Overrides.ContainsKey($mid)) {
            $override = $Overrides[$mid]
        }
        if ($null -eq $override) {
            # Checked but nothing was edited: leave the entry byte for byte alone.
            [void]$already.Add($mid)
            continue
        }
        if ($override.Contains('MaxInputTokens')) {
            Set-LmModelProperty -Object $model -Name 'maxInputTokens' -Value ([int]$override['MaxInputTokens'])
        }
        if ($override.Contains('Vision')) {
            Set-LmModelProperty -Object $model -Name 'vision' -Value ([bool]$override['Vision'])
        }
        [void]$updated.Add($mid)
    }

    # Second pass adds the ids that were not in the block yet.
    foreach ($id in @($ModelIds)) {
        $id = ([string]$id).Trim()
        if (-not $id) {
            continue
        }
        if ($hostModels.ContainsKey($id)) {
            continue
        }
        if ($known.Contains($id)) {
            # Configured under a provider this proxy does not own. Never duplicate it.
            [void]$already.Add($id)
            continue
        }
        # Re-read the override here: the first pass leaves $override pointing at
        # whichever existing row it visited last.
        $override = $null
        if ($Overrides -and $Overrides.ContainsKey($id)) {
            $override = $Overrides[$id]
        }
        if (@($IncludePatterns).Count -gt 0 -and -not (Test-LmMatchAnyPattern -Id $id -Patterns $IncludePatterns)) {
            [void]$skipped.Add($id)
            continue
        }
        if (Test-LmMatchAnyPattern -Id $id -Patterns $SkipPatterns) {
            [void]$skipped.Add($id)
            continue
        }
        $entryTokens = $MaxInputTokens
        $entryVision = $Vision
        if ($null -ne $override) {
            if ($override.Contains('MaxInputTokens')) {
                $entryTokens = [int]$override['MaxInputTokens']
            }
            if ($override.Contains('Vision')) {
                $entryVision = [bool]$override['Vision']
            }
        }
        [void]$kept.Add((New-LmModelEntry -Id $id -Url $Url -MaxInputTokens $entryTokens -MaxOutputTokens $MaxOutputTokens -ToolCalling $ToolCalling -Vision $entryVision))
        [void]$known.Add($id)
        [void]$added.Add($id)
    }

    Set-LmModelProperty -Object $target -Name 'models' -Value $kept.ToArray()

    $baseline = if (@($UpstreamIds).Count -gt 0) { @($UpstreamIds) } else { @($ModelIds) }
    $stale = New-Object System.Collections.ArrayList
    $removedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $removed.ToArray()) {
        [void]$removedSet.Add([string]$id)
    }
    if (@($baseline).Count -gt 0) {
        $upstream = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($id in @($baseline)) {
            [void]$upstream.Add(([string]$id).Trim())
        }
        foreach ($model in $existingIds) {
            $id = ([string](Get-LmModelProperty $model 'id')).Trim()
            # Something just pruned is not also "kept but stale": that reads as a lie.
            if ($id -and (-not $upstream.Contains($id)) -and (-not $removedSet.Contains($id))) {
                [void]$stale.Add($id)
            }
        }
    }

    # Named variables, not inline expressions: an empty array written straight
    # into a hashtable literal expands to nothing and the key comes back $null.
    $providersOut = $providerList.ToArray()
    $addedOut = $added.ToArray()
    $alreadyOut = $already.ToArray()
    $skippedOut = $skipped.ToArray()
    $updatedOut = $updated.ToArray()
    $removedOut = $removed.ToArray()
    $staleOut = $stale.ToArray()
    # A PSCustomObject keeps an empty array value intact; a hashtable literal
    # would expand it away and hand back $null.
    return [pscustomobject]@{
        Providers = $providersOut
        Added = $addedOut
        Existing = $alreadyOut
        Skipped = $skippedOut
        Updated = $updatedOut
        Removed = $removedOut
        Stale = $staleOut
    }
}

# Classify every upstream model for the picker: already configured, worth adding,
# or filtered out by LM_SKIP_MODELS / LM_INCLUDE_MODELS. Everything except the
# filtered rows comes checked: a checked row that is already configured re-applies
# whatever the table shows, so editing a cell and syncing takes effect at once.
function Get-LmModelPlan {
    param(
        [string[]]$UpstreamIds,
        $KnownIds,
        [hashtable]$Catalog = @{},
        [object[]]$ContextHints = @(),
        # Ids that live in this proxy's own provider block but are no longer upstream.
        # Under prune semantics an invisible row is an accidental deletion, so these
        # get their own row and default to kept.
        [string[]]$LocalIds = @(),
        [string[]]$SkipPatterns = @(),
        [string[]]$IncludePatterns = @()
    )

    # Classify first, then emit already -> new -> filtered. The picker keeps that
    # order, so the models you already set up sit at the top instead of being
    # scattered through an alphabetical list.
    $existing = New-Object System.Collections.ArrayList
    $localOnly = New-Object System.Collections.ArrayList
    $fresh = New-Object System.Collections.ArrayList
    $filtered = New-Object System.Collections.ArrayList

    foreach ($id in @($UpstreamIds)) {
        $id = ([string]$id).Trim()
        if (-not $id) {
            continue
        }

        $known = $false
        if ($KnownIds -and $KnownIds.Contains($id)) {
            $known = $true
        }

        $state = 'new'
        $checked = $true
        if ($known) {
            $state = 'existing'
        } elseif (@($IncludePatterns).Count -gt 0 -and -not (Test-LmMatchAnyPattern -Id $id -Patterns $IncludePatterns)) {
            $state = 'filtered'
            $checked = $false
        } elseif (Test-LmMatchAnyPattern -Id $id -Patterns $SkipPatterns) {
            $state = 'filtered'
            $checked = $false
        }

        $tokens = 0
        $vision = $true
        $configured = $false
        if ($Catalog -and $Catalog.ContainsKey($id)) {
            $configured = $true
            $found = $Catalog[$id]
            $tokens = [int]$found.MaxInputTokens
            $vision = [bool]$found.Vision
        }
        # What an empty cell means for this row: the LM_MODEL_CONTEXT family hit,
        # or 0 so the caller falls back to LM_MAX_INPUT_TOKENS. Kept apart from
        # $tokens above, which is what the file says right now.
        $defaultTokens = Resolve-LmContextHint -Hints $ContextHints -Id $id

        $row = [pscustomobject]@{
            Id = $id
            State = $state
            Checked = $checked
            # True when some chatLanguageModels.json already pins this model, so the
            # picker knows to echo the file back instead of the config.bat defaults.
            Configured = $configured
            MaxInputTokens = $tokens
            DefaultInputTokens = $defaultTokens
            Vision = $vision
        }
        switch ($state) {
            'existing' { [void]$existing.Add($row) }
            'filtered' { [void]$filtered.Add($row) }
            default { [void]$fresh.Add($row) }
        }
    }

    $rows = New-Object System.Collections.ArrayList
    foreach ($row in $existing.ToArray()) {
        [void]$rows.Add($row)
    }
    $upstreamSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @($UpstreamIds)) {
        [void]$upstreamSet.Add(([string]$id).Trim())
    }
    foreach ($id in @($LocalIds)) {
        $id = ([string]$id).Trim()
        if (-not $id -or $upstreamSet.Contains($id)) {
            continue
        }
        $tokens = 0
        $vision = $true
        $configured = $false
        if ($Catalog -and $Catalog.ContainsKey($id)) {
            $configured = $true
            $found = $Catalog[$id]
            $tokens = [int]$found.MaxInputTokens
            $vision = [bool]$found.Vision
        }
        $defaultTokens = Resolve-LmContextHint -Hints $ContextHints -Id $id
        [void]$localOnly.Add([pscustomobject]@{
            Id = $id
            State = 'local'
            Checked = $true
            Configured = $configured
            MaxInputTokens = $tokens
            DefaultInputTokens = $defaultTokens
            Vision = $vision
        })
    }
    foreach ($row in $localOnly.ToArray()) {
        [void]$rows.Add($row)
    }
    foreach ($row in $fresh.ToArray()) {
        [void]$rows.Add($row)
    }
    foreach ($row in $filtered.ToArray()) {
        [void]$rows.Add($row)
    }
    return ,$rows.ToArray()
}

function Invoke-LmHttpGet {
    param(
        [string]$Uri,
        [string]$ApiKey
    )

    $result = @{
        Ok = $false
        Status = 0
        Body = ''
        Error = ''
    }

    try {
        $params = @{
            Uri = $Uri
            Method = 'Get'
            UseBasicParsing = $true
            TimeoutSec = 20
            ErrorAction = 'Stop'
        }
        if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey('NoProxy')) {
            $params['NoProxy'] = $true
        }
        if ($ApiKey) {
            $params['Headers'] = @{ Authorization = "Bearer $ApiKey" }
        }
        $response = Invoke-WebRequest @params
        $result.Status = [int]$response.StatusCode
        $result.Body = [string]$response.Content
        $result.Ok = $result.Status -ge 200 -and $result.Status -lt 300
        if (-not $result.Ok) {
            $result.Error = "HTTP $($result.Status)"
        }
    } catch {
        $result.Error = $_.Exception.Message
        $response = $_.Exception.Response
        if ($response) {
            try {
                $result.Status = [int]$response.StatusCode
            } catch {}
        }
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $result.Body = [string]$_.ErrorDetails.Message
        }
    }

    return $result
}

# A key almost never has to be typed by hand. Codex already keeps one on disk
# for this very upstream, so when the proxy has not seen a VS Code request yet,
# borrow it from there instead of opening a prompt. The key is only ever used for
# the one GET /v1/models call and is never written to any file.
function Find-LmLocalApiKey {
    param([string]$TargetHost)

    $result = [ordered]@{
        Key = ''
        Source = ''
    }

    if ($env:LM_API_KEY) {
        $result['Key'] = [string]$env:LM_API_KEY
        $result['Source'] = 'env:LM_API_KEY'
        return $result
    }

    $codexDir = Join-Path $env:USERPROFILE '.codex'
    $authPath = Join-Path $codexDir 'auth.json'
    if (-not (Test-Path -LiteralPath $authPath)) {
        if ($env:OPENAI_API_KEY) {
            $result['Key'] = [string]$env:OPENAI_API_KEY
            $result['Source'] = 'env:OPENAI_API_KEY'
        }
        return $result
    }

    $auth = $null
    try {
        $auth = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($authPath))
    } catch {
        $auth = $null
    }
    if (-not $auth) {
        return $result
    }

    $candidate = ''
    foreach ($field in @('OPENAI_API_KEY', 'API_KEY')) {
        $value = [string]$auth.$field
        if ($value) {
            $candidate = $value
            break
        }
    }
    if (-not $candidate) {
        return $result
    }

    # Only hand the key to the host Codex itself was configured to talk to.
    $codexConfig = Join-Path $codexDir 'config.toml'
    if (Test-Path -LiteralPath $codexConfig) {
        $declaresHost = $false
        try {
            foreach ($line in [System.IO.File]::ReadAllLines($codexConfig)) {
                if ($line -match 'base_url\s*=\s*"([^"]*)"' -and $Matches[1] -match [regex]::Escape($TargetHost)) {
                    $declaresHost = $true
                    break
                }
            }
        } catch {
            $declaresHost = $true
        }
        if (-not $declaresHost) {
            return $result
        }
    }

    $result['Key'] = $candidate
    $result['Source'] = '~/.codex/auth.json'
    return $result
}

# Ask the running proxy first: it replays the Authorization header it already
# forwards for VS Code, so no key has to be stored anywhere. Falling back to a
# direct upstream call keeps sync working while the proxy is stopped, which needs
# a key, and Find-LmLocalApiKey below is where that key comes from.
function Request-LmModelIds {
    param(
        [int]$ProxyPort,
        [string]$TargetHost,
        [string]$TargetPort,
        [string]$ApiKey,
        [bool]$ProxyRunning
    )

    $report = [ordered]@{
        Ok = $false
        Ids = Get-LmFlatArray $null
        Source = ''
        Status = 0
        Error = ''
        AuthHint = $false
    }
    $failures = New-Object System.Collections.ArrayList

    if ($ProxyRunning -and $ProxyPort -gt 0) {
        $uri = "http://127.0.0.1:$ProxyPort/__reasoning_proxy/models"
        $response = Invoke-LmHttpGet -Uri $uri -ApiKey $ApiKey
        $payload = $null
        if ($response.Body) {
            try {
                $payload = ConvertFrom-Json -InputObject $response.Body
            } catch {
                $payload = $null
            }
        }
        if ($response.Ok -and $payload) {
            $ids = Get-LmFlatArray (Get-LmModelIds $payload)
            if ($ids.Count -gt 0) {
                $report['Ok'] = $true
                $report['Ids'] = $ids
                $report['Source'] = 'proxy'
                $report['Status'] = $response.Status
                return $report
            }
        }
        $detail = 'no model list'
        if ($payload -and $payload.error) {
            $detail = [string]$payload.error
        } elseif ($response.Error) {
            $detail = $response.Error
        }
        [void]$failures.Add("proxy: $detail")
        if ($payload -and [int]$payload.upstreamStatus -in @(401, 403)) {
        $report['AuthHint'] = $true
    }
        if ($response.Status -in @(401, 403)) {
            $report.AuthHint = $true
        }
    }

    if ($TargetHost) {
        $uri = "http://${TargetHost}:$($TargetPort)/v1/models"
        $response = Invoke-LmHttpGet -Uri $uri -ApiKey $ApiKey
        if ($response.Ok) {
            try {
                $payload = ConvertFrom-Json -InputObject $response.Body
                $ids = Get-LmFlatArray (Get-LmModelIds $payload)
            } catch {
                $ids = Get-LmFlatArray $null
            }
            if ($ids.Count -gt 0) {
                $report.Ok = $true
                $report.Ids = $ids
                $report.Source = 'upstream'
                $report.Status = $response.Status
                return $report
            }
            [void]$failures.Add('upstream: response is not a model list')
        } else {
            [void]$failures.Add("upstream: $($response.Error)")
        }
        if ($response.Status -in @(401, 403)) {
            $report['AuthHint'] = $true
            $report['Status'] = $response.Status
        }
    }

    $report['Error'] = ($failures -join '; ')
    return $report
}

function Sync-LmConfig {
    param(
        [string[]]$TargetPaths,
        [string[]]$ModelIds,
        [string[]]$UpstreamIds = @(),
        [hashtable]$Overrides = @{},
        [bool]$Prune = $false,
        [string]$Url,
        [string]$ProviderName = 'Reasoning Proxy',
        [int]$MaxInputTokens = 1000000,
        [int]$MaxOutputTokens = 128000,
        [bool]$ToolCalling = $true,
        [bool]$Vision = $true,
        [string[]]$SkipPatterns = @(),
        [string[]]$IncludePatterns = @(),
        [int]$KeepBackups = 10,
        [string]$BackupRoot = ''
    )

    # Dot assignment on a plain hashtable flattens array values to a string, so
    # every report below is an ordered dictionary written with index syntax.
    $results = New-Object System.Collections.ArrayList
    $emptyList = Get-LmFlatArray $null

    foreach ($path in @($TargetPaths)) {
        $entry = [ordered]@{
            Path = $path
            Ok = $false
            Written = $false
            Backup = $null
            Added = $emptyList
            Existing = $emptyList
            Skipped = $emptyList
            Stale = $emptyList
            AddedCount = 0
            SkippedCount = 0
            StaleCount = 0
            ExistingCount = 0
            Updated = $emptyList
            UpdatedCount = 0
            Removed = $emptyList
            RemovedCount = 0
            AddedText = ''
            UpdatedText = ''
            RemovedText = ''
            SkippedText = ''
            StaleText = ''
            Total = 0
            Error = ''
        }

        try {
            $parsed = Read-LmJsonFile $path
            $providers = @()
            if ($null -ne $parsed) {
                # PowerShell 7 hands back a bare object for a one element JSON
                # array, so accept a provider-shaped object as well.
                $isList = $parsed -is [System.Array]
                if (-not $isList -and $parsed -is [System.Management.Automation.PSCustomObject]) {
                    $isList = @($parsed.PSObject.Properties.Name) -contains 'models'
                }
                if (-not $isList) {
                    throw 'root value is not a provider array; refusing to rewrite this file'
                }
                $providers = Get-LmFlatArray $parsed
            }

            $merge = Merge-LmModels `
                -Providers $providers `
                -ModelIds $ModelIds `
                -UpstreamIds $UpstreamIds `
                -Overrides $Overrides `
                -Prune $Prune `
                -Url $Url `
                -ProviderName $ProviderName `
                -MaxInputTokens $MaxInputTokens `
                -MaxOutputTokens $MaxOutputTokens `
                -ToolCalling $ToolCalling `
                -Vision $Vision `
                -SkipPatterns $SkipPatterns `
                -IncludePatterns $IncludePatterns

            $addedList = Get-LmFlatArray $merge.Added
            $existingList = Get-LmFlatArray $merge.Existing
            $skippedList = Get-LmFlatArray $merge.Skipped
            $updatedList = Get-LmFlatArray $merge.Updated
            $removedList = Get-LmFlatArray $merge.Removed
            $staleList = Get-LmFlatArray $merge.Stale
            $knownSet = Get-LmKnownIdSet -Providers $merge.Providers

            $entry['Added'] = $addedList
            $entry['Existing'] = $existingList
            $entry['Skipped'] = $skippedList
            $entry['Updated'] = $updatedList
            $entry['Removed'] = $removedList
            $entry['Stale'] = $staleList
            $entry['AddedCount'] = $addedList.Count
            $entry['ExistingCount'] = $existingList.Count
            $entry['SkippedCount'] = $skippedList.Count
            $entry['StaleCount'] = $staleList.Count
            $entry['UpdatedCount'] = $updatedList.Count
            $entry['RemovedCount'] = $removedList.Count
            $entry['AddedText'] = ($addedList -join ', ')
            $entry['UpdatedText'] = ($updatedList -join ', ')
            $entry['RemovedText'] = ($removedList -join ', ')
            $entry['SkippedText'] = ($skippedList -join ', ')
            $entry['StaleText'] = ($staleList -join ', ')
            $entry['Total'] = $knownSet.Count
            $writtenProviders = Get-LmFlatArray $merge.Providers

            # A prune that only deletes is still a change worth writing.
            $changed = ($addedList.Count -gt 0) -or ($updatedList.Count -gt 0) -or ($removedList.Count -gt 0)
            if ($changed -or $providers.Count -eq 0) {
                $backupPath = Write-LmJsonFile -Path $path -Value $writtenProviders -KeepBackups $KeepBackups -BackupRoot $BackupRoot
                $entry['Backup'] = $backupPath
                $entry['Written'] = $true
            }
            $entry['Ok'] = $true
        } catch {
            $entry['Error'] = $_.Exception.Message
        }

        [void]$results.Add($entry)
    }

    return ,$results.ToArray()
}

function Get-LmSetting {
    param(
        [hashtable]$Config,
        [string]$Name,
        [string]$Fallback
    )
    if ($Config -and $Config.Contains($Name)) {
        $value = ([string]$Config[$Name]).Trim()
        if ($value) {
            return $value
        }
    }
    return $Fallback
}

function Get-LmBoolSetting {
    param(
        [hashtable]$Config,
        [string]$Name,
        [bool]$Fallback
    )
    $raw = ([string](Get-LmSetting $Config $Name '')).ToLowerInvariant()
    if ($raw -eq '1' -or $raw -eq 'true' -or $raw -eq 'yes') {
        return $true
    }
    if ($raw -eq '0' -or $raw -eq 'false' -or $raw -eq 'no') {
        return $false
    }
    return $Fallback
}

function Get-LmIntSetting {
    param(
        [hashtable]$Config,
        [string]$Name,
        [int]$Fallback
    )
    $raw = [string](Get-LmSetting $Config $Name '')
    $parsed = 0
    if ([int]::TryParse($raw, [ref]$parsed)) {
        return $parsed
    }
    return $Fallback
}

# Resolve every LM_* knob once so the picker flow and the one-shot autosync agree.
function Get-LmSyncSettings {
    param(
        [hashtable]$Config,
        [int]$ProxyPort = 0
    )

    $port = if ($ProxyPort -gt 0) { $ProxyPort } else { Get-LmIntSetting $Config 'PROXY_PORT' 3120 }
    return [ordered]@{
        Port = $port
        Url = Get-LmSetting $Config 'LM_MODEL_URL' "http://127.0.0.1:$port/v1"
        ProviderName = Get-LmSetting $Config 'LM_PROVIDER_NAME' 'Reasoning Proxy'
        MaxInputTokens = Get-LmIntSetting $Config 'LM_MAX_INPUT_TOKENS' 1000000
        MaxOutputTokens = Get-LmIntSetting $Config 'LM_MAX_OUTPUT_TOKENS' 128000
        ToolCalling = Get-LmBoolSetting $Config 'LM_TOOL_CALLING' $true
        Vision = Get-LmBoolSetting $Config 'LM_VISION' $true
        ModelContext = Get-LmSetting $Config 'LM_MODEL_CONTEXT' ''
        SkipPatterns = Split-LmList (Get-LmSetting $Config 'LM_SKIP_MODELS' 'embedding,rerank,reranker,bge,whisper,tts,asr,ocr,ranker,flux,video')
        IncludePatterns = Split-LmList (Get-LmSetting $Config 'LM_INCLUDE_MODELS' '')
        TargetHost = Get-LmSetting $Config 'TARGET_HOST' ''
        TargetPort = Get-LmSetting $Config 'TARGET_PORT' '80'
        ConfigPath = Get-LmSetting $Config 'LM_CONFIG_PATH' ''
        KeepBackups = Get-LmIntSetting $Config 'LM_BACKUP_KEEP' 10
        BackupRoot = Get-LmSetting $Config 'LM_BACKUP_DIR' ''
    }
}

# The only function here that writes to the user's config files. Callers decide
# which models and which files, so nothing lands anywhere without a confirmation.
function Complete-LmSync {
    param(
        [hashtable]$Config,
        [string[]]$ModelIds,
        [string[]]$TargetPaths,
        [string[]]$UpstreamIds = @(),
        # id -> @{ MaxInputTokens; Vision } collected from the picker table.
        [hashtable]$Overrides = @{},
        # The picker is a desired-state editor, so the interactive path prunes.
        # Unattended autosync leaves this off: a flaky upstream that returns fewer
        # models must not be able to empty somebody's config.
        [bool]$Prune = $false,
        [string]$Source = 'upstream',
        [string]$KeySource = '',
        [string]$LogPath = '',
        [int]$ProxyPort = 0
    )

    $finished = Get-Date
    $settings = Get-LmSyncSettings -Config $Config -ProxyPort $ProxyPort
    $report = [ordered]@{
        Ok = $false
        Text = ''
        Detail = ''
        Ids = (Get-LmFlatArray $null)
        Results = (Get-LmFlatArray $null)
    }

    $ids = Get-LmFlatArray $ModelIds
    $baseline = if (@($UpstreamIds).Count -gt 0) { Get-LmFlatArray $UpstreamIds } else { $ids }
    $targets = Get-LmFlatArray $TargetPaths

    $results = Sync-LmConfig `
        -TargetPaths $targets `
        -ModelIds $ids `
        -UpstreamIds $baseline `
        -Overrides $Overrides `
        -Prune $Prune `
        -Url $settings['Url'] `
        -ProviderName $settings['ProviderName'] `
        -MaxInputTokens $settings['MaxInputTokens'] `
        -MaxOutputTokens $settings['MaxOutputTokens'] `
        -ToolCalling $settings['ToolCalling'] `
        -Vision $settings['Vision'] `
        -SkipPatterns $settings['SkipPatterns'] `
        -IncludePatterns $settings['IncludePatterns'] `
        -KeepBackups $settings['KeepBackups'] `
        -BackupRoot $settings['BackupRoot']

    $report['Ok'] = $true
    $report['Ids'] = $ids
    $report['Results'] = $results

    $detail = New-Object System.Collections.ArrayList
    $summary = New-Object System.Collections.ArrayList
    $anyFailure = $false

    foreach ($result in $results) {
        if (-not $result['Ok']) {
            $anyFailure = $true
            [void]$summary.Add("写入失败 $($result['Path'])")
            [void]$detail.Add("  FAILED  $($result['Path']) - $($result['Error'])")
            continue
        }
        # Short per-file line for the status bar; the long form goes to the log.
        $label = Split-LmEditorLabel $result['Path']
        $parts = New-Object System.Collections.ArrayList
        if ($result['AddedCount'] -gt 0) {
            [void]$parts.Add("新增 $($result['AddedCount']) 个")
        }
        if ($result['UpdatedCount'] -gt 0) {
            [void]$parts.Add("更新 $($result['UpdatedCount']) 个")
        }
        if ($result['RemovedCount'] -gt 0) {
            [void]$parts.Add("移除 $($result['RemovedCount']) 个")
        }
        if ($parts.Count -gt 0) {
            [void]$summary.Add("$label $($parts -join ' · ')")
        } else {
            [void]$summary.Add("$label 无改动")
        }
        [void]$detail.Add("  FILE    $($result['Path'])")
        if ($result['AddedCount'] -gt 0) {
            [void]$detail.Add("  ADDED   $($result['AddedText'])")
        }
        if ($result['UpdatedCount'] -gt 0) {
            [void]$detail.Add("  UPDATED $($result['UpdatedText'])")
        }
        if ($result['RemovedCount'] -gt 0) {
            [void]$detail.Add("  REMOVED $($result['RemovedText'])")
        }
        if ($result['SkippedCount'] -gt 0) {
            [void]$detail.Add("  SKIPPED $($result['SkippedText'])")
        }
        if ($result['StaleCount'] -gt 0) {
            [void]$detail.Add("  STALE   $($result['StaleText'])（上游已不可见，保留未删）")
        }
        if ($result['Backup']) {
            [void]$detail.Add("  BACKUP  $($result['Backup'])")
        }
        [void]$detail.Add("  TOTAL   配置中共 $($result['Total']) 个模型")
    }

    $verb = if ($anyFailure) { '部分失败' } elseif (@($results | Where-Object { $_['Written'] }).Count -gt 0) { '已更新' } else { '已是最新' }
    $report['Text'] = "上次同步 $($finished.ToString('HH:mm'))：$verb - " + ($summary -join '；')
    $detailText = New-Object System.Collections.ArrayList
    $keyNote = if ($Source -eq 'upstream') { " key=$keySource" } else { " key=$Source" }
    [void]$detailText.Add("[lm-sync] $($finished.ToString('yyyy-MM-dd HH:mm:ss')) $($verb) via=$Source upstream=$($settings['TargetHost']):$($settings['TargetPort']) picked=$($ids.Count)/$($baseline.Count)$keyNote")
    foreach ($line in $detail) {
        [void]$detailText.Add($line)
    }
    $report['Detail'] = ($detailText -join "`r`n")

    if ($LogPath) {
        Add-LmHistory -Path $LogPath -Line $report['Detail']
    }
    return $report
}

# Resolve a usable key and pull the upstream list. Writes nothing, so the picker can
# show the result first and the one-shot sync can reuse the same path.
function Request-LmModelList {
    param(
        [hashtable]$Config,
        [bool]$ProxyRunning = $true,
        [int]$ProxyPort = 0,
        [scriptblock]$AskForApiKey
    )

    $settings = Get-LmSyncSettings -Config $Config -ProxyPort $ProxyPort
    $apiKey = Get-LmSetting $Config 'LM_API_KEY' ''
    $keySource = ''
    if ($apiKey) {
        $keySource = 'LM_API_KEY'
    } else {
        $localKey = Find-LmLocalApiKey -TargetHost $settings['TargetHost']
        if ($localKey['Key']) {
            $apiKey = [string]$localKey['Key']
            $keySource = [string]$localKey['Source']
        }
    }

    $fetch = Request-LmModelIds `
        -ProxyPort $settings['Port'] `
        -TargetHost $settings['TargetHost'] `
        -TargetPort $settings['TargetPort'] `
        -ApiKey $apiKey `
        -ProxyRunning $ProxyRunning

    # Only fall back to a prompt when there was genuinely no key to try.
    if (-not $fetch.Ok -and $fetch.AuthHint -and $AskForApiKey -and -not $apiKey) {
        $asked = [string](& $AskForApiKey)
        if ($asked.Trim()) {
            $keySource = 'LM_API_KEY'
            $fetch = Request-LmModelIds `
                -ProxyPort $settings['Port'] `
                -TargetHost $settings['TargetHost'] `
                -TargetPort $settings['TargetPort'] `
                -ApiKey $asked.Trim() `
                -ProxyRunning $ProxyRunning
        }
    }

    return [ordered]@{
        Ok = [bool]$fetch.Ok
        Ids = (Get-LmFlatArray $fetch.Ids)
        Source = [string]$fetch.Source
        KeySource = $keySource
        Error = [string]$fetch.Error
        AuthHint = [bool]$fetch.AuthHint
        ApiKey = $apiKey
        Settings = $settings
    }
}

# Everything the sync button does when nobody is watching: fetch, then write the whole
# list into the auto-detected targets. The interactive button uses the picker instead.
function Invoke-LmSync {
    param(
        [hashtable]$Config,
        [bool]$ProxyRunning = $true,
        [int]$ProxyPort = 0,
        [string]$LogPath = '',
        [scriptblock]$AskForApiKey
    )

    $fetch = Request-LmModelList -Config $Config -ProxyRunning $ProxyRunning -ProxyPort $ProxyPort -AskForApiKey $AskForApiKey
    if (-not $fetch['Ok']) {
        return (New-LmFetchFailureReport -Fetch $fetch -ApiKey $fetch['ApiKey'] -KeySource $fetch['KeySource'] -LogPath $LogPath)
    }

    $settings = $fetch['Settings']
    $targets = Select-LmTargetPaths -ConfigPath $settings['ConfigPath']
    # Autosync has nobody to edit the picker table, so LM_MODEL_CONTEXT is the only
    # way a model there gets anything other than the global default.
    $overrides = @{}
    $hints = Get-LmContextHints $settings['ModelContext']
    foreach ($id in (Get-LmFlatArray $fetch['Ids'])) {
        $tokens = Resolve-LmContextHint -Hints $hints -Id ([string]$id)
        if ($tokens -gt 0) {
            $overrides[[string]$id] = @{ MaxInputTokens = $tokens }
        }
    }
    return (Complete-LmSync `
        -Config $Config `
        -ModelIds $fetch['Ids'] `
        -UpstreamIds $fetch['Ids'] `
        -TargetPaths $targets `
        -Overrides $overrides `
        -Source $fetch['Source'] `
        -KeySource $fetch['KeySource'] `
        -LogPath $LogPath `
        -ProxyPort $settings['Port'])
}

# Shared failure shape for both the one-shot sync and the interactive picker.
function New-LmFetchFailureReport {
    param(
        $Fetch,
        [string]$ApiKey,
        [string]$KeySource,
        [string]$LogPath
    )

    $finished = Get-Date
    $reason = if ($Fetch['Error']) { [string]$Fetch['Error'] } else { '上游没有返回模型列表' }
    if ($Fetch['AuthHint']) {
        if ($ApiKey) {
            $reason = "$reason（$KeySource 里的密钥被上游拒绝）"
        } else {
            $reason = "$reason（本地没有找到可用密钥：在 VS Code 里发一次对话让代理捕获，或在 config 里填 LM_API_KEY）"
        }
    }

    $report = [ordered]@{
        Ok = $false
        Text = "上次同步 $($finished.ToString('HH:mm'))：拉取失败 - $reason"
        Detail = "[lm-sync] $($finished.ToString('yyyy-MM-dd HH:mm:ss')) FAILED source=none reason=$reason"
        Ids = (Get-LmFlatArray $null)
        Results = (Get-LmFlatArray $null)
    }
    if ($LogPath) {
        Add-LmHistory -Path $LogPath -Line $report['Detail']
    }
    return $report
}

function Add-LmHistory {
    param(
        [string]$Path,
        [string]$Line
    )
    try {
        $directory = Split-Path -Parent $Path
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Force -Path $directory | Out-Null
        }
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($Path, $Line + "`r`n", $encoding)
    } catch {}
}
