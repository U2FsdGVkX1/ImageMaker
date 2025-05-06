# ImageMaker NEXT

This script automates the process of building custom operating system images. It handles partition creation, root filesystem population using `dnf5`, package installation, source code downloading and extraction, overlaying custom files, and finally, generating a bootable image.

The script is designed to be configurable through "board" profiles, allowing for different image types and configurations to be built with the same core logic.

## Prerequisites

1.  **Root Access**: The script must be run as root.
2.  **SELinux Disabled**: SELinux must be in Permissive mode or disabled. The script will exit if SELinux is Enforcing.
3.  **`genimage-bin`**: The `genimage` binary must be present in the same directory as the `build.sh` script. You can typically obtain this by running a `getgenimage.sh` script.
4.  **`dnf5`**: The `dnf5` package manager is used for populating the rootfs. Ensure it's available in the host system's PATH if not chrooting to an environment that has it.

## Script Parameters

The script accepts the following command-line parameters:

| Option | Argument  | Default Value     | Description                                                                                                |
| :----- | :-------- | :---------------- | :--------------------------------------------------------------------------------------------------------- |
| `-b`   | `board`   | (none)            | **Required.** The name of the board configuration to use. Corresponds to a directory in `./boards/`.       |
| `-r`   | `repourl` | (none)            | **Required.** URL to the DNF repository to be used for the base rootfs installation.                       |
| `-a`   | `arch`    | `riscv64`         | Target architecture for the image (e.g., `riscv64`, `x86_64`, `aarch64`). Used by `dnf5`.                  |
| `-l`   | `loader`  | `grub2`           | Specifies the bootloader type. Options: `grub2`, `extlinux`, `systemd`.                                    |
| `-d`   | `desktop` | `Minimal`         | Specifies the desktop environment to install. Options: `Minimal`, `GNOME`, `Xfce`. Affects base packages.  |
| `-t`   | `tag`     | (none)            | An optional tag to select a specific variant of a board configuration.                                     |
| `-R`   |           |                   | Resume a previously failed build. The script will attempt to continue from the last successful major step. |

## Usage Example

```bash
sudo ./build.sh -b QEMU/Generic -r https://mirror.iscas.ac.cn/fedora-riscv/releases/rawhide/Everything/riscv64/os -d GNOME
