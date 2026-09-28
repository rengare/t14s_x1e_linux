# Investigating a cleaner EL2 handoff: the `EXIT_GUNYAH` SMC

`qebspil` (see the main [README](README.md)) exists as a workaround for a real
limitation: on this laptop's firmware, bare-metal EL2 Linux can authenticate
the ADSP/CDSP via PAS just fine, but the actual *reset-release* step silently
never happens unless triggered by the hypervisor (Gunyah) itself — see
[Stephan Gerhold's commit message](https://git.kernel.org/pub/scm/linux/kernel/git/sre/linux-misc.git/commit/?h=thinkpad-t14s-x1e)
for `qcom,broken-reset`. `slbounce` works around the *bigger* version of this
same problem (owning EL2 at all) by riding Microsoft's Secure-Launch/DRTM
chain via a genuine `tcblaunch.exe` rather than asking Gunyah to step aside
through any supported interface.

This document records an investigation into whether a cleaner mechanism
exists on this specific hardware — and the reproducible method used to check,
in case Lenovo/Qualcomm ship a firmware update that changes the answer.

## The lead

Qualcomm has published real code for exactly this class of transition on
other current-generation platforms:

- A U-Boot patch series for Dragonwing/QCS9100 (`mach-snapdragon: Add early
  EL2...`, Aswin Murugan, July 2026) adds `CONFIG_QCOM_EL2_GUNYAH_EXIT_SUPPORT`
  — TrustZone SMC function `0x02000121`, parameter ID `0x23`, selector
  `EXIT_GUNYAH = 1`, issued at EL1 before continuing at EL2.
- An older, related mechanism exists on Radxa's Dragon Q6A, documented by
  [TravMurav](https://github.com/TravMurav/Qcom-Secure-Launch): UEFI's EnvDxe
  checks `/chosen/radxa,enable-kvm` and issues `smc(0x2000121, 0, 0, 1)` at
  `ExitBootServices()`; Gunyah intercepts it and returns execution at EL2.
- Separately, 2026 upstream `remoteproc: qcom: pas` patches explicitly handle
  the case where "the same SoC runs Linux at EL2" and Linux must perform the
  Q6 Stage-2-equivalent memory protection itself (work Gunyah/QHEE would
  normally do) — evidence that bare-EL2 PAS is becoming a first-class
  supported configuration upstream, not just something downstream
  experimenters are doing.

If this laptop's firmware implements the same `EXIT_GUNYAH`-class SMC, it
could in principle let Linux own EL2 directly, without any of the
Secure-Launch/`tcblaunch.exe` machinery `slbounce` currently needs.

## Method

1. Downloaded Lenovo's "Qualcomm Integrated System Software and Firmware
   Package" for this exact model (ThinkPad T14s Gen 6, Type 21N1) from
   [support.lenovo.com](https://support.lenovo.com/us/en/downloads/ds569777) —
   note: this page is behind Akamai bot-protection that blocks non-browser
   HTTP clients (TLS/fingerprint-based, not IP-based), so it has to be
   downloaded with a real browser, not `curl`/`wget`.
2. The download is an Inno Setup installer (`n42qq22w.exe`). Extract it with
   [`innoextract`](https://constexpr.org/innoextract/) (`apt install
   innoextract`):
   ```
   innoextract -e -m n42qq22w.exe
   ```
3. The system firmware capsule is at
   `.../N42ET98W/BIOS/N42ET98W.CAP` — a signed UEFI FMP capsule. Unwrap the
   `EFI_CAPSULE_HEADER` → `EFI_FIRMWARE_MANAGEMENT_CAPSULE_HEADER` →
   `EFI_FIRMWARE_MANAGEMENT_CAPSULE_IMAGE_HEADER` →
   `EFI_FIRMWARE_IMAGE_AUTHENTICATION` (PKCS7) structure to get the real,
   unsigned firmware volume. `tools/parse_capsule.py` in this repo does this.
4. The unwrapped payload is a Qualcomm `MSS1`-wrapped EFI Firmware Volume
   (`_FVH`). Parse and extract it with the
   [`uefi_firmware`](https://github.com/theopolis/uefi-firmware-parser)
   Python package (`pip install --user uefi_firmware`; the `uefitool` apt
   package only ships a GUI and isn't useful for scripted extraction):
   ```
   uefi-firmware-parser -b -e -O real_fw_payload.bin
   ```
5. Locate the driver that actually issues SMC calls — `ScmDxe`
   (`QcomPkg/Drivers/TzDxe/ScmDxe`, findable by its `.ui` name section in the
   extracted tree) — and disassemble it:
   ```
   aarch64-linux-gnu-objdump -d ScmDxe.pe
   ```
6. Search for the target SMC ID two ways, since a 32-bit immediate loaded via
   the standard AArch64 `mov`/`movk` two-instruction idiom never appears as a
   contiguous constant in a raw byte/string search:
   - Raw bytes: search for the little-endian constant directly (catches data-
     table/literal-pool references).
   - Instructions: `grep` the disassembly for `mov w<n>, #0x0121` /
     `movk w<n>, #0x0200, lsl #16` pairs (catches inline immediate loads).

## Result

`ScmDxe` does register a real `ExitBootServices()`-time SMC handler
(`ScmArmV8ExitBootServicesHandler`, found via its own error string). Tracing
every Qualcomm-OEM-range SMC ID (`0x0200xxxx`) the driver actually constructs
gives exactly: `0x02000601`, `0x02000602`, `0x02000603`, `0x02000801`. The
`ExitBootServices` handler uses `0x02000801` — cross-referenced against
nearby strings (`TzInitLogBuffer`, `QseeRegisterLogBuffer`,
`TZ_OS_GET_LOG_STATUS_ID`, `TzDiagOffset`), this is a QSEE diagnostic-log
flush, **not** a hypervisor handoff.

`0x02000121` (`EXIT_GUNYAH`) does not appear anywhere in `ScmDxe`, nor
anywhere in the full ~21MB firmware volume, by either search method.

The capsule also turned out to contain *only* the AArch64 UEFI Firmware
Volume (PEI/DXE phase) — the `FvLength` field in its header exactly matches
the whole unwrapped payload size, meaning there's no separate raw XBL/TZ/HYP
image appended after it. Those earlier-stage, more deeply signed boot
partitions don't appear to be distributed through Windows'
`UpdateCapsule`/ESRT/fwupd mechanism at all on this platform (checked: the
entire Lenovo installer package contains exactly one `.CAP` file).

**Conclusion:** on this laptop's firmware as of BIOS N42ET98W / package
1.5.11.5 (2026-09-28), the `EXIT_GUNYAH` mechanism is not wired up through
any UEFI-phase driver. Whether TrustZone itself has a dormant, unreachable
dispatch case for this SMC ID can't be determined without the actual TZ core
image, which doesn't appear to be obtainable through normal end-user update
channels.

## What's left, if this matters to you later

- Lenovo also lists a separate "BIOS Update Utility for Windows 11 ARM"
  (ds569693) — not yet checked; could theoretically be a different/larger
  capsule, though the working theory above is that TZ/PBL/HYP simply aren't
  distributed to end users this way at all on this SoC generation.
- Re-run this same method against any future Lenovo firmware update.
- Ask directly — this is now a sharp, evidence-backed question ("does Hamoa
  laptop TZ implement the `EXIT_GUNYAH`-equivalent, or was it never
  provisioned?") rather than speculation, worth raising with
  [Stephan Gerhold](https://github.com/stephan-gh) or in the
  [Ubuntu Concept: Snapdragon X Elite](https://discourse.ubuntu.com/t/ubuntu-concept-snapdragon-x-elite/48800)
  thread.
- The only way to get real ground truth on the actual TZ/XBL/PBL images
  would be a direct SPI NOR flash dump (external programmer, or EDL/Firehose
  download-mode tooling if accessible) — real hardware-hacking territory with
  nonzero bricking risk, out of scope for this investigation.
