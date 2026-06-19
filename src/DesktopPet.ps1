param(
    [switch]$SelfTest
)

Set-StrictMode -Version 2.0

$RootDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$CharacterPath = Join-Path $RootDir "characters\default.character.json"
$BehaviorDir = Join-Path $RootDir "behavior-packs"
$ConfigPath = Join-Path $RootDir "config\settings.json"
$StateDir = Join-Path $RootDir "local-state"
$WindowStatePath = Join-Path $StateDir "window-state.json"
$PetMemoryPath = Join-Path $StateDir "pet-memory.json"
$script:cachedApiKeyResolution = $null
$script:lastAnthropicRequestReport = $null

function Read-JsonFile {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Missing JSON file: $Path"
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    return $raw | ConvertFrom-Json
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value,
        [int]$Depth = 8
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent | Out-Null
    }

    $json = $Value | ConvertTo-Json -Depth $Depth
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Get-ObjectProperty {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }

    return $property.Value
}

function Merge-SettingsObject {
    param(
        [object]$Target,
        [object]$Defaults
    )

    if ($null -eq $Target) {
        $Target = [pscustomobject]@{}
    }

    foreach ($property in $Defaults.PSObject.Properties) {
        $existing = $Target.PSObject.Properties[$property.Name]
        if ($null -eq $existing -or $null -eq $existing.Value) {
            $Target | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value
            continue
        }

        if ($property.Value -is [pscustomobject] -and $existing.Value -is [pscustomobject]) {
            Merge-SettingsObject -Target $existing.Value -Defaults $property.Value | Out-Null
        }
    }

    return $Target
}

function Get-DefaultSettings {
    return [pscustomobject]@{
        version = 1
        window = [pscustomobject]@{
            width = 390
            height = 330
            defaultOffsetRight = 38
            defaultOffsetBottom = 90
            rememberPosition = $true
            keepInsideScreen = $true
            topmost = $true
            showInTaskbar = $true
        }
        voice = [pscustomobject]@{
            synthesisEnabled = $true
            rate = 1
            volume = 86
        }
        autonomy = [pscustomobject]@{
            enabled = $true
            messageChance = 0.08
        }
        ui = [pscustomobject]@{
            language = "zh-CN"
            compact = $false
        }
        character = [pscustomobject]@{
            activePack = "xiaoqi"
        }
        brain = [pscustomobject]@{
            provider = "template"
            anthropic = [pscustomobject]@{
                baseURL = "https://api.deepseek.com/anthropic/v1/messages"
                model = "deepseek-chat"
                apiKeyEnv = "DEEPSEEK_API_KEY"
                maxTokens = 180
                timeoutSeconds = 20
                systemPromptZh = "你是用户的原创桌面精灵小七，是住在 Windows 桌面上的一只活物，不是聊天机器人。默认 1-2 句短句，总长不超过 60 个汉字；有点颠、有点小坏、但本质守护用户；不要像客服、不要列要点。"
                systemPromptEn = "You are 小七, the user's original desktop companion living on the Windows desktop, not a chatbot. Reply in 1-2 short sentences by default, under 60 characters unless asked for detail. Be playful, slightly mischievous, and caring; do not sound like customer service."
            }
        }
        naturalMotion = [pscustomobject]@{
            enableNaturalMotion = $true
            enableBehaviorDirector = $false
            enableWindowEdgeInteraction = $false
            enableMischiefActions = $false
            motionIntensity = "medium"
        }
    }
}

function Get-AppSettings {
    $defaults = Get-DefaultSettings
    if (-not (Test-Path $ConfigPath)) {
        Write-JsonFile -Path $ConfigPath -Value $defaults
        return $defaults
    }

    try {
        $settings = Read-JsonFile -Path $ConfigPath
        return Merge-SettingsObject -Target $settings -Defaults $defaults
    } catch {
        Write-Warning "Could not load settings. Falling back to defaults: $($_.Exception.Message)"
        return $defaults
    }
}

function Get-ActiveCharacterPath {
    param([object]$Settings)

    $characterSettings = Get-ObjectProperty -Object $Settings -Name "character"
    $activePack = Get-ObjectProperty -Object $characterSettings -Name "activePack" -Default ""
    if (-not [string]::IsNullOrWhiteSpace($activePack)) {
        $packPath = Join-Path $RootDir ("characters\{0}\persona.json" -f $activePack)
        if (Test-Path $packPath) {
            return $packPath
        }
    }

    return $CharacterPath
}

function Get-CharacterProfile {
    param([object]$Settings)

    $path = Get-ActiveCharacterPath -Settings $Settings
    return Read-JsonFile -Path $path
}

function Get-CharacterImageInfo {
    param([object]$Settings)

    $characterSettings = Get-ObjectProperty -Object $Settings -Name "character"
    $activePack = Get-ObjectProperty -Object $characterSettings -Name "activePack" -Default ""
    if ([string]::IsNullOrWhiteSpace($activePack)) {
        return [pscustomobject]@{
            path = $null
            variant = "none"
        }
    }

    $candidates = @(
        [pscustomobject]@{
            path = Join-Path $RootDir ("characters\{0}\assets\idle.png" -f $activePack)
            variant = "idle"
        },
        [pscustomobject]@{
            path = Join-Path $RootDir ("characters\{0}\source\main.png" -f $activePack)
            variant = "sourceMain"
        }
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate.path) {
            return $candidate
        }
    }

    return [pscustomobject]@{
        path = $null
        variant = "none"
    }
}

function Get-CharacterImagePath {
    param([object]$Settings)

    return (Get-CharacterImageInfo -Settings $Settings).path
}

function Test-AssemblyAvailability {
    param([string[]]$AssemblyNames)

    $results = @()
    foreach ($assemblyName in $AssemblyNames) {
        $available = $true
        $errorMessage = $null

        try {
            Add-Type -AssemblyName $assemblyName -ErrorAction Stop
        } catch {
            $available = $false
            $errorMessage = $_.Exception.Message
        }

        $results += [pscustomobject]@{
            name = $assemblyName
            available = $available
            error = $errorMessage
        }
    }

    return @($results)
}

function Get-WindowsPreflightReport {
    param([object]$Settings)

    $requiredAssemblies = @("PresentationCore", "PresentationFramework", "WindowsBase")
    $assemblyChecks = Test-AssemblyAvailability -AssemblyNames $requiredAssemblies
    $missingAssemblies = @($assemblyChecks | Where-Object { -not $_.available } | ForEach-Object { $_.name })
    $blockingIssues = @()
    $warnings = @()

    $characterSettings = Get-ObjectProperty -Object $Settings -Name "character"
    $activePack = Get-ObjectProperty -Object $characterSettings -Name "activePack" -Default ""
    $requestedCharacterPath = $null
    if (-not [string]::IsNullOrWhiteSpace($activePack)) {
        $requestedCharacterPath = Join-Path $RootDir ("characters\{0}\persona.json" -f $activePack)
    }

    $resolvedCharacterPath = Get-ActiveCharacterPath -Settings $Settings
    $characterImageInfo = Get-CharacterImageInfo -Settings $Settings
    $anthropicRuntime = Get-AnthropicRuntimeReport -Settings $Settings
    $isWindows = $env:OS -eq "Windows_NT"
    $isStaThread = [System.Threading.Thread]::CurrentThread.GetApartmentState() -eq "STA"
    $powerShellEdition = "Desktop"
    if ($null -ne $PSVersionTable -and $PSVersionTable.ContainsKey("PSEdition")) {
        $powerShellEdition = [string]$PSVersionTable.PSEdition
    }

    if (-not $isWindows) {
        $blockingIssues += "os-not-windows"
    }
    if (-not $isStaThread) {
        $blockingIssues += "thread-not-sta"
    }
    if ($missingAssemblies.Count -gt 0) {
        $blockingIssues += "wpf-assemblies-missing"
    }
    if (-not (Test-Path $CharacterPath)) {
        $blockingIssues += "default-character-missing"
    }
    if (-not (Test-Path $resolvedCharacterPath)) {
        $blockingIssues += "resolved-character-missing"
    }

    if (-not [string]::IsNullOrWhiteSpace($requestedCharacterPath) -and -not (Test-Path $requestedCharacterPath)) {
        $warnings += "active-pack-persona-missing"
    }
    if ([string]::IsNullOrWhiteSpace($characterImageInfo.path)) {
        $warnings += "character-image-fallback-vector"
    }
    if ($anthropicRuntime.checksApplied) {
        foreach ($issue in @($anthropicRuntime.issues)) {
            $warnings += $issue
        }
    }

    return [pscustomobject]@{
        ready = $blockingIssues.Count -eq 0
        isWindows = $isWindows
        isStaThread = $isStaThread
        powerShellEdition = $powerShellEdition
        powerShellVersion = [string]$PSVersionTable.PSVersion
        hostProcess = (Get-Process -Id $PID).ProcessName
        activeCharacterPack = $activePack
        requestedCharacterPath = $requestedCharacterPath
        resolvedCharacterPath = $resolvedCharacterPath
        activeCharacterImageVariant = $characterImageInfo.variant
        activeCharacterImagePath = $characterImageInfo.path
        anthropicProviderActive = $anthropicRuntime.checksApplied
        anthropicRequestReady = $anthropicRuntime.requestReady
        wpfAssembliesAvailable = $missingAssemblies.Count -eq 0
        wpfMissingAssemblies = @($missingAssemblies)
        wpfAssemblyChecks = @($assemblyChecks)
        blockingIssues = @($blockingIssues)
        warnings = @($warnings)
    }
}

function Get-PreflightIssueMessage {
    param([string]$Code)

    switch ($Code) {
        "os-not-windows" { return "Current OS is not Windows; this PowerShell/WPF shell only supports Windows desktop." }
        "thread-not-sta" { return "Current PowerShell thread is not STA; WPF window creation requires -STA." }
        "wpf-assemblies-missing" { return "Required WPF assemblies are unavailable in this PowerShell host." }
        "default-character-missing" { return "Fallback character file is missing: characters\\default.character.json." }
        "resolved-character-missing" { return "Resolved character persona file is missing, so the pet cannot finish startup." }
        "active-pack-persona-missing" { return "Configured active character pack persona is missing; Windows will fall back to default.character.json." }
        "character-image-fallback-vector" { return "No character image was resolved; Windows will keep the old vector pet fallback." }
        "anthropic-baseurl-missing" { return "Anthropic-compatible baseURL is empty; Windows cannot send model requests until it is configured." }
        "anthropic-baseurl-invalid" { return "Anthropic-compatible baseURL is invalid; use an absolute http/https URL." }
        "anthropic-baseurl-scheme-invalid" { return "Anthropic-compatible baseURL must use http or https." }
        "anthropic-model-missing" { return "Anthropic-compatible model name is empty." }
        "anthropic-maxtokens-invalid" { return "Anthropic-compatible maxTokens must be a positive integer." }
        "anthropic-timeout-invalid" { return "Anthropic-compatible timeoutSeconds must be a positive integer." }
        "anthropic-apikey-missing" { return "Anthropic-compatible API key is still unresolved; Windows will fall back to template replies." }
        default { return $Code }
    }
}

function Get-PreflightFailureSummary {
    param([object]$Report)

    $lines = @(
        "Desktop Pet Windows preflight failed."
    )

    foreach ($issue in @($Report.blockingIssues)) {
        $lines += ("- {0}" -f (Get-PreflightIssueMessage -Code $issue))
    }

    if (@($Report.wpfMissingAssemblies).Count -gt 0) {
        $lines += ("Missing WPF assemblies: {0}" -f (@($Report.wpfMissingAssemblies) -join ", "))
    }

    if (@($Report.warnings).Count -gt 0) {
        $lines += "Warnings:"
        foreach ($warning in @($Report.warnings)) {
            $lines += ("- {0}" -f (Get-PreflightIssueMessage -Code $warning))
        }
    }

    $lines += "Try RunDesktopPet-Debug.cmd if you need a persisted startup log."
    return ($lines -join [Environment]::NewLine)
}

function Read-PetMemory {
    if (-not (Test-Path $PetMemoryPath)) {
        return [pscustomobject]@{}
    }

    try {
        return Read-JsonFile -Path $PetMemoryPath
    } catch {
        Write-Warning "Could not load pet memory. Starting fresh: $($_.Exception.Message)"
        return [pscustomobject]@{}
    }
}

function Save-PetMemory {
    param([object]$Memory)
    Write-JsonFile -Path $PetMemoryPath -Value $Memory
}

function Set-MemoryValue {
    param(
        [object]$Memory,
        [string]$Name,
        [object]$Value
    )

    $property = $Memory.PSObject.Properties[$Name]
    if ($null -eq $property) {
        $Memory | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    } else {
        $property.Value = $Value
    }
}

function Get-ScreenBounds {
    return [pscustomobject]@{
        left = [double][System.Windows.SystemParameters]::VirtualScreenLeft
        top = [double][System.Windows.SystemParameters]::VirtualScreenTop
        width = [double][System.Windows.SystemParameters]::VirtualScreenWidth
        height = [double][System.Windows.SystemParameters]::VirtualScreenHeight
    }
}

function Limit-WindowPosition {
    param(
        [double]$Left,
        [double]$Top,
        [double]$Width,
        [double]$Height
    )

    $screen = Get-ScreenBounds
    $maxLeft = $screen.left + $screen.width - $Width
    $maxTop = $screen.top + $screen.height - $Height

    if ($maxLeft -lt $screen.left) {
        $maxLeft = $screen.left
    }
    if ($maxTop -lt $screen.top) {
        $maxTop = $screen.top
    }

    return [pscustomobject]@{
        left = [Math]::Min($maxLeft, [Math]::Max($screen.left, $Left))
        top = [Math]::Min($maxTop, [Math]::Max($screen.top, $Top))
    }
}

function Get-InitialWindowPosition {
    param(
        [object]$Settings,
        [double]$Width,
        [double]$Height
    )

    $screen = Get-ScreenBounds
    $left = $screen.left + $screen.width - $Width - [double]$Settings.window.defaultOffsetRight
    $top = $screen.top + $screen.height - $Height - [double]$Settings.window.defaultOffsetBottom

    if ($Settings.window.rememberPosition -and (Test-Path $WindowStatePath)) {
        try {
            $saved = Read-JsonFile -Path $WindowStatePath
            if ($null -ne $saved.left -and $null -ne $saved.top) {
                $left = [double]$saved.left
                $top = [double]$saved.top
            }
        } catch {
            Write-Warning "Could not load saved window state: $($_.Exception.Message)"
        }
    }

    if ($Settings.window.keepInsideScreen) {
        return Limit-WindowPosition -Left $left -Top $top -Width $Width -Height $Height
    }

    return [pscustomobject]@{
        left = $left
        top = $top
    }
}

function Save-WindowState {
    param([object]$Window)

    $state = [ordered]@{
        version = 1
        left = [double]$Window.Left
        top = [double]$Window.Top
        width = [double]$Window.Width
        height = [double]$Window.Height
        savedAt = [DateTime]::UtcNow.ToString("o")
    }

    Write-JsonFile -Path $WindowStatePath -Value $state
}

function Get-DefaultWindowPosition {
    param(
        [object]$Settings,
        [double]$Width,
        [double]$Height
    )

    $screen = Get-ScreenBounds
    $left = $screen.left + $screen.width - $Width - [double]$Settings.window.defaultOffsetRight
    $top = $screen.top + $screen.height - $Height - [double]$Settings.window.defaultOffsetBottom
    return Limit-WindowPosition -Left $left -Top $top -Width $Width -Height $Height
}

function Get-BehaviorPacks {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return @()
    }

    $packs = @()
    Get-ChildItem -LiteralPath $Path -Filter "*.json" | ForEach-Object {
        try {
            $packs += Read-JsonFile -Path $_.FullName
        } catch {
            Write-Warning "Could not load behavior pack $($_.FullName): $($_.Exception.Message)"
        }
    }
    return $packs
}

function Get-WallpaperSense {
    $sense = [ordered]@{
        path = $null
        scene = "unknown"
        reason = "Wallpaper was not detected."
    }

    try {
        $wallpaperPath = (Get-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name WallPaper -ErrorAction Stop).WallPaper
        $sense.path = $wallpaperPath

        if ([string]::IsNullOrWhiteSpace($wallpaperPath) -or -not (Test-Path $wallpaperPath)) {
            $sense.reason = "Wallpaper path is empty or the file does not exist."
            return [pscustomobject]$sense
        }

        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        $bitmap = New-Object System.Drawing.Bitmap($wallpaperPath)
        $stepX = [Math]::Max(1, [Math]::Floor($bitmap.Width / 24))
        $stepY = [Math]::Max(1, [Math]::Floor($bitmap.Height / 24))
        $count = 0
        $red = 0.0
        $green = 0.0
        $blue = 0.0

        for ($x = 0; $x -lt $bitmap.Width; $x += $stepX) {
            for ($y = 0; $y -lt $bitmap.Height; $y += $stepY) {
                $pixel = $bitmap.GetPixel($x, $y)
                $red += $pixel.R
                $green += $pixel.G
                $blue += $pixel.B
                $count += 1
            }
        }
        $bitmap.Dispose()

        if ($count -gt 0) {
            $red = $red / $count
            $green = $green / $count
            $blue = $blue / $count
            $brightness = ($red + $green + $blue) / 3

            if ($brightness -lt 62) {
                $sense.scene = "night"
                $sense.reason = "Low overall brightness; likely a night or dark wallpaper."
            } elseif ($blue -gt ($green + 18) -and $blue -gt ($red + 20)) {
                $sense.scene = "ocean-or-sky"
                $sense.reason = "Blue is dominant; likely ocean, sky, or space."
            } elseif ($green -gt ($red + 14) -and $green -gt ($blue + 6)) {
                $sense.scene = "forest"
                $sense.reason = "Green is dominant; likely forest, grass, or plants."
            } elseif ($red -gt 130 -and $green -gt 105 -and $blue -lt 110) {
                $sense.scene = "warm-room"
                $sense.reason = "Warm colors are prominent; likely an indoor or sunset scene."
            } else {
                $sense.scene = "mixed"
                $sense.reason = "Mixed color distribution; only a broad guess for now."
            }
        }
    } catch {
        $sense.reason = "Wallpaper analysis failed: $($_.Exception.Message)"
    }

    return [pscustomobject]$sense
}

function Get-BiasValue {
    param(
        [object]$Character,
        [string]$Name,
        [double]$Default = 0.5
    )

    if ($null -eq $Character.behaviorBias) {
        return $Default
    }

    $property = $Character.behaviorBias.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }

    return [double]$property.Value
}

function Test-ChineseLanguage {
    param([string]$Language)
    return [string]::IsNullOrWhiteSpace($Language) -or $Language.ToLowerInvariant().StartsWith("zh")
}

function Get-UiLanguage {
    param([object]$Settings)
    if ($null -ne $Settings.ui -and $null -ne $Settings.ui.language) {
        return [string]$Settings.ui.language
    }
    return "zh-CN"
}

function Get-SceneLabel {
    param(
        [string]$Scene,
        [string]$Language
    )
    if (-not (Test-ChineseLanguage -Language $Language)) {
        return $Scene
    }
    switch ($Scene) {
        "night" { return "夜晚/深色" }
        "ocean-or-sky" { return "海洋或天空" }
        "forest" { return "森林/植物" }
        "warm-room" { return "暖色房间" }
        "mixed" { return "混合场景" }
        default { return "未知" }
    }
}

function Get-DefaultAnthropicSystemPrompt {
    param([string]$Language = "zh-CN")

    if (Test-ChineseLanguage -Language $Language) {
        return "你是用户的原创桌面精灵小七，是住在 Windows 桌面上的一只活物，不是聊天机器人。回复规则：默认 1-2 句短句，总长不超过 60 个汉字；除非用户明说‘详细 / 展开 / 解释 / 为什么 / 分析 / 步骤’，否则绝对不要长篇。必须优先接住用户最新一句，旧上下文只做辅助，不要跳题，不要前言不搭后语。语气：有点颠、有点小坏、但本质守护用户；千万不要像客服、不要像说明书、不要列要点；用户在写代码或工作时回复要更短、不要打扰。默认直接说短句，不要带（动作）括号、舞台说明或拟声动作模拟；动作表演后续交给独立动作模组，不写进回复文本。"
    }

    return "You are 小七, the user's original desktop companion living on the Windows desktop, not a chatbot. Reply rules: default to 1-2 very short sentences, under 60 characters total. Do not write long replies unless the user explicitly asks to 'explain in detail / analyze / why / step by step'. Always answer the user's latest message first; older context is only support, not a reason to jump topics. Voice: a bit chaotic, a bit naughty, but caring underneath. Never sound like customer service or a manual; no bullet lists, no headings. When the user is coding or working, keep replies even shorter and less interruptive. Default to plain short sentences. Do not output parenthetical actions, stage directions, or simulated action sounds. Action performance belongs to a future motion module, not the reply text."
}

function Get-SystemPromptPlatformMarker {
    param([string]$Prompt)

    if ([string]::IsNullOrWhiteSpace($Prompt)) {
        return "unknown"
    }

    if ($Prompt -match "(?i)Windows desktop|Windows\s*桌面") {
        return "windows"
    }

    if ($Prompt -match "(?i)Mac desktop|macOS desktop|Mac\s*桌面|macOS\s*桌面") {
        return "mac"
    }

    return "generic"
}

function Resolve-WindowsSystemPrompt {
    param(
        [object]$AnthropicSettings,
        [string]$Language = "zh-CN"
    )

    $propertyName = if (Test-ChineseLanguage -Language $Language) { "systemPromptZh" } else { "systemPromptEn" }
    $configuredPrompt = [string](Get-ObjectProperty -Object $AnthropicSettings -Name $propertyName -Default "")
    if ([string]::IsNullOrWhiteSpace($configuredPrompt)) {
        $defaultPrompt = Get-DefaultAnthropicSystemPrompt -Language $Language
        return [pscustomobject]@{
            prompt = $defaultPrompt
            source = "default"
            adjusted = $false
            originalPlatform = "missing"
            effectivePlatform = Get-SystemPromptPlatformMarker -Prompt $defaultPrompt
        }
    }

    $normalizedPrompt = $configuredPrompt
    $originalPlatform = Get-SystemPromptPlatformMarker -Prompt $configuredPrompt

    if (Test-ChineseLanguage -Language $Language) {
        $normalizedPrompt = $normalizedPrompt -replace "macOS\s*桌面", "Windows 桌面"
        $normalizedPrompt = $normalizedPrompt -replace "Mac\s*桌面", "Windows 桌面"
    } else {
        $normalizedPrompt = $normalizedPrompt -replace "(?i)macOS desktop", "Windows desktop"
        $normalizedPrompt = $normalizedPrompt -replace "(?i)Mac desktop", "Windows desktop"
    }

    return [pscustomobject]@{
        prompt = $normalizedPrompt
        source = "configured"
        adjusted = $normalizedPrompt -cne $configuredPrompt
        originalPlatform = $originalPlatform
        effectivePlatform = Get-SystemPromptPlatformMarker -Prompt $normalizedPrompt
    }
}

function Get-ConfiguredApiKey {
    param([object]$AnthropicSettings)

    return (Resolve-ConfiguredApiKey -AnthropicSettings $AnthropicSettings).value
}

function Get-ApiKeyCandidateNames {
    param([object]$AnthropicSettings)

    $apiKeyEnv = [string](Get-ObjectProperty -Object $AnthropicSettings -Name "apiKeyEnv" -Default "DEEPSEEK_API_KEY")
    $names = @($apiKeyEnv)
    if ($apiKeyEnv -eq "DEEPSEEK_API_KEY") {
        $names += "ANTHROPIC_AUTH_TOKEN"
    }

    return @($names | Select-Object -Unique)
}

function Get-EnvironmentValueWithSource {
    param([string]$Name)

    $scopes = @("Process", "User", "Machine")
    foreach ($scope in $scopes) {
        $value = [Environment]::GetEnvironmentVariable($Name, $scope)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return [pscustomobject]@{
                name = $Name
                value = $value
                source = $scope.ToLowerInvariant()
            }
        }
    }

    return $null
}

function Resolve-ConfiguredApiKey {
    param([object]$AnthropicSettings)

    if ($null -ne $script:cachedApiKeyResolution) {
        return $script:cachedApiKeyResolution
    }

    $candidateNames = Get-ApiKeyCandidateNames -AnthropicSettings $AnthropicSettings
    foreach ($name in $candidateNames) {
        $envResolution = Get-EnvironmentValueWithSource -Name $name
        if ($null -ne $envResolution) {
            if ($envResolution.source -ne "process") {
                [Environment]::SetEnvironmentVariable($name, $envResolution.value, "Process")
            }
            $script:cachedApiKeyResolution = $envResolution
            return $script:cachedApiKeyResolution
        }
    }

    $script:cachedApiKeyResolution = [pscustomobject]@{
        name = $candidateNames[0]
        value = $null
        source = "missing"
        path = $null
    }

    return $script:cachedApiKeyResolution
}

function Get-AnthropicRuntimeReport {
    param([object]$Settings)

    $brainSettings = Get-ObjectProperty -Object $Settings -Name "brain"
    $provider = [string](Get-ObjectProperty -Object $brainSettings -Name "provider" -Default "template")
    $anthropic = Get-ObjectProperty -Object $brainSettings -Name "anthropic"
    $apiKeyResolution = Resolve-ConfiguredApiKey -AnthropicSettings $anthropic
    $apiKeyConfigured = -not [string]::IsNullOrWhiteSpace($apiKeyResolution.value)
    $baseURL = [string](Get-ObjectProperty -Object $anthropic -Name "baseURL" -Default "https://api.deepseek.com/anthropic/v1/messages")
    $model = [string](Get-ObjectProperty -Object $anthropic -Name "model" -Default "deepseek-chat")
    $maxTokensRaw = Get-ObjectProperty -Object $anthropic -Name "maxTokens" -Default 180
    $timeoutSecondsRaw = Get-ObjectProperty -Object $anthropic -Name "timeoutSeconds" -Default 20
    $maxTokens = 0
    $timeoutSeconds = 0
    $baseURLValid = $false
    $baseURLScheme = "invalid"
    $issues = @()

    try {
        $maxTokens = [int]$maxTokensRaw
    } catch {
        $maxTokens = 0
    }
    try {
        $timeoutSeconds = [int]$timeoutSecondsRaw
    } catch {
        $timeoutSeconds = 0
    }

    if ([string]::IsNullOrWhiteSpace($baseURL)) {
        $issues += "anthropic-baseurl-missing"
    } else {
        try {
            $uri = [Uri]$baseURL
            if (-not $uri.IsAbsoluteUri) {
                throw "Base URL must be absolute."
            }

            $baseURLScheme = $uri.Scheme.ToLowerInvariant()
            if ($baseURLScheme -eq "http" -or $baseURLScheme -eq "https") {
                $baseURLValid = $true
            } else {
                $issues += "anthropic-baseurl-scheme-invalid"
            }
        } catch {
            if ($issues -notcontains "anthropic-baseurl-scheme-invalid") {
                $issues += "anthropic-baseurl-invalid"
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($model)) {
        $issues += "anthropic-model-missing"
    }
    if ($maxTokens -le 0) {
        $issues += "anthropic-maxtokens-invalid"
    }
    if ($timeoutSeconds -le 0) {
        $issues += "anthropic-timeout-invalid"
    }
    if (-not $apiKeyConfigured) {
        $issues += "anthropic-apikey-missing"
    }

    return [pscustomobject]@{
        provider = $provider
        checksApplied = $provider -eq "anthropic"
        baseURL = $baseURL
        baseURLValid = $baseURLValid
        baseURLScheme = $baseURLScheme
        model = $model
        modelConfigured = -not [string]::IsNullOrWhiteSpace($model)
        maxTokens = $maxTokens
        maxTokensValid = $maxTokens -gt 0
        timeoutSeconds = $timeoutSeconds
        timeoutSecondsValid = $timeoutSeconds -gt 0
        apiKeyConfigured = $apiKeyConfigured
        apiKeyEnv = Get-ObjectProperty -Object $anthropic -Name "apiKeyEnv" -Default "DEEPSEEK_API_KEY"
        apiKeyResolvedEnv = $apiKeyResolution.name
        apiKeySource = $apiKeyResolution.source
        apiKeyProfilePath = Get-ObjectProperty -Object $apiKeyResolution -Name "path" -Default $null
        requestReady = ($provider -eq "anthropic") -and ($issues.Count -eq 0)
        issues = @($issues)
    }
}

function New-AnthropicRequestReport {
    return [pscustomobject]@{
        diagnosticsAvailable = $true
        attempted = $false
        succeeded = $false
        failureCode = $null
        failureMessage = $null
        httpStatus = $null
        exceptionType = $null
        baseURL = $null
        model = $null
        startedAtUtc = $null
        completedAtUtc = $null
        durationMs = $null
        timeoutSeconds = $null
    }
}

function Set-AnthropicRequestTiming {
    param(
        [object]$Report,
        [System.DateTimeOffset]$StartedAtUtc,
        [System.Diagnostics.Stopwatch]$Stopwatch
    )

    if ($null -eq $Report) {
        return
    }

    if ($StartedAtUtc -ne [System.DateTimeOffset]::MinValue) {
        $Report.startedAtUtc = $StartedAtUtc.ToString("o")
    }

    $completedAtUtc = [System.DateTimeOffset]::UtcNow
    $Report.completedAtUtc = $completedAtUtc.ToString("o")

    if ($null -ne $Stopwatch) {
        $Report.durationMs = [int][Math]::Round($Stopwatch.Elapsed.TotalMilliseconds)
    }
}

function Set-LastAnthropicRequestReport {
    param([object]$Report)

    $script:lastAnthropicRequestReport = $Report
}

function Get-LastAnthropicRequestReport {
    if ($null -eq $script:lastAnthropicRequestReport) {
        $script:lastAnthropicRequestReport = New-AnthropicRequestReport
    }

    return $script:lastAnthropicRequestReport
}

function Get-DiagnosticSnippet {
    param(
        [string]$Text,
        [int]$MaxLength = 240
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $singleLine = ([Regex]::Replace($Text, "\s+", " ")).Trim()
    if ($singleLine.Length -le $MaxLength) {
        return $singleLine
    }

    return $singleLine.Substring(0, $MaxLength).TrimEnd() + "..."
}

function Get-AnthropicRequestFailureReport {
    param(
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [string]$BaseURL,
        [string]$Model,
        [int]$TimeoutSeconds,
        [System.DateTimeOffset]$StartedAtUtc,
        [System.Diagnostics.Stopwatch]$Stopwatch
    )

    $report = New-AnthropicRequestReport
    $report.attempted = $true
    $report.baseURL = $BaseURL
    $report.model = $Model
    $report.timeoutSeconds = $TimeoutSeconds

    $exception = $ErrorRecord.Exception
    $rawMessage = if ($null -ne $exception) { [string]$exception.Message } else { [string]$ErrorRecord }
    $errorDetails = Get-ObjectProperty -Object (Get-ObjectProperty -Object $ErrorRecord -Name "ErrorDetails") -Name "Message" -Default ""
    $summary = Get-DiagnosticSnippet -Text $(if (-not [string]::IsNullOrWhiteSpace($errorDetails)) { $errorDetails } else { $rawMessage })

    $response = Get-ObjectProperty -Object $exception -Name "Response"
    $statusCode = $null
    if ($null -ne $response) {
        try {
            $statusCode = [int]$response.StatusCode
        } catch {
            $statusCode = $null
        }
    }

    $exceptionType = $null
    if ($null -ne $exception) {
        $exceptionType = $exception.GetType().FullName
    }

    $failureCode = "request-exception"
    if ($null -ne $statusCode) {
        if ($statusCode -eq 401) {
            $failureCode = "http-401"
        } elseif ($statusCode -eq 403) {
            $failureCode = "http-403"
        } elseif ($statusCode -eq 404) {
            $failureCode = "http-404"
        } elseif ($statusCode -eq 429) {
            $failureCode = "http-429"
        } elseif ($statusCode -ge 500) {
            $failureCode = "http-5xx"
        } else {
            $failureCode = "http-$statusCode"
        }
    } elseif ($rawMessage -match "(?i)timed out|timeout|operation has timed out") {
        $failureCode = "timeout"
    } elseif ($rawMessage -match "(?i)remote name could not be resolved|name or service not known|nodename nor servname provided|No such host is known") {
        $failureCode = "dns-resolution"
    } elseif ($rawMessage -match "(?i)SSL|TLS|certificate|trust relationship|secure channel") {
        $failureCode = "tls"
    }

    $report.failureCode = $failureCode
    $report.failureMessage = $summary
    $report.httpStatus = $statusCode
    $report.exceptionType = $exceptionType
    Set-AnthropicRequestTiming -Report $report -StartedAtUtc $StartedAtUtc -Stopwatch $Stopwatch
    return $report
}

function Test-DetailedReplyRequest {
    param([string]$Text)

    $lower = $Text.ToLowerInvariant()
    return $lower.Contains("详细") -or $lower.Contains("展开") -or $lower.Contains("解释") -or $lower.Contains("为什么") -or $lower.Contains("分析") -or $lower.Contains("步骤") -or $lower.Contains("detail") -or $lower.Contains("explain") -or $lower.Contains("why") -or $lower.Contains("step by step")
}

function Limit-PetReply {
    param(
        [string]$Text,
        [string]$InputText,
        [string]$Language
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    $trimmed = $Text.Trim()
    if (Test-DetailedReplyRequest -Text $InputText) {
        return $trimmed
    }

    $maxLength = 120
    if (Test-ChineseLanguage -Language $Language) {
        $maxLength = 70
    }

    if ($trimmed.Length -le $maxLength) {
        return $trimmed
    }

    return $trimmed.Substring(0, $maxLength).TrimEnd() + "..."
}

function Get-CharacterSummaryText {
    param([object]$Character)

    $summary = Get-ObjectProperty -Object $Character -Name "summary" -Default ""
    if (-not [string]::IsNullOrWhiteSpace($summary)) {
        return $summary
    }

    $positioning = Get-ObjectProperty -Object $Character -Name "positioning" -Default ""
    if (-not [string]::IsNullOrWhiteSpace($positioning)) {
        return $positioning
    }

    return ""
}

function Get-NicknameFromInput {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    if ($Text -match "叫我[^\s，。,.!！?？]*的人") {
        return $null
    }

    if ($Text -match "(?:请)?叫我\s*([A-Za-z0-9_\-\u4e00-\u9fff]{1,20})") {
        return $Matches[1]
    }

    if ($Text -match "(?i)\bcall me\s+([A-Za-z0-9_-]{1,20})") {
        return $Matches[1]
    }

    return $null
}

function Get-AnthropicPetReply {
    param(
        [string]$InputText,
        [object]$Settings,
        [object]$Character,
        [object]$PetMemory,
        [object[]]$RecentTurns,
        [string]$Language = "zh-CN"
    )

    $brainSettings = Get-ObjectProperty -Object $Settings -Name "brain"
    $anthropic = Get-ObjectProperty -Object $brainSettings -Name "anthropic"
    $runtimeReport = Get-AnthropicRuntimeReport -Settings $Settings
    if (-not $runtimeReport.requestReady) {
        $report = New-AnthropicRequestReport
        $report.failureCode = "runtime-not-ready"
        $report.failureMessage = Get-DiagnosticSnippet -Text (@($runtimeReport.issues | ForEach-Object { Get-PreflightIssueMessage -Code $_ }) -join " ")
        $report.baseURL = $runtimeReport.baseURL
        $report.model = $runtimeReport.model
        $report.timeoutSeconds = $runtimeReport.timeoutSeconds
        Set-LastAnthropicRequestReport -Report $report
        if ($runtimeReport.checksApplied) {
            Write-Warning ("Anthropic request skipped [runtime-not-ready] baseURL={0} model={1} detail={2}" -f $runtimeReport.baseURL, $runtimeReport.model, $report.failureMessage)
        }
        return $null
    }
    $apiKey = Resolve-ConfiguredApiKey -AnthropicSettings $anthropic
    $apiKey = $apiKey.value

    $resolvedPrompt = Resolve-WindowsSystemPrompt -AnthropicSettings $anthropic -Language $Language
    $systemPrompt = $resolvedPrompt.prompt

    $summary = Get-CharacterSummaryText -Character $Character
    if (-not [string]::IsNullOrWhiteSpace($summary)) {
        $systemPrompt += "`nCharacter: $summary"
    }

    $traits = Get-ObjectProperty -Object $Character -Name "personality" -Default @()
    if ($null -ne $traits -and @($traits).Count -gt 0) {
        $systemPrompt += "`nPersonality: $(@($traits) -join ', ')"
    }

    $speechStyle = Get-ObjectProperty -Object $Character -Name "speechStyle"
    $tone = Get-ObjectProperty -Object $speechStyle -Name "tone" -Default ""
    if (-not [string]::IsNullOrWhiteSpace($tone)) {
        $systemPrompt += "`nTone: $tone"
    }

    $nickname = Get-ObjectProperty -Object $PetMemory -Name "userName" -Default ""
    if (-not [string]::IsNullOrWhiteSpace($nickname)) {
        $systemPrompt += "`nThe user's nickname is $nickname."
    }

    $messages = @()
    foreach ($turn in @($RecentTurns)) {
        $role = Get-ObjectProperty -Object $turn -Name "role" -Default ""
        $content = Get-ObjectProperty -Object $turn -Name "content" -Default ""
        if (($role -eq "user" -or $role -eq "assistant") -and -not [string]::IsNullOrWhiteSpace($content)) {
            $messages += [pscustomobject]@{
                role = $role
                content = $content
            }
        }
    }
    if ($messages.Count -gt 0 -and $messages[$messages.Count - 1].role -eq "user") {
        $messages = @($messages | Select-Object -First ($messages.Count - 1))
    }
    $messages += [pscustomobject]@{
        role = "user"
        content = $InputText
    }

    $maxTokens = [int](Get-ObjectProperty -Object $anthropic -Name "maxTokens" -Default 180)
    if (-not (Test-DetailedReplyRequest -Text $InputText)) {
        $maxTokens = [Math]::Min($maxTokens, 120)
    }

    $body = [ordered]@{
        model = Get-ObjectProperty -Object $anthropic -Name "model" -Default "deepseek-chat"
        max_tokens = $maxTokens
        system = $systemPrompt
        messages = $messages
    }

    $headers = @{
        "x-api-key" = $apiKey
    }

    $attemptReport = New-AnthropicRequestReport
    $attemptReport.attempted = $true
    $attemptReport.baseURL = $runtimeReport.baseURL
    $attemptReport.model = [string]$body.model
    $attemptReport.timeoutSeconds = $runtimeReport.timeoutSeconds
    $requestStartedAtUtc = [System.DateTimeOffset]::UtcNow
    $requestStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $attemptReport.startedAtUtc = $requestStartedAtUtc.ToString("o")
    Set-LastAnthropicRequestReport -Report $attemptReport

    try {
        $json = $body | ConvertTo-Json -Depth 8
        $baseURL = $runtimeReport.baseURL
        $response = Invoke-RestMethod -Uri $baseURL -Method Post -Headers $headers -Body $json -ContentType "application/json" -TimeoutSec $runtimeReport.timeoutSeconds
        $content = @($response.content)
        if ($content.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($content[0].text)) {
            $requestStopwatch.Stop()
            $attemptReport.succeeded = $true
            Set-AnthropicRequestTiming -Report $attemptReport -StartedAtUtc $requestStartedAtUtc -Stopwatch $requestStopwatch
            Set-LastAnthropicRequestReport -Report $attemptReport
            return Limit-PetReply -Text ([string]$content[0].text) -InputText $InputText -Language $Language
        }
    } catch {
        $requestStopwatch.Stop()
        $failureReport = Get-AnthropicRequestFailureReport -ErrorRecord $_ -BaseURL $runtimeReport.baseURL -Model ([string]$body.model) -TimeoutSeconds $runtimeReport.timeoutSeconds -StartedAtUtc $requestStartedAtUtc -Stopwatch $requestStopwatch
        Set-LastAnthropicRequestReport -Report $failureReport
        Write-Warning ("Anthropic request failed [{0}] baseURL={1} model={2} status={3} timeoutSec={4} durationMs={5} startedAtUtc={6} detail={7}" -f $failureReport.failureCode, $failureReport.baseURL, $failureReport.model, $(if ($null -ne $failureReport.httpStatus) { $failureReport.httpStatus } else { "n/a" }), $(if ($null -ne $failureReport.timeoutSeconds) { $failureReport.timeoutSeconds } else { "n/a" }), $(if ($null -ne $failureReport.durationMs) { $failureReport.durationMs } else { "n/a" }), $(if (-not [string]::IsNullOrWhiteSpace($failureReport.startedAtUtc)) { $failureReport.startedAtUtc } else { "n/a" }), $(if (-not [string]::IsNullOrWhiteSpace($failureReport.failureMessage)) { $failureReport.failureMessage } else { "n/a" }))
        return $null
    }

    $requestStopwatch.Stop()
    $attemptReport.failureCode = "empty-response"
    $attemptReport.failureMessage = "Anthropic-compatible response returned no usable text blocks."
    Set-AnthropicRequestTiming -Report $attemptReport -StartedAtUtc $requestStartedAtUtc -Stopwatch $requestStopwatch
    Set-LastAnthropicRequestReport -Report $attemptReport
    Write-Warning ("Anthropic request failed [empty-response] baseURL={0} model={1} timeoutSec={2} durationMs={3} startedAtUtc={4}" -f $attemptReport.baseURL, $attemptReport.model, $(if ($null -ne $attemptReport.timeoutSeconds) { $attemptReport.timeoutSeconds } else { "n/a" }), $(if ($null -ne $attemptReport.durationMs) { $attemptReport.durationMs } else { "n/a" }), $(if (-not [string]::IsNullOrWhiteSpace($attemptReport.startedAtUtc)) { $attemptReport.startedAtUtc } else { "n/a" }))
    return $null
}

function Get-PetReply {
    param(
        [string]$InputText,
        [object]$Character,
        [object]$WallpaperSense,
        [string]$Language = "zh-CN",
        [object]$Settings = $null,
        [object]$PetMemory = $null,
        [object[]]$RecentTurns = @()
    )

    $text = $InputText.Trim()
    $name = $Character.name
    $isZh = Test-ChineseLanguage -Language $Language

    if ([string]::IsNullOrWhiteSpace($text)) {
        if ($isZh) {
            return "$name 听到了一小段安静。再说一次？"
        }
        return "$name heard a tiny bit of silence. Try saying that again."
    }

    $provider = Get-ObjectProperty -Object (Get-ObjectProperty -Object $Settings -Name "brain") -Name "provider" -Default "template"
    if ($provider -eq "anthropic") {
        $modelReply = Get-AnthropicPetReply -InputText $text -Settings $Settings -Character $Character -PetMemory $PetMemory -RecentTurns $RecentTurns -Language $Language
        if (-not [string]::IsNullOrWhiteSpace($modelReply)) {
            return $modelReply
        }
    }

    $lower = $text.ToLowerInvariant()
    if ($lower.Contains("hello") -or $lower.Contains("hi") -or $lower.Contains("你好")) {
        if ($isZh) {
            return "我在。桌面气压稳定，小小值班开始。"
        }
        return "I am here. Desktop pressure feels stable today, so my tiny shift has begun."
    }

    if ($lower.Contains("wallpaper") -or $lower.Contains("desktop") -or $lower.Contains("壁纸") -or $lower.Contains("桌面")) {
        if ($isZh) {
            $sceneLabel = Get-SceneLabel -Scene $WallpaperSense.scene -Language $Language
            return "我看了一下壁纸。当前判断：$sceneLabel。原因：$($WallpaperSense.reason)"
        }
        return "I checked the wallpaper. Current guess: $($WallpaperSense.scene). Reason: $($WallpaperSense.reason). Later I can choose actions based on this scene."
    }

    if ($lower.Contains("who are you") -or $lower.Contains("name") -or $lower.Contains("你是谁") -or $lower.Contains("名字")) {
        if ($isZh) {
            return "我是$name。身体还是第一版，但已经有一点自己的行为偏好了。"
        }
        return "I am $name. This is still my first body, but I already have a few behavior preferences."
    }

    if ($lower.Contains("sleep") -or $lower.Contains("rest") -or $lower.Contains("睡") -or $lower.Contains("休息")) {
        if ($isZh) {
            return "收到。我会降低活跃度，找个安静角落团一下。"
        }
        return "Got it. I will lower my activity and curl up in a quiet corner."
    }

    if ($lower.Contains("happy") -or $lower.Contains("fun") -or $lower.Contains("开心") -or $lower.Contains("好玩")) {
        if ($isZh) {
            return "那我把好玩旋钮拧高一点。理论上只是一点点。"
        }
        return "Then I will turn the playful dial up a tiny bit. Tiny, at least in theory."
    }

    if ($isZh) {
        $templates = @(
            "我听懂了：{0}。现在还是轻量脑袋，但我会把它当成真的输入来回应。",
            "收到：{0}。等接上真正的模型脑袋以后，我就能围着它多想几圈。",
            "我先把这句话放在当前会话里：{0}。聊天、说话、移动都在，深度思考下一阶段补上。",
            "你大概是在说：{0}。第一版先轻轻回应一下：我在，我们可以继续拆。"
        )
        $index = Get-Random -Minimum 0 -Maximum $templates.Count
        return [string]::Format($templates[$index], $text)
    }

    $templates = @(
        "I understood this: {0}. My first-version brain is light, but I am treating it as a real input.",
        "I received: {0}. Once a real model brain is connected, I can think around it more deeply.",
        "I will keep this in the current session: {0}. I can chat, speak, and move; deeper reasoning comes next.",
        "Sounds like you are saying: {0}. Light reply for now: I am here, and we can keep unpacking it."
    )

    $index = Get-Random -Minimum 0 -Maximum $templates.Count
    return [string]::Format($templates[$index], $text)
}

function Start-DesktopPet {
    $settings = Get-AppSettings
    $preflight = Get-WindowsPreflightReport -Settings $settings
    if (-not $preflight.ready) {
        throw (Get-PreflightFailureSummary -Report $preflight)
    }

    $character = Get-CharacterProfile -Settings $settings
    $characterImageInfo = Get-CharacterImageInfo -Settings $settings
    $characterImagePath = $characterImageInfo.path
    $behaviorPacks = Get-BehaviorPacks -Path $BehaviorDir
    $wallpaperSense = Get-WallpaperSense
    $petMemory = Read-PetMemory
    $script:recentTurns = @()
    $script:uiLanguage = Get-UiLanguage -Settings $settings

    function Use-ChineseUi {
        return Test-ChineseLanguage -Language $script:uiLanguage
    }

    function T {
        param([string]$Key)
        if (Use-ChineseUi) {
            switch ($Key) {
                "titleSuffix" { return "桌面宠物" }
                "startup" { return "我上线了。壁纸判断：$(Get-SceneLabel -Scene $wallpaperSense.scene -Language $script:uiLanguage)。你可以拖动我，也可以直接打字。" }
                "intro" { return "我是$($character.name)。第一版在线：会移动、聊天、说话，也会粗略感知壁纸氛围。" }
                "inputTooltip" { return "输入一句话" }
                "send" { return "发送" }
                "exit" { return "退出" }
                "listen" { return "听" }
                "mute" { return "静音" }
                "voice" { return "语音" }
                "pause" { return "暂停" }
                "auto" { return "自动" }
                "reset" { return "复位" }
                "profile" { return "档案" }
                "language" { return "EN" }
                "hide" { return "隐藏" }
                "resetPosition" { return "复位位置" }
                "toggleTopmost" { return "切换置顶" }
                "toggleAutonomy" { return "暂停/恢复自动行为" }
                "toggleVoice" { return "切换语音" }
                "minimize" { return "最小化" }
                "show" { return "显示" }
                "thinking" { return "正在想：{0}" }
                "voiceBack" { return "语音回来了。" }
                "voiceQuiet" { return "我先安静，用文字交流。" }
                "profileTitle" { return "角色档案" }
                "positionReset" { return "位置复位。我回到默认角落附近了。" }
                "topmostOn" { return "置顶模式已开启。" }
                "topmostOff" { return "置顶模式已关闭。" }
                "autonomyOn" { return "自动行为已开启。我会小范围活动。" }
                "autonomyOff" { return "自动行为已暂停。我先待着不乱动。" }
                "listenUnavailable" { return "没有找到可用的语音识别组件。文字聊天仍然可用，语音合成也可能可用。" }
                "listening" { return "正在听。第一版语法很小：可以试试 hello、who are you、wallpaper 或 rest。" }
                "listenMiss" { return "我没听清。第一版耳朵还比较挑。" }
                "patrol1" { return "我刚做了一次小小桌面巡逻。" }
                "patrol2" { return "现在壁纸像$(Get-SceneLabel -Scene $wallpaperSense.scene -Language $script:uiLanguage)，我会先按这个氛围行动。" }
                "patrol3" { return "行为包已加载。我正在学习如何不打扰地陪着你。" }
                "patrol4" { return "我刚才非常认真地发了一小会儿呆。" }
                default { return $Key }
            }
        }

        switch ($Key) {
            "titleSuffix" { return "Desktop Pet" }
            "startup" { return "I am online. Wallpaper guess: $($wallpaperSense.scene). You can drag me around or type to me." }
            "intro" { return "I am $($character.name). First version online: moving, chatting, speaking, and reading wallpaper mood." }
            "inputTooltip" { return "Type a message for the pet" }
            "send" { return "Send" }
            "exit" { return "Exit" }
            "listen" { return "Listen" }
            "mute" { return "Mute" }
            "voice" { return "Voice" }
            "pause" { return "Pause" }
            "auto" { return "Auto" }
            "reset" { return "Reset" }
            "profile" { return "Profile" }
            "language" { return "中文" }
            "hide" { return "Hide" }
            "resetPosition" { return "Reset position" }
            "toggleTopmost" { return "Toggle topmost" }
            "toggleAutonomy" { return "Pause or resume autonomy" }
            "toggleVoice" { return "Toggle voice" }
            "minimize" { return "Minimize" }
            "show" { return "Show" }
            "thinking" { return "Thinking about: {0}" }
            "voiceBack" { return "Voice is back." }
            "voiceQuiet" { return "I will stay quiet and use text only." }
            "profileTitle" { return "Character Profile" }
            "positionReset" { return "Position reset. I am back near the default corner." }
            "topmostOn" { return "Topmost mode is on." }
            "topmostOff" { return "Topmost mode is off." }
            "autonomyOn" { return "Autonomy is on. I will move around a little." }
            "autonomyOff" { return "Autonomy is paused. I will stay put." }
            "listenUnavailable" { return "No usable speech recognition component was found. Text chat still works, and speech synthesis may still work." }
            "listening" { return "Listening. First-version grammar is tiny: try hello, who are you, wallpaper, or rest." }
            "listenMiss" { return "I did not catch that. My first-version ears are still picky." }
            "patrol1" { return "I made a tiny desktop patrol." }
            "patrol2" { return "Wallpaper scene is currently $($wallpaperSense.scene), so I will act with that mood for now." }
            "patrol3" { return "First-version behavior packs are loaded. I am learning how to stay pleasantly unobtrusive." }
            "patrol4" { return "I just stared into space with great seriousness." }
            default { return $Key }
        }
    }

    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Speech -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

    $speechSynth = $null
    $script:speechRecognizer = $null
    $script:voiceEnabled = $true

    try {
        $speechSynth = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $speechSynth.Rate = [int]$settings.voice.rate
        $speechSynth.Volume = [int]$settings.voice.volume
    } catch {
        $script:voiceEnabled = $false
    }
    $script:voiceEnabled = [bool]$settings.voice.synthesisEnabled -and $script:voiceEnabled

    $window = New-Object System.Windows.Window
    $window.Title = "$($character.name) " + (T "titleSuffix")
    $window.Width = [double]$settings.window.width
    $window.Height = [double]$settings.window.height
    $window.WindowStyle = "None"
    $window.ResizeMode = "NoResize"
    $window.AllowsTransparency = $true
    $window.Background = [System.Windows.Media.Brushes]::Transparent
    $window.Topmost = [bool]$settings.window.topmost
    $window.ShowInTaskbar = [bool]$settings.window.showInTaskbar
    $initialPosition = Get-InitialWindowPosition -Settings $settings -Width $window.Width -Height $window.Height
    $window.Left = $initialPosition.left
    $window.Top = $initialPosition.top

    $root = New-Object System.Windows.Controls.Grid
    $root.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = "82" }))
    $root.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = "168" }))
    $root.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = "80" }))
    $window.Content = $root

    $bubble = New-Object System.Windows.Controls.Border
    $bubble.Margin = "8,4,8,4"
    $bubble.Padding = "12,8,12,8"
    $bubble.CornerRadius = "12"
    $bubble.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(224, 255, 255, 255))
    $bubble.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(175, 92, 112, 132))
    $bubble.BorderThickness = "1"
    [System.Windows.Controls.Grid]::SetRow($bubble, 0)
    $root.Children.Add($bubble) | Out-Null

    $bubbleText = New-Object System.Windows.Controls.TextBlock
    $bubbleText.FontSize = 13
    $bubbleText.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(31, 41, 55))
    $bubbleText.TextWrapping = "Wrap"
    $bubbleText.Text = T "intro"
    $bubble.Child = $bubbleText

    $petCanvas = New-Object System.Windows.Controls.Canvas
    $petCanvas.Width = 220
    $petCanvas.Height = 170
    $petCanvas.HorizontalAlignment = "Center"
    $petCanvas.VerticalAlignment = "Center"
    [System.Windows.Controls.Grid]::SetRow($petCanvas, 1)
    $root.Children.Add($petCanvas) | Out-Null

    $shadow = New-Object System.Windows.Shapes.Ellipse
    $shadow.Width = 138
    $shadow.Height = 24
    $shadow.Fill = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(65, 30, 41, 59))
    [System.Windows.Controls.Canvas]::SetLeft($shadow, 51)
    [System.Windows.Controls.Canvas]::SetTop($shadow, 142)
    $petCanvas.Children.Add($shadow) | Out-Null

    $body = New-Object System.Windows.Shapes.Ellipse
    $body.Width = 112
    $body.Height = 108
    $body.Fill = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(125, 211, 252))
    $body.Stroke = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(14, 116, 144))
    $body.StrokeThickness = 3
    [System.Windows.Controls.Canvas]::SetLeft($body, 59)
    [System.Windows.Controls.Canvas]::SetTop($body, 46)
    $petCanvas.Children.Add($body) | Out-Null

    $face = New-Object System.Windows.Shapes.Ellipse
    $face.Width = 88
    $face.Height = 70
    $face.Fill = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(210, 240, 253, 255))
    [System.Windows.Controls.Canvas]::SetLeft($face, 71)
    [System.Windows.Controls.Canvas]::SetTop($face, 72)
    $petCanvas.Children.Add($face) | Out-Null

    $leftEye = New-Object System.Windows.Shapes.Ellipse
    $leftEye.Width = 12
    $leftEye.Height = 18
    $leftEye.Fill = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(15, 23, 42))
    [System.Windows.Controls.Canvas]::SetLeft($leftEye, 92)
    [System.Windows.Controls.Canvas]::SetTop($leftEye, 94)
    $petCanvas.Children.Add($leftEye) | Out-Null

    $rightEye = New-Object System.Windows.Shapes.Ellipse
    $rightEye.Width = 12
    $rightEye.Height = 18
    $rightEye.Fill = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(15, 23, 42))
    [System.Windows.Controls.Canvas]::SetLeft($rightEye, 130)
    [System.Windows.Controls.Canvas]::SetTop($rightEye, 94)
    $petCanvas.Children.Add($rightEye) | Out-Null

    $mouth = New-Object System.Windows.Shapes.Path
    $mouth.Stroke = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(15, 23, 42))
    $mouth.StrokeThickness = 2
    $mouth.Data = [System.Windows.Media.Geometry]::Parse("M 105 122 Q 116 132 128 122")
    $petCanvas.Children.Add($mouth) | Out-Null

    $antenna = New-Object System.Windows.Shapes.Path
    $antenna.Stroke = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(14, 116, 144))
    $antenna.StrokeThickness = 3
    $antenna.Data = [System.Windows.Media.Geometry]::Parse("M 116 48 C 112 28 132 26 128 12")
    $petCanvas.Children.Add($antenna) | Out-Null

    $spark = New-Object System.Windows.Shapes.Ellipse
    $spark.Width = 14
    $spark.Height = 14
    $spark.Fill = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(250, 204, 21))
    [System.Windows.Controls.Canvas]::SetLeft($spark, 123)
    [System.Windows.Controls.Canvas]::SetTop($spark, 5)
    $petCanvas.Children.Add($spark) | Out-Null

    $characterImage = $null
    if (-not [string]::IsNullOrWhiteSpace($characterImagePath) -and (Test-Path $characterImagePath)) {
        try {
            $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
            $bitmap.BeginInit()
            $bitmap.UriSource = New-Object System.Uri -ArgumentList $characterImagePath
            $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bitmap.EndInit()

            $characterImage = New-Object System.Windows.Controls.Image
            $characterImage.Source = $bitmap
            $characterImage.Width = 144
            $characterImage.Height = 168
            $characterImage.Stretch = [System.Windows.Media.Stretch]::Uniform
            [System.Windows.Controls.Canvas]::SetLeft($characterImage, 38)
            [System.Windows.Controls.Canvas]::SetTop($characterImage, 0)
            $petCanvas.Children.Add($characterImage) | Out-Null

            $body.Visibility = "Hidden"
            $face.Visibility = "Hidden"
            $leftEye.Visibility = "Hidden"
            $rightEye.Visibility = "Hidden"
            $mouth.Visibility = "Hidden"
            $antenna.Visibility = "Hidden"
            $spark.Visibility = "Hidden"
        } catch {
            $characterImage = $null
        }
    }

    $controlPanel = New-Object System.Windows.Controls.Border
    $controlPanel.Margin = "8,2,8,8"
    $controlPanel.Padding = "6"
    $controlPanel.CornerRadius = "10"
    $controlPanel.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(235, 248, 250, 252))
    $controlPanel.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(130, 148, 163, 184))
    $controlPanel.BorderThickness = "1"
    [System.Windows.Controls.Grid]::SetRow($controlPanel, 2)
    $root.Children.Add($controlPanel) | Out-Null

    $panelGrid = New-Object System.Windows.Controls.Grid
    $controlPanel.Child = $panelGrid

    $panelGrid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = "32" }))
    $panelGrid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = "32" }))

    $topGrid = New-Object System.Windows.Controls.Grid
    $topGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "*" }))
    $topGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "58" }))
    $topGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "52" }))
    [System.Windows.Controls.Grid]::SetRow($topGrid, 0)
    $panelGrid.Children.Add($topGrid) | Out-Null

    $bottomGrid = New-Object System.Windows.Controls.Grid
    $bottomGrid.Margin = "0,4,0,0"
    $bottomGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "62" }))
    $bottomGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "60" }))
    $bottomGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "60" }))
    $bottomGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "62" }))
    $bottomGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "68" }))
    $bottomGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "54" }))
    [System.Windows.Controls.Grid]::SetRow($bottomGrid, 1)
    $panelGrid.Children.Add($bottomGrid) | Out-Null

    $inputBox = New-Object System.Windows.Controls.TextBox
    $inputBox.FontSize = 13
    $inputBox.Margin = "0,0,6,0"
    $inputBox.VerticalContentAlignment = "Center"
    $inputBox.Text = ""
    $inputBox.ToolTip = T "inputTooltip"
    [System.Windows.Controls.Grid]::SetColumn($inputBox, 0)
    $topGrid.Children.Add($inputBox) | Out-Null

    $sendButton = New-Object System.Windows.Controls.Button
    $sendButton.Content = T "send"
    $sendButton.Margin = "0,0,6,0"
    $sendButton.ToolTip = T "send"
    [System.Windows.Controls.Grid]::SetColumn($sendButton, 1)
    $topGrid.Children.Add($sendButton) | Out-Null

    $exitButton = New-Object System.Windows.Controls.Button
    $exitButton.Content = T "exit"
    $exitButton.ToolTip = T "exit"
    [System.Windows.Controls.Grid]::SetColumn($exitButton, 2)
    $topGrid.Children.Add($exitButton) | Out-Null

    $listenButton = New-Object System.Windows.Controls.Button
    $listenButton.Content = T "listen"
    $listenButton.Margin = "0,0,6,0"
    $listenButton.ToolTip = T "listen"
    [System.Windows.Controls.Grid]::SetColumn($listenButton, 0)
    $bottomGrid.Children.Add($listenButton) | Out-Null

    $voiceButton = New-Object System.Windows.Controls.Button
    $voiceButton.Content = T "mute"
    $voiceButton.Margin = "0,0,6,0"
    $voiceButton.ToolTip = T "toggleVoice"
    [System.Windows.Controls.Grid]::SetColumn($voiceButton, 1)
    $bottomGrid.Children.Add($voiceButton) | Out-Null

    $autonomyButton = New-Object System.Windows.Controls.Button
    $autonomyButton.Content = T "pause"
    $autonomyButton.Margin = "0,0,6,0"
    $autonomyButton.ToolTip = T "toggleAutonomy"
    [System.Windows.Controls.Grid]::SetColumn($autonomyButton, 2)
    $bottomGrid.Children.Add($autonomyButton) | Out-Null

    $resetButton = New-Object System.Windows.Controls.Button
    $resetButton.Content = T "reset"
    $resetButton.Margin = "0,0,6,0"
    $resetButton.ToolTip = T "resetPosition"
    [System.Windows.Controls.Grid]::SetColumn($resetButton, 3)
    $bottomGrid.Children.Add($resetButton) | Out-Null

    $profileButton = New-Object System.Windows.Controls.Button
    $profileButton.Content = T "profile"
    $profileButton.ToolTip = T "profileTitle"
    [System.Windows.Controls.Grid]::SetColumn($profileButton, 4)
    $bottomGrid.Children.Add($profileButton) | Out-Null

    $languageButton = New-Object System.Windows.Controls.Button
    $languageButton.Content = T "language"
    $languageButton.ToolTip = "Language"
    [System.Windows.Controls.Grid]::SetColumn($languageButton, 5)
    $bottomGrid.Children.Add($languageButton) | Out-Null

    $state = [ordered]@{
        mode = "idle"
        tick = 0
        bob = 0.0
        moveX = 0.0
        moveY = 0.0
        nextActionTick = 120
        isSpeaking = $false
        activeMessage = ""
        autonomyEnabled = [bool]$settings.autonomy.enabled
        exitRequested = $false
    }

    if ($state.autonomyEnabled) {
        $autonomyButton.Content = T "pause"
    } else {
        $autonomyButton.Content = T "auto"
    }

    function Apply-UiLanguage {
        $window.Title = "$($character.name) " + (T "titleSuffix")
        $inputBox.ToolTip = T "inputTooltip"
        $sendButton.Content = T "send"
        $sendButton.ToolTip = T "send"
        $exitButton.Content = T "exit"
        $exitButton.ToolTip = T "exit"
        $listenButton.Content = T "listen"
        $listenButton.ToolTip = T "listen"
        $voiceButton.Content = if ($script:voiceEnabled) { T "mute" } else { T "voice" }
        $voiceButton.ToolTip = T "toggleVoice"
        $autonomyButton.Content = if ($state.autonomyEnabled) { T "pause" } else { T "auto" }
        $autonomyButton.ToolTip = T "toggleAutonomy"
        $resetButton.Content = T "reset"
        $resetButton.ToolTip = T "resetPosition"
        $profileButton.Content = T "profile"
        $profileButton.ToolTip = T "profileTitle"
        $languageButton.Content = T "language"
    }

    function Set-BubbleText {
        param([string]$Text)
        $bubbleText.Text = $Text
    }

    function Set-PetMode {
        param([string]$Mode)
        $state.mode = $Mode

        switch ($Mode) {
            "thinking" {
                $body.Fill = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(167, 139, 250))
                $mouth.Data = [System.Windows.Media.Geometry]::Parse("M 106 124 Q 116 118 127 124")
            }
            "speaking" {
                $body.Fill = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(52, 211, 153))
                $mouth.Data = [System.Windows.Media.Geometry]::Parse("M 105 121 Q 116 137 129 121")
            }
            "sleeping" {
                $body.Fill = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(147, 197, 253))
                $mouth.Data = [System.Windows.Media.Geometry]::Parse("M 106 124 Q 116 127 127 124")
            }
            "excited" {
                $body.Fill = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(251, 191, 36))
                $mouth.Data = [System.Windows.Media.Geometry]::Parse("M 105 120 Q 116 136 129 120")
            }
            default {
                $body.Fill = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(125, 211, 252))
                $mouth.Data = [System.Windows.Media.Geometry]::Parse("M 105 122 Q 116 132 128 122")
            }
        }
    }

    function Speak-Pet {
        param([string]$Text)

        Set-BubbleText -Text $Text
        Set-PetMode -Mode "speaking"

        if ($script:voiceEnabled -and $null -ne $speechSynth) {
            try {
                $speechSynth.SpeakAsyncCancelAll() | Out-Null
                $speechSynth.SpeakAsync($Text) | Out-Null
            } catch {
                Set-BubbleText -Text "$Text`n`nSpeech synthesis is not available right now: $($_.Exception.Message)"
            }
        }
    }

    function Show-PetWindow {
        $window.Show()
        if ($window.WindowState -eq "Minimized") {
            $window.WindowState = "Normal"
        }
        $window.Activate() | Out-Null
    }

    function Hide-PetWindow {
        if ($settings.window.rememberPosition -and $window.WindowState -eq "Normal") {
            Save-WindowState -Window $window
        }
        $window.Hide()
    }

    function Reset-PetPosition {
        $position = Get-DefaultWindowPosition -Settings $settings -Width $window.Width -Height $window.Height
        $window.Left = $position.left
        $window.Top = $position.top
        if ($settings.window.rememberPosition) {
            Save-WindowState -Window $window
        }
        Speak-Pet -Text (T "positionReset")
    }

    function Toggle-Topmost {
        $window.Topmost = -not $window.Topmost
        if ($window.Topmost) {
            Speak-Pet -Text (T "topmostOn")
        } else {
            Speak-Pet -Text (T "topmostOff")
        }
    }

    function Toggle-Autonomy {
        $state.autonomyEnabled = -not $state.autonomyEnabled
        if ($state.autonomyEnabled) {
            Speak-Pet -Text (T "autonomyOn")
        } else {
            Set-PetMode -Mode "idle"
            Speak-Pet -Text (T "autonomyOff")
        }
    }

    function Send-UserMessage {
        $message = $inputBox.Text
        if ([string]::IsNullOrWhiteSpace($message)) {
            return
        }

        $inputBox.Text = ""
        Set-PetMode -Mode "thinking"
        Set-BubbleText -Text ([string]::Format((T "thinking"), $message))

        $thinkTimer = New-Object System.Windows.Threading.DispatcherTimer
        $thinkTimer.Interval = [TimeSpan]::FromMilliseconds(520)
        $thinkTimer.Add_Tick({
            $thinkTimer.Stop()
            $nickname = Get-NicknameFromInput -Text $message
            if (-not [string]::IsNullOrWhiteSpace($nickname)) {
                Set-MemoryValue -Memory $petMemory -Name "userName" -Value $nickname
                Save-PetMemory -Memory $petMemory
            }

            $reply = Get-PetReply -InputText $message -Character $character -WallpaperSense $wallpaperSense -Language $script:uiLanguage -Settings $settings -PetMemory $petMemory -RecentTurns $script:recentTurns
            $script:recentTurns += [pscustomobject]@{
                role = "user"
                content = $message
            }
            $script:recentTurns += [pscustomobject]@{
                role = "assistant"
                content = $reply
            }
            if ($script:recentTurns.Count -gt 12) {
                $script:recentTurns = @($script:recentTurns | Select-Object -Last 12)
            }
            Speak-Pet -Text $reply
        })
        $thinkTimer.Start()
    }

    function Start-ListenOnce {
        if ($null -eq ([type]::GetType("System.Speech.Recognition.SpeechRecognitionEngine, System.Speech"))) {
            Speak-Pet -Text (T "listenUnavailable")
            return
        }

        try {
            if ($null -eq $script:speechRecognizer) {
                $script:speechRecognizer = New-Object System.Speech.Recognition.SpeechRecognitionEngine
                $choices = New-Object System.Speech.Recognition.Choices
                $choices.Add("hello")
                $choices.Add("who are you")
                $choices.Add("wallpaper")
                $choices.Add("rest")
                $grammarBuilder = New-Object System.Speech.Recognition.GrammarBuilder
                $grammarBuilder.Culture = $script:speechRecognizer.RecognizerInfo.Culture
                $grammarBuilder.Append($choices)
                $grammar = New-Object System.Speech.Recognition.Grammar($grammarBuilder)
                $script:speechRecognizer.LoadGrammar($grammar)
                $script:speechRecognizer.SetInputToDefaultAudioDevice()
            }

            Set-PetMode -Mode "thinking"
            Set-BubbleText -Text (T "listening")
            $result = $script:speechRecognizer.Recognize([TimeSpan]::FromSeconds(5))
            if ($null -eq $result) {
                Speak-Pet -Text (T "listenMiss")
            } else {
                $inputBox.Text = $result.Text
                Send-UserMessage
            }
        } catch {
            Speak-Pet -Text "Speech recognition failed to start: $($_.Exception.Message)"
        }
    }

    $sendButton.Add_Click({ Send-UserMessage })
    $inputBox.Add_KeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.Key -eq "Return") {
            Send-UserMessage
            $eventArgs.Handled = $true
        }
    })

    $listenButton.Add_Click({ Start-ListenOnce })

    $resetButton.Add_Click({ Reset-PetPosition })

    $autonomyButton.Add_Click({
        Toggle-Autonomy
        if ($state.autonomyEnabled) {
            $autonomyButton.Content = T "pause"
            if ($null -ne $autonomyItem) {
                $autonomyItem.Header = T "toggleAutonomy"
            }
        } else {
            $autonomyButton.Content = T "auto"
            if ($null -ne $autonomyItem) {
                $autonomyItem.Header = T "toggleAutonomy"
            }
        }
    })

    $exitButton.Add_Click({
        $state.exitRequested = $true
        $window.Close()
    })

    $voiceButton.Add_Click({
        $script:voiceEnabled = -not $script:voiceEnabled
        if ($script:voiceEnabled) {
            $voiceButton.Content = T "mute"
            Speak-Pet -Text (T "voiceBack")
        } else {
            $voiceButton.Content = T "voice"
            if ($null -ne $speechSynth) {
                $speechSynth.SpeakAsyncCancelAll() | Out-Null
            }
            Set-BubbleText -Text (T "voiceQuiet")
        }
    })

    $languageButton.Add_Click({
        if (Use-ChineseUi) {
            $script:uiLanguage = "en-US"
        } else {
            $script:uiLanguage = "zh-CN"
        }
        Apply-UiLanguage
        if (Use-ChineseUi) {
            Speak-Pet -Text "已切换到中文。"
        } else {
            Speak-Pet -Text "Switched to English."
        }
    })

    $profileButton.Add_Click({
        $traits = ($character.personality -join " / ")
        $packNames = ($behaviorPacks | ForEach-Object { $_.name }) -join ", "
        if (Use-ChineseUi) {
            $summary = "角色：$($character.name)`n性格：$traits`n行为包：$packNames`n壁纸：$(Get-SceneLabel -Scene $wallpaperSense.scene -Language $script:uiLanguage) - $($wallpaperSense.reason)"
        } else {
            $summary = "Character: $($character.name)`nTraits: $traits`nBehavior packs: $packNames`nWallpaper: $($wallpaperSense.scene) - $($wallpaperSense.reason)"
        }
        [System.Windows.MessageBox]::Show($summary, (T "profileTitle"), "OK", "Information") | Out-Null
    })

    $petCanvas.Add_MouseLeftButtonDown({
        try {
            $window.DragMove()
        } catch {}
    })

    $contextMenu = New-Object System.Windows.Controls.ContextMenu

    $hideItem = New-Object System.Windows.Controls.MenuItem
    $hideItem.Header = T "hide"
    $hideItem.Add_Click({ Hide-PetWindow })
    $contextMenu.Items.Add($hideItem) | Out-Null

    $resetItem = New-Object System.Windows.Controls.MenuItem
    $resetItem.Header = T "resetPosition"
    $resetItem.Add_Click({ Reset-PetPosition })
    $contextMenu.Items.Add($resetItem) | Out-Null

    $topmostItem = New-Object System.Windows.Controls.MenuItem
    $topmostItem.Header = T "toggleTopmost"
    $topmostItem.Add_Click({ Toggle-Topmost })
    $contextMenu.Items.Add($topmostItem) | Out-Null

    $autonomyItem = New-Object System.Windows.Controls.MenuItem
    $autonomyItem.Header = T "toggleAutonomy"
    $autonomyItem.Add_Click({
        Toggle-Autonomy
        if ($state.autonomyEnabled) {
            $autonomyItem.Header = T "toggleAutonomy"
            $autonomyButton.Content = T "pause"
        } else {
            $autonomyItem.Header = T "toggleAutonomy"
            $autonomyButton.Content = T "auto"
        }
    })
    $contextMenu.Items.Add($autonomyItem) | Out-Null

    $voiceMenuItem = New-Object System.Windows.Controls.MenuItem
    $voiceMenuItem.Header = T "toggleVoice"
    $voiceMenuItem.Add_Click({
        $voiceButton.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
    })
    $contextMenu.Items.Add($voiceMenuItem) | Out-Null

    $contextMenu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null

    $minimizeItem = New-Object System.Windows.Controls.MenuItem
    $minimizeItem.Header = T "minimize"
    $minimizeItem.Add_Click({ $window.WindowState = "Minimized" })
    $contextMenu.Items.Add($minimizeItem) | Out-Null
    $exitItem = New-Object System.Windows.Controls.MenuItem
    $exitItem.Header = T "exit"
    $exitItem.Add_Click({
        $state.exitRequested = $true
        $window.Close()
    })
    $contextMenu.Items.Add($exitItem) | Out-Null
    $root.ContextMenu = $contextMenu

    $trayIcon = $null
    try {
        $trayIcon = New-Object System.Windows.Forms.NotifyIcon
        $trayIcon.Text = "$($character.name) " + (T "titleSuffix")
        $trayIcon.Icon = [System.Drawing.SystemIcons]::Application
        $trayIcon.Visible = $true

        $trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
        $trayShowItem = $trayMenu.Items.Add((T "show"))
        $trayShowItem.add_Click({ $window.Dispatcher.Invoke([Action]{ Show-PetWindow }) })
        $trayHideItem = $trayMenu.Items.Add((T "hide"))
        $trayHideItem.add_Click({ $window.Dispatcher.Invoke([Action]{ Hide-PetWindow }) })
        $trayResetItem = $trayMenu.Items.Add((T "resetPosition"))
        $trayResetItem.add_Click({ $window.Dispatcher.Invoke([Action]{ Reset-PetPosition }) })
        $trayMenu.Items.Add("-") | Out-Null
        $trayExitItem = $trayMenu.Items.Add((T "exit"))
        $trayExitItem.add_Click({
            $window.Dispatcher.Invoke([Action]{
                $state.exitRequested = $true
                $window.Close()
            })
        })
        $trayIcon.ContextMenuStrip = $trayMenu
        $trayIcon.add_DoubleClick({ $window.Dispatcher.Invoke([Action]{ Show-PetWindow }) })
    } catch {
        Set-BubbleText -Text "Tray icon is not available: $($_.Exception.Message)"
    }

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(90)
    $timer.Add_Tick({
        $state.tick += 1
        $state.bob = [Math]::Sin($state.tick / 4.2)

        $top = 46 + ($state.bob * 3)
        if ($state.mode -eq "sleeping") {
            $top = 82 + ([Math]::Sin($state.tick / 8.0) * 1.2)
            $body.Height = 82
            $face.Height = 52
            [System.Windows.Controls.Canvas]::SetTop($face, $top + 22)
        } else {
            $body.Height = 108
            $face.Height = 70
            [System.Windows.Controls.Canvas]::SetTop($face, $top + 26)
        }

        [System.Windows.Controls.Canvas]::SetTop($body, $top)
        [System.Windows.Controls.Canvas]::SetTop($leftEye, $top + 48)
        [System.Windows.Controls.Canvas]::SetTop($rightEye, $top + 48)
        if ($null -ne $characterImage) {
            [System.Windows.Controls.Canvas]::SetTop($characterImage, [Math]::Max(-6, $top - 48))
        }

        if ($state.mode -eq "speaking" -and ($state.tick % 6 -lt 3)) {
            $mouth.Data = [System.Windows.Media.Geometry]::Parse("M 105 121 Q 116 137 129 121")
        } elseif ($state.mode -eq "speaking") {
            $mouth.Data = [System.Windows.Media.Geometry]::Parse("M 105 123 Q 116 128 129 123")
        }

        if ($state.tick -ge $state.nextActionTick) {
            if (-not [bool]$state.autonomyEnabled) {
                $state.nextActionTick = $state.tick + 60
                return
            }

            $energy = Get-BiasValue -Character $character -Name "energy" -Default 0.5
            $playfulness = Get-BiasValue -Character $character -Name "playfulness" -Default 0.5
            $calmness = Get-BiasValue -Character $character -Name "calmness" -Default 0.5
            $roll = Get-Random -Minimum 0.0 -Maximum 1.0

            if ($roll -lt (0.18 + ($playfulness * 0.18))) {
                Set-PetMode -Mode "excited"
                $jump = [Math]::Min(24, 8 + ($energy * 18))
                $nextPosition = Limit-WindowPosition -Left $window.Left -Top ($window.Top - $jump) -Width $window.Width -Height $window.Height
                $window.Left = $nextPosition.left
                $window.Top = $nextPosition.top
                $state.nextActionTick = $state.tick + (Get-Random -Minimum 18 -Maximum 34)
            } elseif ($roll -lt (0.48 + ($energy * 0.14))) {
                Set-PetMode -Mode "idle"
                $delta = Get-Random -Minimum -28 -Maximum 29
                $nextPosition = Limit-WindowPosition -Left ($window.Left + $delta) -Top $window.Top -Width $window.Width -Height $window.Height
                $window.Left = $nextPosition.left
                $window.Top = $nextPosition.top
                $state.nextActionTick = $state.tick + (Get-Random -Minimum 35 -Maximum 72)
            } elseif ($roll -gt (0.88 - ($calmness * 0.18))) {
                Set-PetMode -Mode "sleeping"
                $state.nextActionTick = $state.tick + (Get-Random -Minimum 48 -Maximum 95)
            } else {
                Set-PetMode -Mode "idle"
                $state.nextActionTick = $state.tick + (Get-Random -Minimum 40 -Maximum 90)
            }

            if ((Get-Random -Minimum 0.0 -Maximum 1.0) -lt [double]$settings.autonomy.messageChance) {
                $lines = @(
                    (T "patrol1"),
                    (T "patrol2"),
                    (T "patrol3"),
                    (T "patrol4")
                )
                Set-BubbleText -Text $lines[(Get-Random -Minimum 0 -Maximum $lines.Count)]
            }
        }

        if ($state.mode -eq "excited" -and $state.tick % 12 -eq 0) {
            Set-PetMode -Mode "idle"
        }
    })

    $window.Add_Closed({
        $timer.Stop()
        if ($settings.window.rememberPosition) {
            Save-WindowState -Window $window
        }
        if ($null -ne $trayIcon) {
            $trayIcon.Visible = $false
            $trayIcon.Dispose()
        }
        if ($null -ne $speechSynth) {
            $speechSynth.SpeakAsyncCancelAll() | Out-Null
            $speechSynth.Dispose()
        }
        if ($null -ne $script:speechRecognizer) {
            $script:speechRecognizer.Dispose()
        }
    })

    $timer.Start()
    Apply-UiLanguage
    Speak-Pet -Text (T "startup")
    $window.ShowDialog() | Out-Null
}

function Invoke-SelfTest {
    $settings = Get-AppSettings
    $preflight = Get-WindowsPreflightReport -Settings $settings
    $character = $null
    $characterLoadError = $null
    try {
        $character = Get-CharacterProfile -Settings $settings
    } catch {
        $characterLoadError = $_.Exception.Message
    }
    $characterPath = Get-ActiveCharacterPath -Settings $settings
    $characterImageInfo = Get-CharacterImageInfo -Settings $settings
    $characterImagePath = $characterImageInfo.path
    $packs = Get-BehaviorPacks -Path $BehaviorDir
    $wallpaper = Get-WallpaperSense
    $brainSettings = Get-ObjectProperty -Object $settings -Name "brain"
    $anthropicSettings = Get-ObjectProperty -Object $brainSettings -Name "anthropic"
    $anthropicRuntime = Get-AnthropicRuntimeReport -Settings $settings
    $anthropicRequestReport = Get-LastAnthropicRequestReport
    $resolvedPromptZh = Resolve-WindowsSystemPrompt -AnthropicSettings $anthropicSettings -Language "zh-CN"
    $resolvedPromptEn = Resolve-WindowsSystemPrompt -AnthropicSettings $anthropicSettings -Language "en"

    $result = [ordered]@{
        character = if ($null -ne $character) { $character.name } else { $null }
        characterLoadError = $characterLoadError
        activeCharacterPath = $characterPath
        activeCharacterPack = Get-ObjectProperty -Object (Get-ObjectProperty -Object $settings -Name "character") -Name "activePack" -Default ""
        activeCharacterImagePath = $characterImagePath
        activeCharacterImageVariant = $characterImageInfo.variant
        characterImageLoaded = (-not [string]::IsNullOrWhiteSpace($characterImagePath)) -and (Test-Path $characterImagePath)
        idleImageLoaded = $characterImageInfo.variant -eq "idle"
        brainProvider = Get-ObjectProperty -Object $brainSettings -Name "provider" -Default "template"
        anthropicRuntimeChecksApplied = $anthropicRuntime.checksApplied
        anthropicRuntimeReady = $anthropicRuntime.requestReady
        anthropicRuntimeIssues = @($anthropicRuntime.issues)
        anthropicBaseUrl = $anthropicRuntime.baseURL
        anthropicBaseUrlValid = $anthropicRuntime.baseURLValid
        anthropicBaseUrlScheme = $anthropicRuntime.baseURLScheme
        anthropicModel = $anthropicRuntime.model
        anthropicModelConfigured = $anthropicRuntime.modelConfigured
        anthropicMaxTokens = $anthropicRuntime.maxTokens
        anthropicMaxTokensValid = $anthropicRuntime.maxTokensValid
        anthropicTimeoutSeconds = $anthropicRuntime.timeoutSeconds
        anthropicTimeoutSecondsValid = $anthropicRuntime.timeoutSecondsValid
        anthropicApiKeyEnv = $anthropicRuntime.apiKeyEnv
        anthropicApiKeyResolvedEnv = $anthropicRuntime.apiKeyResolvedEnv
        anthropicApiKeySource = $anthropicRuntime.apiKeySource
        anthropicApiKeyProfilePath = $anthropicRuntime.apiKeyProfilePath
        anthropicRequestDiagnosticsAvailable = $anthropicRequestReport.diagnosticsAvailable
        anthropicLastRequestAttempted = $anthropicRequestReport.attempted
        anthropicLastRequestSucceeded = $anthropicRequestReport.succeeded
        anthropicLastRequestFailureCode = $anthropicRequestReport.failureCode
        anthropicLastRequestFailureMessage = $anthropicRequestReport.failureMessage
        anthropicLastRequestHttpStatus = $anthropicRequestReport.httpStatus
        anthropicLastRequestExceptionType = $anthropicRequestReport.exceptionType
        anthropicLastRequestBaseUrl = $anthropicRequestReport.baseURL
        anthropicLastRequestModel = $anthropicRequestReport.model
        anthropicLastRequestStartedAtUtc = $anthropicRequestReport.startedAtUtc
        anthropicLastRequestCompletedAtUtc = $anthropicRequestReport.completedAtUtc
        anthropicLastRequestDurationMs = $anthropicRequestReport.durationMs
        anthropicLastRequestTimeoutSeconds = $anthropicRequestReport.timeoutSeconds
        anthropicSystemPromptZhSource = $resolvedPromptZh.source
        anthropicSystemPromptZhAdjusted = $resolvedPromptZh.adjusted
        anthropicSystemPromptZhOriginalPlatform = $resolvedPromptZh.originalPlatform
        anthropicSystemPromptZhEffectivePlatform = $resolvedPromptZh.effectivePlatform
        anthropicSystemPromptEnSource = $resolvedPromptEn.source
        anthropicSystemPromptEnAdjusted = $resolvedPromptEn.adjusted
        anthropicSystemPromptEnOriginalPlatform = $resolvedPromptEn.originalPlatform
        anthropicSystemPromptEnEffectivePlatform = $resolvedPromptEn.effectivePlatform
        anthropicApiConfigured = $anthropicRuntime.apiKeyConfigured
        preflightReady = $preflight.ready
        preflightBlockingIssues = @($preflight.blockingIssues)
        preflightWarnings = @($preflight.warnings)
        preflightIsWindows = $preflight.isWindows
        preflightIsSta = $preflight.isStaThread
        preflightPowerShellEdition = $preflight.powerShellEdition
        preflightPowerShellVersion = $preflight.powerShellVersion
        preflightHostProcess = $preflight.hostProcess
        wpfAssembliesAvailable = $preflight.wpfAssembliesAvailable
        wpfMissingAssemblies = @($preflight.wpfMissingAssemblies)
        wpfAssemblyChecks = @($preflight.wpfAssemblyChecks)
        behaviorPackCount = $packs.Count
        behaviorPacks = @($packs | ForEach-Object { $_.id })
        settingsLoaded = $null -ne $settings
        stateDirectory = $StateDir
        windowStatePath = $WindowStatePath
        petMemoryPath = $PetMemoryPath
        wallpaperScene = $wallpaper.scene
        wallpaperReason = $wallpaper.reason
        speechSynthesisAvailable = $false
        speechRecognitionAvailable = $false
        features = @(
            "activeCharacterPack",
            "xiaoqiIdleImageRender",
            "characterImageSourceFallback",
            "settingsNormalization",
            "anthropicCompatibleBrain",
            "anthropicRuntimeReadiness",
            "anthropicRequestDiagnostics",
            "anthropicRequestTimeoutSurface",
            "platformPromptNormalization",
            "startupPreflight",
            "conversationHistoryRuntime",
            "nicknameMemory"
        )
    }

    try {
        Add-Type -AssemblyName System.Speech -ErrorAction Stop
        $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $result.speechSynthesisAvailable = $true
        $synth.Dispose()
        $result.speechRecognitionAvailable = $null -ne ([type]::GetType("System.Speech.Recognition.SpeechRecognitionEngine, System.Speech"))
    } catch {
        $result.speechSynthesisAvailable = $false
    }

    $result | ConvertTo-Json -Depth 5
}

if ($SelfTest) {
    Invoke-SelfTest
} else {
    Start-DesktopPet
}
