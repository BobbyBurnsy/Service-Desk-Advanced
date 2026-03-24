# Service Desk Advanced (SDA) - Official Knowledge Base & FAQ
**Website:** [www.servicedeskadvanced.com](https://www.servicedeskadvanced.com) | **Support:** [SDA.WTF](https://sda.wtf)

Welcome to the official knowledge base for **Service Desk Advanced (SDA)**. Whether you are a Systems Administrator deploying the platform for the first time, or a Help Desk Technician looking to understand the mechanics behind our remediation tools, this document covers everything you need to know about our enterprise-grade orchestration platform.

---

## Table of Contents
1. [Platform Overview & Architecture](#1-platform-overview--architecture)
2. [Security & Attack Surface Mitigation](#2-security--attack-surface-mitigation)
3. [Installation & Deployment Guide](#3-installation--deployment-guide)
4. [Identity & Telemetry Engine](#4-identity--telemetry-engine)
5. [Deep Dive: How the Remediation Tools Work](#5-deep-dive-how-the-remediation-tools-work)
6. [The "Training Mode" Philosophy](#6-the-training-mode-philosophy)
7. [Troubleshooting Common Issues](#7-troubleshooting-common-issues)

---

## 1. Platform Overview & Architecture

### What is Service Desk Advanced (SDA)?
Service Desk Advanced is a comprehensive interface for managing enterprise help desk operations. It bridges the gap between Microsoft Intune, Active Directory, and native Windows management protocols. By consolidating these environments into a single, beautiful, user-friendly graphical dashboard, SDA enables **Live-Call Remediation**—allowing Tier 1 technicians to resolve complex endpoint issues on the first touch.

### Why does SDA use a 100% Agentless Architecture?
In modern enterprise environments, deploying, updating, and troubleshooting endpoint agents is a massive drain on IT resources. SDA operates on a strictly **100% Agentless** model. 
* **Zero Footprint:** There is no software installed on the endpoints.
* **No Database Bottlenecks:** We do not rely on thousands of endpoints simultaneously pushing data to a central server.
* **Reduced Attack Surface:** Endpoints do not require write-access to central IT shares.

### How does the API Gateway work?
The core of SDA is `AppLogic.ps1`. When launched, it spins up a local HTTP listener (API Gateway) on port 5050 and renders the `MainUI.html` dashboard in Microsoft Edge. When a technician clicks a button in the UI, the browser sends a JSON payload to the API Gateway. The Gateway translates that web traffic into native PowerShell commands, executes the corresponding script from the `\Tools` directory, and returns the output to the UI.

---

## 2. Security & Attack Surface Mitigation

### Does deploying SDA increase my network's attack surface?
Any centralized orchestration tool alters your attack surface. Because SDA executes scripts with high privileges against remote endpoints, securing the central repository is paramount. We mitigate these risks through strict NTFS isolation and network micro-segmentation.

### How should I secure the central SDA network share?
The central repository (e.g., `\\CORP-FS01\SDA$`) must be locked down using the Principle of Least Privilege.
1. **Zero Endpoint Access:** Standard users and standard endpoints must have absolutely no access (not even Read access) to this directory.
2. **IT Only:** Only authorized Help Desk and IT Security groups should be granted `Modify` rights to the share.

### What firewall ports need to be open?
SDA requires the following ports to be open **inbound to the endpoints, but ONLY from the Help Desk VLAN**:
* **TCP 5985 (WinRM):** The primary, secure execution protocol.
* **TCP 445 (SMB):** Required for PsExec fallback and Out-of-Band data extraction.
* **TCP 135 (RPC):** Required for legacy WMI queries.
* *Security Note:* Do not open these ports globally. Restrict them at the Windows Defender Firewall level so endpoints only accept connections originating from your dedicated IT subnets. This prevents lateral movement from compromised endpoints.

---

## 3. Installation & Deployment Guide

### What are the prerequisites for running the console?
Technicians running the console must have the **RSAT: Active Directory Domain Services** tools installed.  For the entra/intune tools to work properly, they must also have the **Microsoft Graph API** PowerShell modules. 

### How do I set up a new technician's workstation?
Simply have the technician right-click and run `Install-SDADependencies.ps1` as Administrator. This bootstrapper will automatically enforce TLS 1.2, configure the local execution policy, trust the PSGallery, and install all required Microsoft Graph modules.

### Why does `Launch-SDA.cmd` require Administrator privileges?
SDA utilizes protocols like WinRM and PsExec to interact with remote `C$` shares and system processes. These actions inherently require an elevated security token. `Launch-SDA.cmd` uses a specialized VBScript bootstrapper to seamlessly elevate the command prompt, ensuring the PowerShell API Gateway inherits the necessary Admin rights to function.

---

## 4. Identity & Telemetry Engine

### How does SDA know which computer a user is logged into?
SDA uses a hybrid "Pull and Link" telemetry philosophy:
1. **The Background Sweep:** Schedule `NetworkAssetTracker.ps1` to run bi-weekly on a management server, or launch the script directly from the console at your leisure. It queries AD for all active workstations, pings them, and uses WMI to ask, *"Who is logged into you right now?"* It saves this data to `UserHistory.json`.
2. **The Manual Link:** If a user is on a brand new PC that hasn't been swept yet, the technician simply asks for the PC name and clicks the **`+` (Link PC)** button in the UI. This instantly and permanently binds the user to the device in the database.

### How does the Active Directory Profiler work?
When you search for a user, `ActiveDirectoryProfiler.ps1` executes a cascading identity resolution query. It checks for exact SAMAccountName matches, falls back to Ambiguous Name Resolution (ANR), and calculates exact password expiration dates by cross-referencing the user's `PasswordLastSet` attribute against the domain's `MaxPasswordAge` policy.

### Why did my password reset fail with an AD conflict?
If you type a password into a web UI, browsers can sometimes append invisible trailing spaces, or HTTP streams can mangle special characters. SDA's API Gateway explicitly enforces **UTF-8 encoding** on all incoming web traffic and utilizes `.Trim()` functions to strip accidental whitespace, ensuring the password Active Directory receives is exactly what you typed.

---

## 5. Deep Dive: How the Remediation Tools Work

SDA's `\Tools` directory contains highly specialized scripts designed to execute silently and safely on remote endpoints. Here is how the core tools function under the hood:

* **Automated Warranty Routing:** Queries the remote WMI `Win32_BIOS` and `Win32_ComputerSystem` classes to extract the Make and Serial Number. It then dynamically constructs the exact vendor support URL (Dell, Lenovo, HP, Microsoft) and opens it in your browser.
* **Battery Health Analyzer:** Bypasses legacy WMI limitations on Modern Standby laptops by remotely executing the native `powercfg /batteryreport /xml` command. It parses the XML to calculate exact milliwatt-hour (mWh) degradation and renders a graphical health bar in the UI.
* **BitLocker Status Verification:** Uses `manage-bde` logic to check the live encryption status of the remote drive. It simultaneously queries Active Directory for the hidden `msFVE-RecoveryInformation` object to retrieve backed-up recovery keys.
* **Browser Profile Reset:** A highly surgical tool. It forcefully kills frozen `chrome.exe` and `msedge.exe` processes, securely backs up the user's `Default\Bookmarks` file to a temp directory, completely purges the corrupted `AppData\Local` User Data folders, and then restores the bookmarks to the fresh profile.
* **Deep Storage Cleanup:** Calculates initial free space, forcefully deletes the SCCM (`ccmcache`) cache, wipes the Windows Temp and all User Temp directories, empties the Recycle Bin, and triggers a background `cleanmgr.exe /sagerun:1` task.
* **Out-of-Band Data Preservation:** Bypasses strict SMB/File Sharing firewalls by reading the user's Bookmark files locally on the target, encoding them into Base64 strings, and transmitting them back to the technician's PC via the standard WinRM output stream, where they are decoded and saved.
* **Zero-Touch Deployment:** Bypasses the PowerShell "Double-Hop" authentication issue by utilizing PsExec to execute installers as the `NT AUTHORITY\SYSTEM` account. Includes Wake-on-LAN (WoL) functionality, sending Magic Packets to offline targets using MAC addresses cached in the telemetry database.

---

## 6. The "Training Mode" Philosophy

### What is Training Mode?
When the "Training Mode" toggle is active in the SDA sidebar, clicking a remediation tool will *not* execute the script. Instead, it pops up a modal explaining exactly what the script does, how to perform the action manually in person, and the native command-line equivalent.

### Why does Training Mode teach CMD and PsExec instead of PowerShell?
PowerShell is incredibly powerful, but its object-oriented pipelines can be overwhelming for junior technicians. We believe in building a strong foundational understanding of how Windows operates under the hood. Teaching classic, native executables (`net user`, `wmic`, `manage-bde`, `ipconfig`) combined with Sysinternals `PsExec` provides technicians with bulletproof, highly reliable troubleshooting skills that work even when WMI or PowerShell runspaces are broken.

---

## 7. Troubleshooting Common Issues

### Issue: `Launch-SDA.cmd` flashes and instantly closes.
**Cause:** You are likely running the console from a mapped network drive (e.g., `Z:\IT\SDA`). When Windows UAC elevates the command prompt to Administrator, it intentionally strips mapped network drives from the security token, causing a "File Not Found" crash.
**Solution:** We have engineered `Launch-SDA.cmd` to automatically resolve mapped drives to their true UNC paths (`\\server\share\`) before elevating. Ensure you are using the latest version of the launcher. If running locally on a standalone machine, ensure the script is not buried in a folder path containing aggressive special characters.

### Issue: Tools are failing with "WinRM Failed or Blocked."
**Cause:** The target computer's Windows Remote Management service is either stopped, or the Windows Defender Firewall is blocking TCP Port 5985.
**Solution:** SDA will automatically attempt a PsExec fallback using SMB (TCP 445). If both fail, the machine is completely isolated. You can use the **Enable Remote Desktop** tool (which attempts to force the firewall open via PsExec) or contact the user for a screen-share session.

### Issue: Intune/Entra ID features say "Access Denied" or "Cross-Agency Block".
**Cause:** SDA enforces strict cross-tenant security boundaries. The UPN of the technician logged into the Microsoft Graph API must match the `TenantDomain` specified in your `\Config\config.json` file.
**Solution:** Open `config.json`, verify your `TenantDomain` is correct, and ensure the technician has authenticated to the Graph API using the correct organizational account.
