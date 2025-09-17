#!/usr/bin/env python3
"""Sanity checks for curtin storage config in autoinstall user-data."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Iterable, Optional

import yaml


def load_yaml(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as stream:
        return yaml.safe_load(stream)


def iter_config_entries(data: dict) -> Iterable[dict]:
    try:
        config = data["autoinstall"]["storage"]["config"]
    except KeyError as exc:  # pragma: no cover - defensive
        missing = " -> ".join(str(part) for part in exc.args)
        raise SystemExit(f"storage config missing key: {missing}")
    if not isinstance(config, list):
        raise SystemExit("storage config must be a list")
    return config


def bootloader_type(data: dict) -> Optional[str]:
    try:
        return data["autoinstall"]["storage"]["bootloader"]["type"]
    except KeyError:
        return None


def collect_ids(config: Iterable[dict]) -> set[str]:
    seen: set[str] = set()
    duplicates: list[str] = []
    for entry in config:
        entry_id = entry.get("id")
        if not entry_id:
            raise SystemExit("Found storage entry without an 'id'")
        if entry_id in seen:
            duplicates.append(entry_id)
        seen.add(entry_id)
    if duplicates:
        dup_list = ", ".join(sorted(set(duplicates)))
        raise SystemExit(f"Duplicate storage ids: {dup_list}")
    return seen


def check_entry(entry: dict, known_ids: set[str]) -> list[str]:
    entry_id = entry.get("id", "<missing>")
    entry_type = entry.get("type")
    errors: list[str] = []

    if entry_type is None:
        errors.append(f"{entry_id}: missing type")
        return errors

    if entry_type == "mount":
        if "device" not in entry:
            errors.append(f"{entry_id}: mount entries must use 'device' to reference a format")
        if "volume" in entry:
            errors.append(f"{entry_id}: mount entries should not use 'volume'; replace with 'device'")
    elif entry_type == "dm_crypt":
        if "volume" not in entry:
            errors.append(f"{entry_id}: dm_crypt entries require 'volume' (the backing partition id)")
        if "device" in entry:
            errors.append(f"{entry_id}: dm_crypt entries should not use 'device'; use 'volume'")
    elif entry_type == "format":
        if "volume" not in entry:
            errors.append(f"{entry_id}: format entries require 'volume'")

    reference_fields = {
        "device": lambda value: [value],
        "volume": lambda value: [value],
        "volgroup": lambda value: [value],
        "devices": lambda value: list(value) if isinstance(value, (list, tuple)) else [value],
    }

    for field, extractor in reference_fields.items():
        if field not in entry:
            continue
        targets = extractor(entry[field])
        for target in targets:
            if not isinstance(target, str):
                errors.append(f"{entry_id}: {field} contains non-string target {target!r}")
                continue
            if target not in known_ids:
                errors.append(f"{entry_id}: {field} references unknown id '{target}'")

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "path",
        nargs="?",
        default=Path("autoinstall/user-data"),
        type=Path,
        help="Path to autoinstall user-data file",
    )
    args = parser.parse_args()

    yaml_data = load_yaml(args.path)
    config = list(iter_config_entries(yaml_data))
    known_ids = collect_ids(config)

    errors: list[str] = []
    for entry in config:
        errors.extend(check_entry(entry, known_ids))

    boot_type = bootloader_type(yaml_data)
    if boot_type == "grub-efi":
        grub_partitions = {
            entry["id"]
            for entry in config
            if entry.get("type") == "partition" and entry.get("grub_device")
        }
        if not grub_partitions:
            errors.append(
                "grub-efi bootloader requires at least one partition with grub_device: true"
            )
        else:
            format_by_volume = {
                entry["volume"]: entry
                for entry in config
                if entry.get("type") == "format" and entry.get("volume")
            }
            mount_by_device = {
                entry["device"]: entry
                for entry in config
                if entry.get("type") == "mount" and entry.get("device")
            }
            has_boot_efi_mount = False
            missing_format = []
            for partition_id in sorted(grub_partitions):
                fmt_entry = format_by_volume.get(partition_id)
                if fmt_entry is None:
                    missing_format.append(partition_id)
                    continue
                mount_entry = mount_by_device.get(fmt_entry["id"])
                if mount_entry and mount_entry.get("path") == "/boot/efi":
                    has_boot_efi_mount = True
            if missing_format:
                missing = ", ".join(missing_format)
                errors.append(
                    f"partition(s) {missing} marked grub_device: true must also be formatted"
                )
            if grub_partitions and not has_boot_efi_mount:
                errors.append(
                    "grub-efi bootloader requires a grub_device partition mounted at /boot/efi"
                )

    if errors:
        for issue in sorted(set(errors)):
            print(f"[ERROR] {issue}", file=sys.stderr)
        return 1

    print("Storage config sanity checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
