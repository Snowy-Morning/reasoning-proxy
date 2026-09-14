Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class ProxyGuiSingleInstance {
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    public static IntPtr FindProxyWindow() {
        IntPtr result = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            var title = new StringBuilder(256);
            GetWindowText(hWnd, title, title.Capacity);
            if (title.ToString() == "Reasoning Proxy") {
                result = hWnd;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }
}
'@

$existingWindow = [ProxyGuiSingleInstance]::FindProxyWindow()
if ($existingWindow -ne [IntPtr]::Zero) {
    [ProxyGuiSingleInstance]::ShowWindow($existingWindow, 9) | Out-Null
    [ProxyGuiSingleInstance]::SetForegroundWindow($existingWindow) | Out-Null
    exit 0
}

$script:mutexCreatedNew = $false
$script:appMutex = New-Object System.Threading.Mutex($false, 'Local\ReasoningProxyGui', [ref]$script:mutexCreatedNew)
if (-not $script:mutexCreatedNew) {
    $existingWindow = [ProxyGuiSingleInstance]::FindProxyWindow()
    if ($existingWindow -ne [IntPtr]::Zero) {
        [ProxyGuiSingleInstance]::ShowWindow($existingWindow, 9) | Out-Null
        [ProxyGuiSingleInstance]::SetForegroundWindow($existingWindow) | Out-Null
    }
    exit 0
}

$script:RuntimeRoot = if ($env:REASONING_PROXY_RUNTIME_DIR) {
    $env:REASONING_PROXY_RUNTIME_DIR
} else {
    Split-Path -Parent $PSScriptRoot
}
$script:DataRoot = if ($env:REASONING_PROXY_DIR) {
    $env:REASONING_PROXY_DIR
} else {
    $script:RuntimeRoot
}

function Read-Config {
    $configPath = Join-Path $script:DataRoot 'config\config.bat'
    if (-not (Test-Path $configPath)) {
        return @{}
    }

    $config = @{}
    Get-Content -Path $configPath | ForEach-Object {
        if ($_ -match '^\s*set\s+([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$') {
            $config[$Matches[1]] = $Matches[2]
        }
    }
    return $config
}

function Set-ConfigValue([string]$Name, [string]$Value) {
    $configPath = Join-Path $script:DataRoot 'config\config.bat'
    $configDir = Split-Path -Parent $configPath
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    }
    $lines = if (Test-Path $configPath) {
        @([System.IO.File]::ReadAllLines($configPath))
    } else {
        @()
    }
    $pattern = "^set\s+$([regex]::Escape($Name))\s*="
    $updated = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $pattern) {
            $lines[$i] = "set $Name=$Value"
            $updated = $true
            break
        }
    }
    if (-not $updated) {
        $lines += "set $Name=$Value"
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($configPath, $lines, $encoding)
}

function Get-ProxyProcessId {
    $connection = Get-NetTCPConnection -LocalPort $script:Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($connection) {
        return [int]$connection.OwningProcess
    }
    return $null
}

function New-Brush([string]$Hex) {
    return (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Hex)
}

function New-Color([string]$Hex) {
    $value = $Hex.TrimStart('#')
    return [System.Windows.Media.Color]::FromRgb(
        [Convert]::ToInt32($value.Substring(0, 2), 16),
        [Convert]::ToInt32($value.Substring(2, 2), 16),
        [Convert]::ToInt32($value.Substring(4, 2), 16)
    )
}

function Update-Status {
    $processId = Get-ProxyProcessId
    if ($processId) {
        $green = New-Brush '#4ADE80'
        $script:statusDot.Fill = $green
        $script:statusEffect.Color = (New-Color '#4ADE80')
        $script:statusEffect.Opacity = 0.9
        $script:statusText.Text = '运行中'
        $script:statusText.Foreground = $green
        $script:pidText.Text = "PID  $processId"
        $script:startButton.IsEnabled = $false
        $script:stopButton.IsEnabled = $true
        $script:glowStoryboard.Begin()
    } else {
        $muted = New-Brush '#949EB4'
        $script:statusDot.Fill = $muted
        $script:statusEffect.Color = (New-Color '#949EB4')
        $script:statusEffect.Opacity = 0.5
        $script:statusText.Text = '未运行'
        $script:statusText.Foreground = $muted
        $script:pidText.Text = '等待启动'
        $script:startButton.IsEnabled = $true
        $script:stopButton.IsEnabled = $false
        $script:glowStoryboard.Stop()
    }
}

function Start-Proxy {
    $yellow = New-Brush '#FACC15'
    $script:statusDot.Fill = $yellow
    $script:statusEffect.Color = (New-Color '#FACC15')
    $script:statusEffect.Opacity = 0.9
    $script:glowStoryboard.Begin()
    $script:startButton.IsEnabled = $false
    $script:statusText.Text = '正在启动...'
    $script:statusText.Foreground = $yellow
    $script:pidText.Text = '请稍候'
    $logDir = Join-Path $script:DataRoot 'logs'
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    }

    if ($env:REASONING_PROXY_EXE) {
        $env:REASONING_PROXY_DIR = $script:DataRoot
        $env:REASONING_PROXY_FILE_LOG = '1'
        Start-Process -FilePath $env:REASONING_PROXY_EXE -ArgumentList '--proxy' -WorkingDirectory $script:DataRoot -WindowStyle Hidden
    } else {
        $startBat = Join-Path $PSScriptRoot 'start.bat'
        Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$startBat`"" -WorkingDirectory $PSScriptRoot -WindowStyle Hidden
    }
}

function Stop-Proxy {
    $processId = Get-ProxyProcessId
    if ($processId) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 300
    }
    Update-Status
}

function Update-EffortButtons {
    $selectedBrush = New-Brush '#4ADE80'
    $mutedBrush = New-Brush '#949EB4'
    foreach ($button in $script:effortButtons) {
        $isSelected = ($button.Tag -eq $script:reasoningEffort)
        $button.Foreground = if ($isSelected) { $selectedBrush } else { $mutedBrush }
    }
}

function Set-ReasoningEffort([string]$Value) {
    if ($Value -eq $script:reasoningEffort) {
        return
    }
    $script:reasoningEffort = $Value
    Set-ConfigValue 'REASONING_EFFORT' $Value
    Update-EffortButtons
}

function Get-LogText {
    $path = Join-Path $script:DataRoot 'logs\proxy.log'
    if (-not (Test-Path $path)) {
        return '日志文件不存在'
    }

    try {
        $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $reader = New-Object System.IO.StreamReader($stream)
            $content = $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
            $stream.Dispose()
        }

        $lines = $content -split "`r?`n" | Where-Object { $_.Length -gt 0 }
        return ($lines | Select-Object -Last 200) -join "`r`n"
    } catch {
        return "无法读取日志: $($_.Exception.Message)"
    }
}

function Scroll-LogToEnd {
    $script:logTextBox.Dispatcher.InvokeAsync(
        [System.Action] { $script:logTextBox.ScrollToEnd() },
        [System.Windows.Threading.DispatcherPriority]::ApplicationIdle
    ) | Out-Null
}

function Update-LogPanel {
    $text = Get-LogText
    if ($script:logTextBox.Text -ne $text) {
        $script:logTextBox.Text = $text
        $script:logTextBox.UpdateLayout()
        Scroll-LogToEnd
    }
}

function Toggle-LogPanel {
    $script:logPanelVisible = -not $script:logPanelVisible
    if ($script:logPanelVisible) {
        $script:mainPanel.Visibility = [System.Windows.Visibility]::Collapsed
        $script:logPanel.Visibility = [System.Windows.Visibility]::Visible
        $script:logToggleButton.Content = '返回状态'
        Update-LogPanel
        $script:logTextBox.UpdateLayout()
        Scroll-LogToEnd
    } else {
        $script:logPanel.Visibility = [System.Windows.Visibility]::Collapsed
        $script:mainPanel.Visibility = [System.Windows.Visibility]::Visible
        $script:logToggleButton.Content = '查看日志'
    }
}

# chatLanguageModels.json lives outside this project, so every write keeps a
# timestamped copy next to the file first.
$lmScript = Join-Path $PSScriptRoot 'language-models.ps1'
if (Test-Path -LiteralPath $lmScript) {
    . $lmScript
} else {
    Write-Host "[gui] missing language-models.ps1, model sync is unavailable"
}

function Pump-UiOnce {
    # The sync call blocks, so let WPF paint the "running" state first.
    try {
        $frame = New-Object System.Windows.Threading.DispatcherFrame
        $window.Dispatcher.BeginInvoke(
            [System.Action] { $frame.Done = $true },
            [System.Windows.Threading.DispatcherPriority]::Render,
            $null
        ) | Out-Null
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    } catch {}
}

function Request-UpstreamApiKey {
    # Last resort only. Before this runs the sync already tried the Authorization
    # header the proxy is forwarding and the key the local Codex install keeps in
    # ~/.codex/auth.json, so reaching here means both were unavailable.
    $prompt = "没能从本地拿到上游密钥。`r`n可以留空：先在 VS Code 里发一条消息，代理就会带上 Authorization 头，再点同步即可。`r`n也可以直接粘贴密钥（会写入 config\config.bat 的 LM_API_KEY）："
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic
        $entered = [Microsoft.VisualBasic.Interaction]::InputBox($prompt, 'Reasoning Proxy - 同步模型', '')
        if ($entered -and $entered.Trim()) {
            Set-ConfigValue 'LM_API_KEY' $entered.Trim()
            return $entered.Trim()
        }
    } catch {}
    return ''
}

$script:lmPicker = $null

function New-LmBadge([string]$Text, [string]$Background, [string]$Foreground) {
    $border = New-Object System.Windows.Controls.Border
    $border.Background = (New-Brush $Background)
    $border.CornerRadius = (New-Object System.Windows.CornerRadius(5))
    $border.Padding = (New-Object System.Windows.Thickness(8, 2, 8, 2))
    $border.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $border.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $Text
    $label.FontSize = 11
    $label.Foreground = (New-Brush $Foreground)
    $border.Child = $label
    return $border
}

# The confirmation step: pick which upstream models go into VS Code's config file,
# and set the per-model columns before anything is written.
# Returns @{ Ids = ...; Paths = ...; Overrides = ... } or $null when cancelled.
function Show-LmPickerDialog {
    param(
        [object[]]$Plan,
        [string]$TargetPath,
        [string]$Url,
        # Fallbacks for a model whose cell was left blank, straight from config.bat.
        [int]$DefaultInputTokens = 1000000,
        [bool]$DefaultVision = $true
    )

    $pickerXaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Reasoning Proxy - 选择同步内容"
    Width="860" Height="700"
    WindowStyle="None"
    AllowsTransparency="True"
    Background="Transparent"
    ShowInTaskbar="False"
    ResizeMode="NoResize"
    WindowStartupLocation="CenterOwner"
    FontFamily="Microsoft YaHei UI"
    UseLayoutRounding="True"
    SnapsToDevicePixels="True"
    TextOptions.TextFormattingMode="Display">
    <Window.Resources>
        <Style x:Key="DlgAccent" TargetType="Button">
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="Background" Value="#7F7EFC"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Padding" Value="18,0,18,0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="9" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#706EF0"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="bd" Property="Background" Value="#232838"/>
                                <Setter Property="Foreground" Value="#5D6880"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="DlgGhost" TargetType="Button">
            <Setter Property="Foreground" Value="#C3CBDC"/>
            <Setter Property="Background" Value="#242A3A"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Padding" Value="14,0,14,0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="9" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#39425A"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="DlgCheck" TargetType="CheckBox">
            <Setter Property="Foreground" Value="#DCE3F2"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <StackPanel Orientation="Horizontal" Background="Transparent">
                            <!-- 18 outer with a 1 border leaves a 16 box, so the tick
                                 geometry below is in absolute units and stays centred. -->
                            <Border x:Name="box" Width="18" Height="18" CornerRadius="5" VerticalAlignment="Center"
                                    Background="#161A25" BorderBrush="#48546F" BorderThickness="1"
                                    SnapsToDevicePixels="True">
                                <Path x:Name="tick" Width="16" Height="16" Stretch="None" Opacity="0"
                                      Data="M 3.4,8.4 L 6.6,11.6 L 12.6,4.4"
                                      Stroke="#FFFFFF" StrokeThickness="2"
                                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
                            </Border>
                            <ContentPresenter x:Name="cp" Margin="10,0,0,0" VerticalAlignment="Center"
                                              TextBlock.Foreground="{TemplateBinding Foreground}"/>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="box" Property="BorderBrush" Value="#78849F"/>
                                <Setter TargetName="box" Property="Background" Value="#1E2434"/>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="box" Property="Background" Value="#7F7EFC"/>
                                <Setter TargetName="box" Property="BorderBrush" Value="#7F7EFC"/>
                                <Setter TargetName="tick" Property="Opacity" Value="1"/>
                            </Trigger>
                            <MultiTrigger>
                                <MultiTrigger.Conditions>
                                    <Condition Property="IsChecked" Value="True"/>
                                    <Condition Property="IsMouseOver" Value="True"/>
                                </MultiTrigger.Conditions>
                                <Setter TargetName="box" Property="Background" Value="#8F8EFF"/>
                                <Setter TargetName="box" Property="BorderBrush" Value="#8F8EFF"/>
                            </MultiTrigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Foreground" Value="#5D6880"/>
                                <Setter TargetName="box" Property="Opacity" Value="0.35"/>
                                <Setter TargetName="cp" Property="Opacity" Value="0.55"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="DlgSearch" TargetType="TextBox">
            <Setter Property="Foreground" Value="#EBEEF8"/>
            <Setter Property="CaretBrush" Value="#EBEEF8"/>
            <Setter Property="Background" Value="#1C2130"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border Background="{TemplateBinding Background}" CornerRadius="8" BorderBrush="#2A3247" BorderThickness="1">
                            <ScrollViewer x:Name="PART_ContentHost" Margin="10,0,10,0" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="DlgHead" TargetType="TextBlock">
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Foreground" Value="#949EB4"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>
        <Style x:Key="DlgThumb" TargetType="Thumb">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Thumb">
                        <Border x:Name="thumbBg" Background="#3B455E" CornerRadius="4" Margin="2"/>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="thumbBg" Property="Background" Value="#596684"/>
                            </Trigger>
                            <Trigger Property="IsDragging" Value="True">
                                <Setter TargetName="thumbBg" Property="Background" Value="#76839F"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="DlgCell" TargetType="TextBox">
            <Setter Property="Foreground" Value="#EBEEF8"/>
            <Setter Property="CaretBrush" Value="#EBEEF8"/>
            <Setter Property="Background" Value="#0E1119"/>
            <Setter Property="BorderBrush" Value="#2A3247"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontFamily" Value="Consolas"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Height" Value="34"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="9"
                                BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
                            <Grid>
                                <ScrollViewer x:Name="PART_ContentHost" Margin="11,0,11,0" VerticalAlignment="Center"/>
                                <!-- Tag carries the "leave it blank" hint, so an empty cell still says what it means. -->
                                <TextBlock x:Name="watermark" Text="{TemplateBinding Tag}" Margin="12,0,11,0"
                                           VerticalAlignment="Center" FontSize="12" FontWeight="Normal"
                                           Foreground="#4A5470" IsHitTestVisible="False" Visibility="Collapsed"/>
                            </Grid>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="Text" Value="">
                                <Setter TargetName="watermark" Property="Visibility" Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="BorderBrush" Value="#3B455E"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="bd" Property="BorderBrush" Value="#7F7EFC"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Foreground" Value="#5D6880"/>
                                <Setter TargetName="bd" Property="Background" Value="#161A25"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="DlgComboItem" TargetType="ComboBoxItem">
            <Setter Property="Foreground" Value="#EBEEF8"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBoxItem">
                        <Border x:Name="ib" Background="Transparent" CornerRadius="7" Padding="11,7,11,7" Margin="4,2,4,2">
                            <ContentPresenter/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsHighlighted" Value="True">
                                <Setter TargetName="ib" Property="Background" Value="#2A3247"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="DlgCombo" TargetType="ComboBox">
            <Setter Property="Foreground" Value="#EBEEF8"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Height" Value="34"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="ItemContainerStyle" Value="{StaticResource DlgComboItem}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <ToggleButton x:Name="dropToggle" Focusable="False" ClickMode="Press"
                                          IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="ToggleButton">
                                        <Border x:Name="bd" Background="#0E1119" BorderBrush="#2A3247" BorderThickness="1" CornerRadius="9">
                                            <Path x:Name="arrow" Data="M 0,0 L 4.5,4.5 L 9,0" Stroke="#949EB4" StrokeThickness="1.6"
                                                  StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                                                  HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,1,13,0"/>
                                        </Border>
                                        <ControlTemplate.Triggers>
                                            <Trigger Property="IsMouseOver" Value="True">
                                                <Setter TargetName="bd" Property="BorderBrush" Value="#3B455E"/>
                                            </Trigger>
                                        </ControlTemplate.Triggers>
                                    </ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>
                            <ContentPresenter x:Name="selection" Margin="12,0,30,0" HorizontalAlignment="Left"
                                              VerticalAlignment="Center" IsHitTestVisible="False"
                                              Content="{TemplateBinding SelectionBoxItem}"
                                              ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                              TextBlock.Foreground="{TemplateBinding Foreground}"/>
                            <Popup x:Name="partPopup" AllowsTransparency="True" Placement="Bottom" Focusable="False"
                                   IsOpen="{TemplateBinding IsDropDownOpen}" PopupAnimation="Fade">
                                <Border Background="#1C2130" BorderBrush="#2A3247" BorderThickness="1" CornerRadius="10"
                                        Margin="0,5,0,0" MinWidth="164" MaxHeight="220">
                                    <ScrollViewer VerticalScrollBarVisibility="Auto">
                                        <ItemsPresenter/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.45"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="DlgPage" TargetType="RepeatButton">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Focusable" Value="False"/>
            <Setter Property="IsTabStop" Value="False"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RepeatButton">
                        <Border Background="Transparent"/>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="DlgScroll" TargetType="ScrollBar">
            <!-- Min/Max rather than Width: the theme style wins over a plain Width
                 setter, which is what left the bar at its default 17px. -->
            <Setter Property="MinWidth" Value="8"/>
            <Setter Property="MaxWidth" Value="8"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollBar">
                        <Grid Background="Transparent">
                            <Track x:Name="PART_Track" IsDirectionReversed="True">
                                <Track.DecreaseRepeatButton>
                                    <RepeatButton Command="{x:Static ScrollBar.PageUpCommand}" Style="{StaticResource DlgPage}"/>
                                </Track.DecreaseRepeatButton>
                                <Track.IncreaseRepeatButton>
                                    <RepeatButton Command="{x:Static ScrollBar.PageDownCommand}" Style="{StaticResource DlgPage}"/>
                                </Track.IncreaseRepeatButton>
                                <Track.Thumb><Thumb Style="{StaticResource DlgThumb}"/></Track.Thumb>
                            </Track>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <Border Background="#12151E" CornerRadius="16" BorderBrush="#2A3247" BorderThickness="1">
        <Grid Margin="26,20,26,20">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <Grid x:Name="HeaderBar" Grid.Row="0" Margin="0,0,0,18" Background="Transparent">
                <StackPanel>
                    <TextBlock Text="选择要同步的内容" FontSize="19" FontWeight="Bold" Foreground="#EBEEF8"/>
                    <TextBlock x:Name="SubtitleText" Text="" FontSize="12" Foreground="#949EB4" Margin="0,5,0,0"/>
                </StackPanel>
                <Button x:Name="CloseButton" Content="&#xE8BB;" FontFamily="Segoe MDL2 Assets" FontSize="13"
                        HorizontalAlignment="Right" VerticalAlignment="Top" Width="28" Height="28"
                        Foreground="#949EB4" Background="Transparent" BorderThickness="0" Cursor="Hand">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="cb" Background="Transparent" CornerRadius="7">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="cb" Property="Background" Value="#2A3247"/>
                                    <Setter Property="Foreground" Value="White"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
            </Grid>

            <Border Grid.Row="1" Background="#1C2130" CornerRadius="12" Padding="16,13,16,13">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <Grid Grid.Row="0" Margin="0,0,0,12">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <StackPanel Grid.Column="0" VerticalAlignment="Center">
                            <TextBlock Text="上游模型" FontSize="12" FontWeight="Bold" Foreground="#949EB4"/>
                        <TextBlock Text="留空即沿用文件里的值，新模型走默认值" FontSize="11" Foreground="#5D6880" Margin="0,3,0,0"/>
                            <TextBlock Text="同步后只保留勾选的模型，取消勾选会被删除" FontSize="11" Foreground="#FBBF24" Margin="0,2,0,0"/>
                        </StackPanel>
                        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                            <Grid Margin="0,0,8,0">
                                <TextBox x:Name="SearchBox" Style="{StaticResource DlgSearch}" Width="150" Height="28"/>
                                <TextBlock x:Name="SearchHint" Text="搜索模型" FontSize="12" Foreground="#5D6880"
                                           IsHitTestVisible="False" VerticalAlignment="Center" Margin="11,0,0,0"/>
                            </Grid>
                            <Button x:Name="AllButton" Content="全选" Style="{StaticResource DlgGhost}" Height="28" Margin="0,0,6,0"/>
                            <Button x:Name="NoneButton" Content="全不选" Style="{StaticResource DlgGhost}" Height="28" Margin="0,0,6,0"/>
        <Button x:Name="NewButton" Content="只勾新增" Style="{StaticResource DlgGhost}" Height="28"/>
                        </StackPanel>
                    </Grid>
                    <!-- The scrollbar track is always shown, and the header carries a
                         right margin equal to its width so the columns stay aligned. -->
                    <Grid Grid.Row="1" Margin="0,0,8,7">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="118"/>
                            <ColumnDefinition Width="164"/>
                            <ColumnDefinition Width="88"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Text="模型名称" Style="{StaticResource DlgHead}"/>
                        <TextBlock Grid.Column="1" Text="上下文窗口" Style="{StaticResource DlgHead}" Margin="10,0,10,0"/>
                        <TextBlock Grid.Column="2" Text="图片处理方式" Style="{StaticResource DlgHead}"/>
                    </Grid>
                    <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Visible" HorizontalScrollBarVisibility="Disabled">
                        <ScrollViewer.Resources>
                            <Style TargetType="ScrollBar" BasedOn="{StaticResource DlgScroll}"/>
                        </ScrollViewer.Resources>
                        <StackPanel x:Name="ModelHost"/>
                    </ScrollViewer>
                </Grid>
            </Border>

            <Grid Grid.Row="2" Margin="0,16,0,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="SummaryText" Grid.Column="0" Text="" FontSize="12" Foreground="#949EB4" VerticalAlignment="Center" TextWrapping="Wrap"/>
                <StackPanel Grid.Column="1" Orientation="Horizontal">
                    <Button x:Name="CancelButton" Content="取消" Style="{StaticResource DlgGhost}" Width="76" Height="34" Margin="0,0,10,0"/>
                    <Button x:Name="OkButton" Content="同步" Style="{StaticResource DlgAccent}" Width="96" Height="34"/>
                </StackPanel>
            </Grid>
        </Grid>
    </Border>
</Window>
'@

    $dialog = [Windows.Markup.XamlReader]::Parse($pickerXaml)
    $modelHost = $dialog.FindName('ModelHost')
    $summaryText = $dialog.FindName('SummaryText')
    $okButton = $dialog.FindName('OkButton')
    $searchBox = $dialog.FindName('SearchBox')

    # --- model rows: a table, one row per upstream model ---
    # Each row is parsed from its own XAML because PS 5.1 cannot build a
    # ColumnDefinition with a star GridLength, and the styles get attached by
    # hand since a standalone XAML string has no access to the window resources.
    $rowXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
      Margin="0,3,0,3">
    <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="118"/>
        <ColumnDefinition Width="164"/>
        <ColumnDefinition Width="88"/>
    </Grid.ColumnDefinitions>
    <CheckBox x:Name="RowCheck" Grid.Column="0" FontFamily="Consolas" VerticalContentAlignment="Center"/>
    <TextBox x:Name="TokensBox" Grid.Column="1" Margin="10,0,10,0"/>
    <ComboBox x:Name="VisionBox" Grid.Column="2">
        <ComboBoxItem Content="原样发送图片"/>
        <ComboBoxItem Content="不发送图片"/>
    </ComboBox>
    <Border x:Name="BadgeHost" Grid.Column="3" Margin="10,0,0,0"
            HorizontalAlignment="Left" VerticalAlignment="Center"/>
</Grid>
'@

    $checkStyle = $dialog.FindResource('DlgCheck')
    $cellStyle = $dialog.FindResource('DlgCell')
    $comboStyle = $dialog.FindResource('DlgCombo')
    $modelRows = New-Object System.Collections.ArrayList
    foreach ($item in $Plan) {
        $row = [System.Windows.Markup.XamlReader]::Parse($rowXaml)
        $scope = [System.Windows.NameScope]::GetNameScope($row)
        $box = $scope.FindName('RowCheck')
        $tokensBox = $scope.FindName('TokensBox')
        $visionBox = $scope.FindName('VisionBox')
        $badgeHost = $scope.FindName('BadgeHost')

        $box.Style = $checkStyle
        $box.Content = [string]$item.Id
        $box.IsChecked = [bool]$item.Checked
        $tokensBox.Style = $cellStyle
        $visionBox.Style = $comboStyle

        # What chatLanguageModels.json pins today, 0 when the model is not there.
        $tokens = [int]$item.MaxInputTokens
        # A blank cell keeps the value the file already has, so a model you set up
        # once never needs setting up again. Only models that are not in the file
        # yet fall back to the LM_MODEL_CONTEXT family hit and then to
        # LM_MAX_INPUT_TOKENS. The watermark shows whichever number wins.
        $rowDefault = $tokens
        if (-not [bool]$item.Configured) {
            $rowDefault = [int]$item.DefaultInputTokens
            if ($rowDefault -le 0) {
                $rowDefault = $DefaultInputTokens
            }
        }
        if ($rowDefault -le 0) {
            $rowDefault = $DefaultInputTokens
        }
        $tokensBox.Tag = Format-LmTokenSize $rowDefault
        # Same rule for the image setting: the file wins when it already says
        # something, otherwise LM_VISION decides for a brand new entry.
        $vision = if ([bool]$item.Configured) { [bool]$item.Vision } else { $DefaultVision }
        if ($vision) {
            $visionBox.SelectedIndex = 0
        } else {
            $visionBox.SelectedIndex = 1
        }

        switch ($item.State) {
            # Indigo rather than grey: these rows are live and editable, grey would
            # read as disabled now that only LM_SKIP_MODELS rows can be dead.
            'existing' { $badge = New-LmBadge '已配置' '#22264C' '#A5A6F7' }
            'local' { $badge = New-LmBadge '仅本地' '#12303A' '#5EEAD4' }
            'filtered' { $badge = New-LmBadge '已过滤' '#33291A' '#FBBF24' }
            default { $badge = New-LmBadge '新增' '#1E2B22' '#4ADE80' }
        }
        $badgeHost.Child = $badge

        # Only LM_SKIP_MODELS rows are dead, since nothing can be written for them.
        # Everything else is editable, rows already in the file included, so a cell
        # edit plus 同步 updates that entry where it stands.
        $box.IsEnabled = ($item.State -ne 'filtered')
        # Both of these already live in the provider block, so unchecking one is a
        # deletion and editing a cell is an update.
        $locked = ($item.State -eq 'existing') -or ($item.State -eq 'local')

        [void]$modelHost.Children.Add($row)

        [void]$modelRows.Add([pscustomobject]@{
            CheckBox = $box
            Row = $row
            Badge = $badge
            TokensBox = $tokensBox
            VisionBox = $visionBox
            Id = [string]$item.Id
            State = [string]$item.State
            Known = $locked
            # Resolved fallback for an empty cell, per row.
            DefaultTokens = $rowDefault
            # What chatLanguageModels.json says right now, so the sync can tell a
            # real edit from a row the user only looked at.
            OriginalTokens = $tokens
            OriginalVision = $vision
        })
    }

    $refresh = {
        $picker = $script:lmPicker
        $willAdd = 0
        $willUpdate = 0
        $willRemove = 0
        $kept = 0
        $skipped = 0
        foreach ($row in $picker.ModelRows) {
            if (-not $row.CheckBox.IsEnabled) {
                continue
            }
            $tokens = ConvertFrom-LmTokenSize -Text ([string]$row.TokensBox.Text) -Fallback $row.DefaultTokens
            $vision = ($row.VisionBox.SelectedIndex -ne 1)
            $dirty = ($tokens -ne $row.OriginalTokens) -or ($vision -ne $row.OriginalVision)
            if (-not $row.CheckBox.IsChecked) {
                # Unchecking something that is in the file means deleting it, which
                # deserves its own number rather than hiding inside "不同步".
                if ($row.Known) { $willRemove++ } else { $skipped++ }
                continue
            }
            if ($row.Known) {
                if ($dirty) { $willUpdate++ } else { $kept++ }
                continue
            }
            $willAdd++
        }

        $parts = New-Object System.Collections.ArrayList
        [void]$parts.Add("新增 $willAdd 个")
        if ($willUpdate -gt 0) {
            [void]$parts.Add("更新 $willUpdate 个")
        }
        if ($willRemove -gt 0) {
            [void]$parts.Add("移除 $willRemove 个")
        }
        if ($kept -gt 0) {
            [void]$parts.Add("保持 $kept 个")
        }
        if ($skipped -gt 0) {
            [void]$parts.Add("跳过 $skipped 个")
        }
        $picker.SummaryText.Text = ($parts -join ' · ')
    }

    foreach ($row in $modelRows) {
        if ($row.CheckBox.IsEnabled) {
            $row.CheckBox.Add_Checked($refresh)
            $row.CheckBox.Add_Unchecked($refresh)
        }
    }

    $dialog.FindName('AllButton').Add_Click({
        foreach ($row in $script:lmPicker.ModelRows) {
            if ($row.CheckBox.IsEnabled -and $row.Row.Visibility -eq 'Visible') {
                $row.CheckBox.IsChecked = $true
            }
        }
        & $script:lmPicker.Refresh
    })
    $dialog.FindName('NoneButton').Add_Click({
        foreach ($row in $script:lmPicker.ModelRows) {
            if ($row.CheckBox.IsEnabled) {
                $row.CheckBox.IsChecked = $false
            }
        }
        & $script:lmPicker.Refresh
    })
    $dialog.FindName('NewButton').Add_Click({
        foreach ($row in $script:lmPicker.ModelRows) {
            if ($row.CheckBox.IsEnabled) {
                $row.CheckBox.IsChecked = (-not $row.Known) -and ($row.State -ne 'filtered')
            }
        }
        & $script:lmPicker.Refresh
    })

    $searchBox.Add_TextChanged({
        $needle = ([string]$this.Text).Trim().ToLowerInvariant()
        $script:lmPicker.SearchHint.Visibility = $(if ($needle) {
            [System.Windows.Visibility]::Collapsed
        } else {
            [System.Windows.Visibility]::Visible
        })
        foreach ($row in $script:lmPicker.ModelRows) {
            if (-not $needle -or $row.Id.ToLowerInvariant().Contains($needle)) {
                $row.Row.Visibility = [System.Windows.Visibility]::Visible
            } else {
                $row.Row.Visibility = [System.Windows.Visibility]::Collapsed
            }
        }
    })

    $script:lmPicker = [pscustomobject]@{
        Dialog = $dialog
        TargetPaths = @([string]$TargetPath)
        ModelRows = $modelRows.ToArray()
        SummaryText = $summaryText
        OkButton = $okButton
        SearchHint = $dialog.FindName('SearchHint')
        Refresh = $refresh
        DefaultInputTokens = $DefaultInputTokens
        Result = $null
    }

    $dialog.Title = 'Reasoning Proxy - 选择同步内容'
    $dialog.FindName('SubtitleText').Text = "$TargetPath · 上游共 $($Plan.Count) 个模型"
    $okButton.Add_Click({
        $ids = New-Object System.Collections.ArrayList
        $overrides = @{}
        foreach ($row in $script:lmPicker.ModelRows) {
            if (-not $row.CheckBox.IsChecked) {
                continue
            }
            [void]$ids.Add($row.Id)
            $tokens = ConvertFrom-LmTokenSize -Text ([string]$row.TokensBox.Text) -Fallback $row.DefaultTokens
            $vision = ($row.VisionBox.SelectedIndex -ne 1)
            if ($row.Known -and ($tokens -eq $row.OriginalTokens) -and ($vision -eq $row.OriginalVision)) {
                # Untouched and already in the file: no override, so the entry stays
                # byte for byte as it is and no rewrite is triggered.
                continue
            }
            $overrides[$row.Id] = [ordered]@{
                MaxInputTokens = $tokens
                Vision = $vision
            }
        }
        $paths = @($script:lmPicker.TargetPaths)
        $script:lmPicker.Result = [pscustomobject]@{
            Ids = $ids.ToArray()
            Paths = $paths
            Overrides = $overrides
        }
        $dialog.DialogResult = $true
    })
    $dialog.FindName('CancelButton').Add_Click({ $dialog.DialogResult = $false })
    $dialog.FindName('CloseButton').Add_Click({ $dialog.DialogResult = $false })
    $dialog.FindName('HeaderBar').Add_MouseLeftButtonDown({ $dialog.DragMove() })

    & $refresh
    $dialog.Owner = $window
    [void]$dialog.ShowDialog()

    $result = $script:lmPicker.Result
    $script:lmPicker = $null
    $dialog.Close()
    return $result
}

function Sync-LanguageModelsConfig {
    param([bool]$Silent = $false)

    if (-not (Get-Command 'Complete-LmSync' -ErrorAction SilentlyContinue)) {
        $script:syncResultText.Text = '同步失败：缺少 language-models.ps1'
        $script:syncResultText.Foreground = (New-Brush '#F87171')
        return
    }

    $script:syncButton.IsEnabled = $false
    $script:syncResultText.Text = '正在从上游拉取模型列表...'
    $script:syncResultText.Foreground = (New-Brush '#FACC15')
    Pump-UiOnce

    $logPath = Join-Path $script:DataRoot 'logs\lm-sync.log'
    $config = Read-Config

    # Build the scriptblock first: `$(if ...)` yields nothing at all when the
    # branch is null, which PowerShell reads as a missing argument.
    $ask = $null
    if (-not $Silent) {
        $ask = { Request-UpstreamApiKey }
    }
    try {
        $fetch = Request-LmModelList `
            -Config $config `
            -ProxyRunning ([bool](Get-ProxyProcessId)) `
            -ProxyPort $script:Port `
            -AskForApiKey $ask

        if (-not $fetch['Ok']) {
            $report = New-LmFetchFailureReport -Fetch $fetch -ApiKey $fetch['ApiKey'] -KeySource $fetch['KeySource'] -LogPath $logPath
            $script:syncResultText.Text = [string]$report['Text']
            $script:syncResultText.Foreground = (New-Brush '#F87171')
            Write-Host "[gui] $($report['Detail'])"
            return
        }

        $settings = $fetch['Settings']
        # One file, always. This tool is written for VS Code, and LM_CONFIG_PATH
        # stays available for a portable install that keeps its profile elsewhere.
        $targets = Select-LmTargetPaths -ConfigPath $settings['ConfigPath']
        $targetPath = ''
        if (@($targets).Count -gt 0) {
            $targetPath = [string]$targets[0]
        }
        if ($Silent) {
            # Autosync has no user in front of it, so it takes every eligible model
            # and never prunes: a half-broken upstream must not be able to empty the
            # file while nobody is watching.
            $chosen = [pscustomobject]@{ Ids = $fetch['Ids']; Paths = $targets; Overrides = @{} }
            $prune = $false
        } else {
            # Scope "already configured" to the block this proxy owns, because that is
            # exactly the block the checked list is allowed to add to, edit and prune.
            $knownIds = Get-LmHostModelIds -Paths $targets -Url $settings['Url'] -ProviderName $settings['ProviderName']
            # What the file already pins per model, so the table can show the real
            # context window and image setting instead of the global default.
            $catalog = Get-LmModelCatalog -Paths $targets
            $plan = Get-LmModelPlan `
                -UpstreamIds $fetch['Ids'] `
                -KnownIds $knownIds `
                -Catalog $catalog `
                -ContextHints (Get-LmContextHints $settings['ModelContext']) `
                -LocalIds @($knownIds) `
                -SkipPatterns $settings['SkipPatterns'] `
                -IncludePatterns $settings['IncludePatterns']
            $prune = $true
            $chosen = Show-LmPickerDialog `
                -Plan $plan `
                -TargetPath $targetPath `
                -Url $settings['Url'] `
                -DefaultInputTokens $settings['MaxInputTokens'] `
                -DefaultVision $settings['Vision']
        }

        if ($null -eq $chosen) {
            $script:syncResultText.Text = "已取消：chatLanguageModels.json 未改动（上游共 $($fetch['Ids'].Count) 个模型）"
            $script:syncResultText.Foreground = (New-Brush '#949EB4')
            return
        }
        if (@($chosen.Ids).Count -eq 0) {
            $script:syncResultText.Text = '未勾选任何模型，已取消（否则会把该 provider 清空）'
            $script:syncResultText.Foreground = (New-Brush '#949EB4')
            return
        }

        $report = Complete-LmSync `
            -Config $config `
            -ModelIds $chosen.Ids `
            -UpstreamIds $fetch['Ids'] `
            -TargetPaths $chosen.Paths `
            -Overrides $chosen.Overrides `
            -Prune $prune `
            -Source $fetch['Source'] `
            -KeySource $fetch['KeySource'] `
            -LogPath $logPath `
            -ProxyPort $settings['Port']

        $script:syncResultText.Text = [string]$report['Text']
        $script:syncResultText.Foreground = (New-Brush $(if ($report['Ok']) { '#4ADE80' } else { '#F87171' }))
        Write-Host "[gui] $($report['Detail'])"

        if (-not $Silent) {
            $note = "已写入 $(Split-LmEditorLabel $targetPath)（$(@($chosen.Ids).Count) 个模型）。完整记录在 logs\lm-sync.log"
            if ($report['Ok']) {
                $script:notifyIcon.ShowBalloonTip(4000, '模型同步完成', $note, [System.Windows.Forms.ToolTipIcon]::Info)
            } else {
                $script:notifyIcon.ShowBalloonTip(6000, '模型同步未完成', $note, [System.Windows.Forms.ToolTipIcon]::Warning)
            }
        }
    } catch {
        $script:syncResultText.Text = "同步失败：$($_.Exception.Message)"
        $script:syncResultText.Foreground = (New-Brush '#F87171')
        Write-Host "[gui] sync failed: $($_.Exception.Message)"
    } finally {
        $script:syncButton.IsEnabled = $true
    }
}

# With LM_AUTOSYNC=1 the first sync waits until the proxy has seen one VS Code
# request, because that is where the upstream credential comes from.
function Test-LmAuthCaptured {
    try {
        $status = Invoke-LmHttpGet -Uri "http://127.0.0.1:$($script:Port)/__reasoning_proxy/status"
        if (-not $status.Ok) {
            return $false
        }
        $payload = ConvertFrom-Json -InputObject $status.Body
        return (([string]$payload.authSource) -eq 'captured')
    } catch {
        return $false
    }
}

function Run-LmAutoSync {
    if (-not $script:lmAutoSync -or $script:lmAutoSyncDone) {
        return
    }
    if (-not (Get-ProxyProcessId)) {
        $script:lmAutoSyncTicks = 0
        return
    }
    $script:lmAutoSyncTicks = [int]$script:lmAutoSyncTicks + 1
    # 15 ticks is about 30 seconds of waiting, then sync anyway and stop trying.
    if ($script:lmAutoSyncTicks -lt 15 -and -not (Test-LmAuthCaptured)) {
        return
    }
    $script:lmAutoSyncDone = $true
    Sync-LanguageModelsConfig -Silent $true
}

$config = Read-Config
$script:Port = if ($config['PROXY_PORT']) { [int]$config['PROXY_PORT'] } else { 3120 }
$targetHost = if ($config['TARGET_HOST']) { $config['TARGET_HOST'] } else { '10.0.8.19' }
$targetPort = if ($config['TARGET_PORT']) { $config['TARGET_PORT'] } else { '80' }
$script:reasoningEffort = if ($config['REASONING_EFFORT']) { $config['REASONING_EFFORT'] } else { 'high' }
$kimiTemperature = if ($config['KIMI_TEMPERATURE']) { $config['KIMI_TEMPERATURE'] } else { '1' }
$kimiTopP = if ($config['KIMI_TOP_P']) { $config['KIMI_TOP_P'] } else { '0.95' }
$script:allowExit = $false
$script:logPanelVisible = $false
$script:lmAutoSync = ([string]$config['LM_AUTOSYNC']) -eq '1'
$script:lmAutoSyncDone = $false
$script:lmProxyWasRunning = $false

$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    xmlns:sys="clr-namespace:System;assembly=mscorlib"
    Title="Reasoning Proxy"
    Width="520"
    Height="540"
    WindowStyle="None"
    AllowsTransparency="True"
    Background="Transparent"
    ResizeMode="NoResize"
    WindowStartupLocation="CenterScreen"
    FontFamily="Microsoft YaHei UI"
    UseLayoutRounding="True"
    SnapsToDevicePixels="True"
    TextOptions.TextFormattingMode="Display">
    <Window.Resources>
        <Style x:Key="AccentButton" TargetType="Button">
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="Background" Value="#7F7EFC"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="10">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#706EF0"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="bd" Property="Background" Value="#2C3242"/>
                                <Setter Property="Foreground" Value="#949EB4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="DangerButton" TargetType="Button">
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="Background" Value="#EF4444"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="10">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#DC2626"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="bd" Property="Background" Value="#2C3242"/>
                                <Setter Property="Foreground" Value="#949EB4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="CloseButton" TargetType="Button">
            <Setter Property="Foreground" Value="#949EB4"/>
            <Setter Property="FontSize" Value="16"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="Transparent" CornerRadius="6">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Foreground" Value="White"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="GhostButton" TargetType="Button">
            <Setter Property="Foreground" Value="#EBEEF8"/>
            <Setter Property="Background" Value="#2C3242"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="10">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#39425A"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#454F6B"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="bd" Property="Background" Value="#232838"/>
                                <Setter Property="Foreground" Value="#949EB4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ScrollThumb" TargetType="Thumb">
            <Setter Property="Focusable" Value="False"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Thumb">
                        <Border x:Name="thumbBg" Background="#3B455E" CornerRadius="4" Margin="2"/>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="thumbBg" Property="Background" Value="#596684"/>
                            </Trigger>
                            <Trigger Property="IsDragging" Value="True">
                                <Setter TargetName="thumbBg" Property="Background" Value="#76839F"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ScrollPageButton" TargetType="RepeatButton">
            <Setter Property="Focusable" Value="False"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RepeatButton">
                        <Border Background="Transparent"/>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="LogScrollBar" TargetType="ScrollBar">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="MinWidth" Value="8"/>
            <Setter Property="MaxWidth" Value="8"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollBar">
                        <Grid Background="Transparent">
                            <Track x:Name="PART_Track" Orientation="Vertical" IsDirectionReversed="True">
                                <Track.DecreaseRepeatButton>
                                    <RepeatButton Command="{x:Static ScrollBar.PageUpCommand}" Style="{StaticResource ScrollPageButton}"/>
                                </Track.DecreaseRepeatButton>
                                <Track.Thumb>
                                    <Thumb Style="{StaticResource ScrollThumb}"/>
                                </Track.Thumb>
                                <Track.IncreaseRepeatButton>
                                    <RepeatButton Command="{x:Static ScrollBar.PageDownCommand}" Style="{StaticResource ScrollPageButton}"/>
                                </Track.IncreaseRepeatButton>
                            </Track>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="Orientation" Value="Horizontal">
                    <Setter Property="MinWidth" Value="0"/>
                    <Setter Property="MaxWidth" Value="{x:Static sys:Double.PositiveInfinity}"/>
                    <Setter Property="MinHeight" Value="8"/>
                    <Setter Property="MaxHeight" Value="8"/>
                    <Setter Property="Template">
                        <Setter.Value>
                            <ControlTemplate TargetType="ScrollBar">
                                <Grid Background="Transparent">
                                    <Track x:Name="PART_Track" Orientation="Horizontal" IsDirectionReversed="False">
                                        <Track.DecreaseRepeatButton>
                                            <RepeatButton Command="{x:Static ScrollBar.PageLeftCommand}" Style="{StaticResource ScrollPageButton}"/>
                                        </Track.DecreaseRepeatButton>
                                        <Track.Thumb>
                                            <Thumb Style="{StaticResource ScrollThumb}"/>
                                        </Track.Thumb>
                                        <Track.IncreaseRepeatButton>
                                            <RepeatButton Command="{x:Static ScrollBar.PageRightCommand}" Style="{StaticResource ScrollPageButton}"/>
                                        </Track.IncreaseRepeatButton>
                                    </Track>
                                </Grid>
                            </ControlTemplate>
                        </Setter.Value>
                    </Setter>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="LogScrollViewerStyle" TargetType="ScrollViewer">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollViewer">
                        <Grid Background="Transparent">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="*"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>
                            <ScrollContentPresenter x:Name="PART_ScrollContentPresenter"
                                                    Grid.Row="0"
                                                    Grid.Column="0"
                                                    CanContentScroll="{TemplateBinding CanContentScroll}"
                                                    CanHorizontallyScroll="False"
                                                    CanVerticallyScroll="False"
                                                    Content="{TemplateBinding Content}"
                                                    ContentTemplate="{TemplateBinding ContentTemplate}"
                                                    Margin="{TemplateBinding Padding}"/>
                            <ScrollBar x:Name="PART_VerticalScrollBar"
                                       Grid.Row="0"
                                       Grid.Column="1"
                                       Orientation="Vertical"
                                       Minimum="0"
                                       Maximum="{TemplateBinding ScrollableHeight}"
                                       ViewportSize="{TemplateBinding ViewportHeight}"
                                       Value="{TemplateBinding VerticalOffset}"
                                       Visibility="{TemplateBinding ComputedVerticalScrollBarVisibility}"
                                       Cursor="Arrow"
                                       Style="{StaticResource LogScrollBar}"/>
                            <ScrollBar x:Name="PART_HorizontalScrollBar"
                                       Grid.Row="1"
                                       Grid.Column="0"
                                       Orientation="Horizontal"
                                       Minimum="0"
                                       Maximum="{TemplateBinding ScrollableWidth}"
                                       ViewportSize="{TemplateBinding ViewportWidth}"
                                       Value="{TemplateBinding HorizontalOffset}"
                                       Visibility="{TemplateBinding ComputedHorizontalScrollBarVisibility}"
                                       Cursor="Arrow"
                                       Style="{StaticResource LogScrollBar}"/>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="LogTextBoxStyle" TargetType="TextBox">
            <Setter Property="Background" Value="#151924"/>
            <Setter Property="Foreground" Value="#C7D0E0"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="12"/>
            <Setter Property="FontFamily" Value="Consolas"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}" CornerRadius="10">
                            <ScrollViewer x:Name="PART_ContentHost" Style="{StaticResource LogScrollViewerStyle}" Focusable="False" HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Auto" SnapsToDevicePixels="{TemplateBinding SnapsToDevicePixels}"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="TextButton" TargetType="Button">
            <Setter Property="Foreground" Value="#949EB4"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontFamily" Value="Consolas"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Padding" Value="0,4,18,4"/>
            <Setter Property="Margin" Value="0,0,6,0"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="Transparent" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="HeaderButton" TargetType="Button">
            <Setter Property="Foreground" Value="#949EB4"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="Transparent" CornerRadius="6">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Foreground" Value="White"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Border x:Name="Root" Background="#12151E" CornerRadius="16" BorderBrush="#2A3040" BorderThickness="1" Margin="12">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="80"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <Border x:Name="Header" Grid.Row="0" Background="#0E1119" CornerRadius="16,16,0,0">
                <Grid>
                    <Image x:Name="LogoImage" Width="48" Height="48" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="22,0,0,0" Stretch="Uniform"/>
                    <TextBlock x:Name="TitleText" Text="Reasoning Proxy" FontSize="18" FontWeight="Bold" Foreground="#EBEEF8" Margin="82,16,0,0" HorizontalAlignment="Left" VerticalAlignment="Top"/>
                    <TextBlock x:Name="SubtitleText" Text="本地 API 反向代理" FontSize="12" Foreground="#949EB4" Margin="84,46,0,0" HorizontalAlignment="Left" VerticalAlignment="Top"/>
                    <Button x:Name="LogToggleButton" Style="{StaticResource HeaderButton}" Content="查看日志" Width="72" Height="30" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,10,52,0"/>
                    <Button x:Name="CloseButton" Style="{StaticResource CloseButton}" Content="&#x2715;" Width="34" Height="30" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,10,10,0"/>
                </Grid>
            </Border>

            <Grid Grid.Row="1" Margin="20,14,20,18">
                <Grid x:Name="MainPanel">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <Border Grid.Row="0" Background="#1C2130" CornerRadius="12" Padding="20,16">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Grid Grid.Row="0" Grid.Column="0" Width="22" Height="22" VerticalAlignment="Center">
                            <Ellipse x:Name="StatusDot" Width="10" Height="10" Fill="#949EB4" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Grid>
                        <TextBlock x:Name="StatusText" Grid.Row="0" Grid.Column="1" Text="未运行" FontSize="18" FontWeight="Bold" Foreground="#949EB4" VerticalAlignment="Center" Margin="10,0,0,0"/>
                        <TextBlock x:Name="PidText" Grid.Row="1" Grid.Column="1" Text="等待启动" FontSize="12" Foreground="#949EB4" Margin="10,4,0,0"/>
                    </Grid>
                </Border>

                <Border Grid.Row="1" Background="#1C2130" CornerRadius="12" Padding="24,16" Margin="0,14,0,0">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Text="运行信息" FontSize="14" FontWeight="Bold" Foreground="#EBEEF8"/>
                        <Grid Grid.Row="1" Margin="0,10,0,0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="120"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="30"/>
                                <RowDefinition Height="30"/>
                                <RowDefinition Height="30"/>
                                <RowDefinition Height="30"/>
                            </Grid.RowDefinitions>
                            <TextBlock Grid.Row="0" Grid.Column="0" Text="本地地址" Foreground="#949EB4" VerticalAlignment="Center" Margin="0,4,0,4"/>
                            <TextBlock x:Name="LocalValue" Grid.Row="0" Grid.Column="1" Foreground="#EBEEF8" FontFamily="Consolas" VerticalAlignment="Center" Margin="0,4,0,4"/>
                            <TextBlock Grid.Row="1" Grid.Column="0" Text="目标地址" Foreground="#949EB4" VerticalAlignment="Center" Margin="0,4,0,4"/>
                            <TextBlock x:Name="TargetValue" Grid.Row="1" Grid.Column="1" Foreground="#EBEEF8" FontFamily="Consolas" VerticalAlignment="Center" Margin="0,4,0,4"/>
                            <TextBlock Grid.Row="2" Grid.Column="0" Text="推理等级" Foreground="#949EB4" VerticalAlignment="Center" Margin="0,4,0,4"/>
                            <StackPanel x:Name="EffortButtons" Grid.Row="2" Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,4,0,4"/>
                            <TextBlock Grid.Row="3" Grid.Column="0" Text="Kimi 参数" Foreground="#949EB4" VerticalAlignment="Center" Margin="0,4,0,4"/>
                            <TextBlock x:Name="KimiValue" Grid.Row="3" Grid.Column="1" Foreground="#EBEEF8" FontFamily="Consolas" VerticalAlignment="Center" Margin="0,4,0,4"/>
                        </Grid>
                    </Grid>
                </Border>

                <Grid Grid.Row="2" Margin="0,18,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="20"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Button x:Name="StartButton" Grid.Column="0" Style="{StaticResource AccentButton}" Content="启动代理" Height="42"/>
                    <Button x:Name="StopButton" Grid.Column="2" Style="{StaticResource DangerButton}" Content="停止代理" Height="42"/>
                </Grid>

                <Button x:Name="SyncButton" Grid.Row="3" Style="{StaticResource GhostButton}" Content="同步上游模型到 VS Code" Height="42" Margin="0,12,0,0"/>

                <Grid Grid.Row="4" Margin="0,6,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock x:Name="SyncResultText" Grid.Column="0" Text="尚未同步：从上游拉取模型列表，补齐 chatLanguageModels.json" FontSize="11" Foreground="#949EB4" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
                    <TextBlock Grid.Column="1" Text="窗口关闭后仍在系统托盘" FontSize="11" Foreground="#5D6880" VerticalAlignment="Center" Margin="12,0,0,0"/>
                </Grid>
            </Grid>

                <Grid x:Name="LogPanel" Visibility="Collapsed">
                    <Border Background="#1C2130" CornerRadius="12" Padding="10">
                        <TextBox x:Name="LogTextBox" Style="{StaticResource LogTextBoxStyle}" IsReadOnly="True" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
                    </Border>
                </Grid>
            </Grid>
        </Grid>
    </Border>
</Window>
'@

$window = [System.Windows.Markup.XamlReader]::Parse($xaml)

$logoImage = $window.FindName('LogoImage')
$closeButton = $window.FindName('CloseButton')
$header = $window.FindName('Header')
$statusDot = $window.FindName('StatusDot')
$statusText = $window.FindName('StatusText')
$pidText = $window.FindName('PidText')
$startButton = $window.FindName('StartButton')
$stopButton = $window.FindName('StopButton')
$logToggleButton = $window.FindName('LogToggleButton')
$mainPanel = $window.FindName('MainPanel')
$logPanel = $window.FindName('LogPanel')
$logTextBox = $window.FindName('LogTextBox')
$syncButton = $window.FindName('SyncButton')
$syncResultText = $window.FindName('SyncResultText')

$script:statusDot = $statusDot
$script:statusText = $statusText
$script:pidText = $pidText
$script:startButton = $startButton
$script:stopButton = $stopButton
$script:logToggleButton = $logToggleButton
$script:mainPanel = $mainPanel
$script:logPanel = $logPanel
$script:logTextBox = $logTextBox
$script:syncButton = $syncButton
$script:syncResultText = $syncResultText

$script:effortLevels = @('low', 'medium', 'high', 'max')
$script:effortButtons = @()
$effortPanel = $window.FindName('EffortButtons')
foreach ($level in $script:effortLevels) {
    $button = New-Object System.Windows.Controls.Button
    $button.Name = "Effort$level"
    $button.Style = $window.FindResource('TextButton')
    $button.Content = $level
    $button.Tag = $level
    $button.Add_Click({ Set-ReasoningEffort $this.Tag })
    $effortPanel.Children.Add($button) | Out-Null
    $script:effortButtons += $button
}

$statusEffect = New-Object System.Windows.Media.Effects.DropShadowEffect
$statusEffect.BlurRadius = 12
$statusEffect.ShadowDepth = 0
$statusEffect.Opacity = 0.5
$statusEffect.Color = (New-Color '#949EB4')
$statusDot.Effect = $statusEffect
$script:statusEffect = $statusEffect

$glowStoryboard = New-Object System.Windows.Media.Animation.Storyboard
$glowStoryboard.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
$glowStoryboard.AutoReverse = $true

$blurAnimation = New-Object System.Windows.Media.Animation.DoubleAnimation
$blurAnimation.From = 8.0
$blurAnimation.To = 22.0
$blurAnimation.Duration = [TimeSpan]::FromMilliseconds(900)
[System.Windows.Media.Animation.Storyboard]::SetTarget($blurAnimation, $statusDot)
[System.Windows.Media.Animation.Storyboard]::SetTargetProperty($blurAnimation, (New-Object System.Windows.PropertyPath('(UIElement.Effect).(DropShadowEffect.BlurRadius)')))
$glowStoryboard.Children.Add($blurAnimation) | Out-Null

$glowOpacityAnimation = New-Object System.Windows.Media.Animation.DoubleAnimation
$glowOpacityAnimation.From = 0.55
$glowOpacityAnimation.To = 1.0
$glowOpacityAnimation.Duration = [TimeSpan]::FromMilliseconds(900)
[System.Windows.Media.Animation.Storyboard]::SetTarget($glowOpacityAnimation, $statusDot)
[System.Windows.Media.Animation.Storyboard]::SetTargetProperty($glowOpacityAnimation, (New-Object System.Windows.PropertyPath('(UIElement.Effect).(DropShadowEffect.Opacity)')))
$glowStoryboard.Children.Add($glowOpacityAnimation) | Out-Null
$script:glowStoryboard = $glowStoryboard

$logoPath = Join-Path $script:RuntimeRoot 'assets\logo.png'
$logoUri = New-Object System.Uri($logoPath)
$logoBitmap = New-Object System.Windows.Media.Imaging.BitmapImage
$logoBitmap.BeginInit()
$logoBitmap.UriSource = $logoUri
$logoBitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
$logoBitmap.EndInit()
$logoImage.Source = $logoBitmap
$window.Icon = $logoBitmap

$window.FindName('LocalValue').Text = "http://127.0.0.1:$script:Port"
$window.FindName('TargetValue').Text = "http://${targetHost}:${targetPort}"
$window.FindName('KimiValue').Text = "temperature=$kimiTemperature  top_p=$kimiTopP"
Update-EffortButtons

$startButton.Add_Click({ Start-Proxy })
$stopButton.Add_Click({ Stop-Proxy })
$logToggleButton.Add_Click({ Toggle-LogPanel })
$syncButton.Add_Click({ Sync-LanguageModelsConfig })
$closeButton.Add_Click({ $window.Close() })
$header.Add_MouseLeftButtonDown({ $window.DragMove() })

$script:appIcon = New-Object System.Drawing.Icon((Join-Path $script:RuntimeRoot 'assets\logo.ico'))
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = $script:appIcon
$notifyIcon.Text = 'Reasoning Proxy'
$notifyIcon.Visible = $true
$script:notifyIcon = $notifyIcon

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$openItem = New-Object System.Windows.Forms.ToolStripMenuItem('打开界面')
$openItem.Add_Click({
    $script:allowExit = $false
    $window.Show()
    $window.WindowState = 'Normal'
    $window.Activate()
    Update-Status
})
$quitItem = New-Object System.Windows.Forms.ToolStripMenuItem('退出（不停止代理）')
$quitItem.Add_Click({
    $script:allowExit = $true
    $script:notifyIcon.Visible = $false
    $script:notifyIcon.Dispose()
    $window.Close()
})
$trayMenu.Items.Add($openItem) | Out-Null
$syncTrayItem = New-Object System.Windows.Forms.ToolStripMenuItem('同步模型到 VS Code')
$syncTrayItem.Add_Click({ Sync-LanguageModelsConfig })
$trayMenu.Items.Add($syncTrayItem) | Out-Null
$trayMenu.Items.Add($quitItem) | Out-Null
$notifyIcon.ContextMenuStrip = $trayMenu
$notifyIcon.Add_MouseDoubleClick({
    if ($_.Button -eq 'Left') {
        $window.Show()
        $window.WindowState = 'Normal'
        $window.Activate()
        Update-Status
    }
})

$window.Add_Closing({
    param($sender, $eventArgs)
    if (-not $script:allowExit) {
        $eventArgs.Cancel = $true
        $window.Hide()
        $script:notifyIcon.ShowBalloonTip(2000, 'Reasoning Proxy', '代理仍在后台运行', [System.Windows.Forms.ToolTipIcon]::Info)
    }
})

$refreshTimer = New-Object System.Windows.Threading.DispatcherTimer
$refreshTimer.Interval = [TimeSpan]::FromSeconds(2)
$refreshTimer.Add_Tick({
    Update-Status
    if ($script:logPanelVisible) {
        Update-LogPanel
    }
    Run-LmAutoSync
})
$refreshTimer.Start()

Update-Status
Run-LmAutoSync

$app = New-Object System.Windows.Application
$app.Run($window) | Out-Null

if ($script:appMutex) {
    try { $script:appMutex.ReleaseMutex() } catch {}
    $script:appMutex.Dispose()
}
