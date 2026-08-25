Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Read-Config {
    $configPath = Join-Path $PSScriptRoot 'config.bat'
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
    $script:statusDot.Foreground = $yellow
    $script:statusText.Text = '正在启动...'
    $script:statusText.Foreground = $yellow
    $script:pidText.Text = '请稍候'
    $startBat = Join-Path $PSScriptRoot 'start.bat'
    Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$startBat`"" -WorkingDirectory $PSScriptRoot -WindowStyle Hidden
}

function Stop-Proxy {
    $processId = Get-ProxyProcessId
    if ($processId) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 300
    }
    Update-Status
}

$config = Read-Config
$script:Port = if ($config['PROXY_PORT']) { [int]$config['PROXY_PORT'] } else { 3120 }
$targetHost = if ($config['TARGET_HOST']) { $config['TARGET_HOST'] } else { '10.0.8.19' }
$targetPort = if ($config['TARGET_PORT']) { $config['TARGET_PORT'] } else { '80' }
$reasoningEffort = if ($config['REASONING_EFFORT']) { $config['REASONING_EFFORT'] } else { 'high' }
$kimiTemperature = if ($config['KIMI_TEMPERATURE']) { $config['KIMI_TEMPERATURE'] } else { '1' }
$kimiTopP = if ($config['KIMI_TOP_P']) { $config['KIMI_TOP_P'] } else { '0.95' }
$script:allowExit = $false

$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Reasoning Proxy"
    Width="520"
    Height="464"
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
                    <Button x:Name="CloseButton" Style="{StaticResource CloseButton}" Content="&#x2715;" Width="34" Height="30" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,10,10,0"/>
                </Grid>
            </Border>

            <Grid Grid.Row="1" Margin="20,14,20,18">
                <Grid.RowDefinitions>
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
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>
                            <TextBlock Grid.Row="0" Grid.Column="0" Text="本地地址" Foreground="#949EB4" Margin="0,6,0,6"/>
                            <TextBlock x:Name="LocalValue" Grid.Row="0" Grid.Column="1" Foreground="#EBEEF8" FontFamily="Consolas" Margin="0,6,0,6"/>
                            <TextBlock Grid.Row="1" Grid.Column="0" Text="目标地址" Foreground="#949EB4" Margin="0,6,0,6"/>
                            <TextBlock x:Name="TargetValue" Grid.Row="1" Grid.Column="1" Foreground="#EBEEF8" FontFamily="Consolas" Margin="0,6,0,6"/>
                            <TextBlock Grid.Row="2" Grid.Column="0" Text="推理等级" Foreground="#949EB4" Margin="0,6,0,6"/>
                            <TextBlock x:Name="EffortValue" Grid.Row="2" Grid.Column="1" Foreground="#EBEEF8" FontFamily="Consolas" Margin="0,6,0,6"/>
                            <TextBlock Grid.Row="3" Grid.Column="0" Text="Kimi 参数" Foreground="#949EB4" Margin="0,6,0,6"/>
                            <TextBlock x:Name="KimiValue" Grid.Row="3" Grid.Column="1" Foreground="#EBEEF8" FontFamily="Consolas" Margin="0,6,0,6"/>
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

                <TextBlock x:Name="HintText" Grid.Row="3" Text="关闭窗口不会停止代理，界面会保留在系统托盘" FontSize="11" Foreground="#949EB4" Margin="0,12,0,0"/>
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

$script:statusDot = $statusDot
$script:statusText = $statusText
$script:pidText = $pidText
$script:startButton = $startButton
$script:stopButton = $stopButton

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

$logoPath = Join-Path $PSScriptRoot 'logo.png'
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
$window.FindName('EffortValue').Text = $reasoningEffort
$window.FindName('KimiValue').Text = "temperature=$kimiTemperature  top_p=$kimiTopP"

$startButton.Add_Click({ Start-Proxy })
$stopButton.Add_Click({ Stop-Proxy })
$closeButton.Add_Click({ $window.Close() })
$header.Add_MouseLeftButtonDown({ $window.DragMove() })

$script:appIcon = New-Object System.Drawing.Icon((Join-Path $PSScriptRoot 'logo.ico'))
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
$refreshTimer.Add_Tick({ Update-Status })
$refreshTimer.Start()

Update-Status

$app = New-Object System.Windows.Application
$app.Run($window) | Out-Null
