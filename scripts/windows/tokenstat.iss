; SPDX-License-Identifier: LicenseRef-tokenstat-source-available
;
; Branded per-user installer. The wizard extracts the published folder and
; runs Tokenstat.exe --install, which is the source of truth for copy, Start
; Menu, Add/Remove Programs, and the host task. This script does not write
; those itself. Uninstall stays Tokenstat.exe --uninstall.
;
; Compiled on windows-latest by scripts/pack-windows-installer.ps1.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef StageDir
  #error StageDir must be defined (the published Tokenstat.exe folder)
#endif
#ifndef OutputDir
  #define OutputDir "dist"
#endif
#ifndef OutputBase
  #define OutputBase "tokenstat-" + AppVersion + "-windows-x64-setup"
#endif
#ifndef SetupIcon
  #define SetupIcon "apps\windows\Assets\tokenstat.ico"
#endif
#ifndef LicenseFile
  #define LicenseFile "LICENSE"
#endif
#ifndef WizardImage
  #define WizardImage "apps\windows\Assets\tokenstat.png"
#endif
#ifndef WizardSmallImage
  #define WizardSmallImage "apps\windows\Assets\tokenstat.png"
#endif
#ifndef FileVersion
  #define FileVersion "0.0.0"
#endif

[Setup]
AppId=ai.tokenstat.tokenstat
AppName=tokenstat
AppVersion={#AppVersion}
AppVerName=tokenstat {#AppVersion}
AppPublisher=pueev OÜ
AppPublisherURL=https://tokenstat.ai
AppSupportURL=https://tokenstat.ai
AppCopyright=© pueev OÜ. All rights reserved.
VersionInfoVersion={#FileVersion}.0
VersionInfoCompany=pueev OÜ
VersionInfoProductName=tokenstat
VersionInfoCopyright=© pueev OÜ. All rights reserved.
DefaultDirName={localappdata}\Programs\tokenstat
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
LicenseFile={#LicenseFile}
SetupIconFile={#SetupIcon}
WizardImageFile={#WizardImage}
WizardSmallImageFile={#WizardSmallImage}
WizardStyle=modern
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBase}
Compression=lzma2
SolidCompression=yes
Uninstallable=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=no
RestartApplications=no
MinVersion=10.0
ShowLanguageDialog=no
UsePreviousAppDir=no
DisableReadyPage=no
DisableFinishedPage=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Messages]
SetupAppTitle=tokenstat
SetupWindowTitle=Install tokenstat
WelcomeLabel1=Welcome to tokenstat
WelcomeLabel2=This installs tokenstat for your user account, with the licence on the next page.
FinishedLabel=tokenstat is installed. The app opens from %LOCALAPPDATA%\Programs\tokenstat.
ButtonInstall=&Install

[Files]
Source: "{#StageDir}\*"; DestDir: "{tmp}\tokenstat-payload"; Flags: recursesubdirs ignoreversion

[Run]
Filename: "{tmp}\tokenstat-payload\Tokenstat.exe"; Parameters: "--install"; StatusMsg: "Installing tokenstat for this user…"; Flags: waituntilterminated
