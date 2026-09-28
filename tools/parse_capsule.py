#!/usr/bin/env python3
"""Unwrap a signed UEFI FMP capsule (EFI_CAPSULE_HEADER ->
EFI_FIRMWARE_MANAGEMENT_CAPSULE_HEADER -> ...IMAGE_HEADER ->
EFI_FIRMWARE_IMAGE_AUTHENTICATION/PKCS7) and write out the real, unsigned
firmware payload underneath -- e.g. Lenovo's *.CAP BIOS capsule files.

Usage: parse_capsule.py INPUT.CAP [OUTPUT.bin]

See ../GUNYAH_EXIT_SMC.md for why this exists and what to do with the output.
"""
import struct
import sys
import uuid


def guid_at(data, off):
    d1, d2, d3 = struct.unpack_from('<IHH', data, off)
    d4 = data[off + 8:off + 16]
    return uuid.UUID(bytes=struct.pack('>IHH', d1, d2, d3) + d4)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    in_path = sys.argv[1]
    out_path = sys.argv[2] if len(sys.argv) > 2 else 'real_fw_payload.bin'
    data = open(in_path, 'rb').read()

    # EFI_CAPSULE_HEADER
    cap_guid = guid_at(data, 0)
    header_size, flags, capsule_image_size = struct.unpack_from('<III', data, 16)
    print(f"CapsuleGuid: {cap_guid}")
    print(f"HeaderSize: {header_size:#x}  Flags: {flags:#x}  CapsuleImageSize: {capsule_image_size:#x}")
    print(f"File size: {len(data):#x}")

    # EFI_FIRMWARE_MANAGEMENT_CAPSULE_HEADER right after the capsule header
    fmp_off = header_size
    version, embedded_driver_count, payload_item_count = struct.unpack_from('<IHH', data, fmp_off)
    print(f"\nFMP header @ {fmp_off:#x}: version={version} embedded_drivers={embedded_driver_count} payload_items={payload_item_count}")

    item_offsets = []
    for i in range(embedded_driver_count + payload_item_count):
        (off,) = struct.unpack_from('<Q', data, fmp_off + 8 + i * 8)
        item_offsets.append(off)
    print(f"ItemOffsetList: {[hex(o) for o in item_offsets]}")

    # First payload item (index embedded_driver_count) -- adjust if you need
    # a different one out of a multi-payload capsule.
    img_hdr_off = fmp_off + item_offsets[embedded_driver_count]
    ver = struct.unpack_from('<I', data, img_hdr_off)[0]
    img_guid = guid_at(data, img_hdr_off + 4)
    idx = data[img_hdr_off + 20]
    img_size, vendor_code_size = struct.unpack_from('<II', data, img_hdr_off + 24)
    print(f"\nImageHeader @ {img_hdr_off:#x}: version={ver} UpdateImageTypeId={img_guid} "
          f"index={idx} UpdateImageSize={img_size:#x} UpdateVendorCodeSize={vendor_code_size:#x}")

    hw_instance_size = 8 if ver >= 2 else 0
    capsule_support_size = 8 if ver >= 3 else 0
    img_hdr_total = 4 + 16 + 1 + 3 + 4 + 4 + hw_instance_size + capsule_support_size
    payload_off = img_hdr_off + img_hdr_total
    print(f"ImageHeader total size: {img_hdr_total}  -> payload starts @ {payload_off:#x}")

    # EFI_FIRMWARE_IMAGE_AUTHENTICATION (MonotonicCount + WIN_CERTIFICATE_UEFI_GUID/PKCS7)
    monotonic_count = struct.unpack_from('<Q', data, payload_off)[0]
    auth_off = payload_off + 8
    dw_length, w_revision, w_cert_type = struct.unpack_from('<IHH', data, auth_off)
    cert_guid = guid_at(data, auth_off + 8)
    print(f"\nFW_IMAGE_AUTHENTICATION @ {payload_off:#x}: MonotonicCount={monotonic_count}")
    print(f"WIN_CERTIFICATE @ {auth_off:#x}: dwLength={dw_length:#x} wRevision={w_revision:#x} "
          f"wCertType={w_cert_type:#x} CertType={cert_guid}")

    real_fw_off = auth_off + dw_length
    real_fw_size = img_size - (real_fw_off - payload_off)
    print(f"\n>>> Real (unsigned) firmware payload @ {real_fw_off:#x}, size={real_fw_size:#x} ({real_fw_size} bytes)")
    print(f">>> Ends @ {real_fw_off + real_fw_size:#x}, file size is {len(data):#x}")

    with open(out_path, 'wb') as f:
        f.write(data[real_fw_off:real_fw_off + real_fw_size])
    print(f"\nWrote {out_path}")


if __name__ == '__main__':
    main()
