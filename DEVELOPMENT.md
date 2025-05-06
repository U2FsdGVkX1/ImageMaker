## Board Configuration Structure

The script relies on a specific directory and file structure for board configurations. All board configurations are expected to reside within a `boards` directory, located in the same directory as the `build.sh` script (`$PWD/boards/`).

The primary path for a board configuration is: `$PWD/boards/<board_vendor>/<board_name>/`
If a tag is specified (`-t <tag_name>`), the path becomes: `$PWD/boards/<board_vendor>/<board_name>/tags/<tag_name>/`

A board configuration can consist of the following files and directories (The $boardpath variable is the final configuration directory):

1.  **`inherit` (Optional File)**
    * **Path**: `$boardpath/inherit` or `$boardpath/tags/<tag_name>/inherit`
    * **Format**: A plain text file where each line specifies a base board configuration to inherit from. The configurations are loaded and applied sequentially in the order they appear in this file. Files from boards listed later will overlay files from boards listed earlier. Finally, the files from the current board (the one containing this inherit file) are applied, overlaying anything inherited.
    * **Purpose**: Allows a board configuration to be built upon multiple other "base" or "feature" configurations. This provides a flexible way to compose configurations. For example, you might have a base hardware configuration, then overlay a specific feature set, and finally add board-specific customizations.
        * Each line follows the format:
        * board [optional_tag]
        ```
        QEMU/Generic
        SpacemiT-K1/SpacemiT-K1 free
        ```

2.  **`partitions` (Optional File)**
    * **Path**: `$boardpath/partitions`
    * **Format**: A CSV-like file, with each line defining a partition. Fields are comma-separated:
        `partition_variable_name,mount_point,size,mkfs_command_and_options`
        * `partition_variable_name`: A name used to create a shell variable (e.g., `rootfs`, `boot`). The actual image file will be named `$partition_variable_name.img` (e.g., `rootfs.img`).
        * `mount_point_suffix`: The path relative to the rootfs where this partition will be mounted (e.g., `/boot`, `/boot/efi`, `/`). An empty suffix or `/` refers to the root of the rootfs.
        * `size`: The size of the partition image file (e.g., `100M`, `4G`). Passed to `fallocate -l`.
        * `mkfs_command_and_options`: The command used to create the filesystem on the partition image (e.g., `mkfs.ext4`, `mkfs.vfat`). The partition image file (e.g., `rootfs.img`) will be appended as the last argument to this command.
    * **Example**:
        ```csv
        rootfs,/,15G,mkfs.ext4
        boot,/boot,1G,mkfs.ext4
        efi,/boot/efi,500M,mkfs.fat -F 32
        ```

3.  **`packages` (Optional File)**
    * **Path**: `$boardpath/packages`
    * **Format**: A plain text file listing additional packages to be installed into the rootfs, one package or package group per line. Lines starting with `#` and empty lines are ignored.
    * **Purpose**: To install board-specific software beyond the base packages selected by the `-d` option. These packages are installed using `dnf install -y` inside the chroot.
    * **Example**:
        ```
        # Core utilities
        vim-enhanced
        openssh-server

        # Development tools
        @development-tools
        ```

4.  **`sources` (Optional File)**
    * **Path**: `$boardpath/sources`
    * **Format**: A plain text file listing URLs, one URL per line.
    * **Purpose**: To download files from the internet. If a downloaded file is a tarball (ending in `.tar`, `.tar.xz`, or `.tar.gz`), it will be automatically extracted into the rootfs (`$rootfs`). Other files are just downloaded.
    * **Example**:
        ```
        http://openkoji.iscas.ac.cn/pub/dist-repos/dl/XuanTie/TH1520/kernel-cross/6.6.66-g1c6721ec2918-dirty.tar.gz
        http://openkoji.iscas.ac.cn/pub/dist-repos/dl/XuanTie/TH1520/fw/firmware.tar.gz
        ```

5.  **`repos/` (Optional Directory)**
    * **Path**: `$boardpath/repos/`
    * **Purpose**: This directory can contain custom DNF repository files (`.repo` files). Any `.repo` files found here will be copied to `/etc/yum.repos.d/` within the target rootfs before additional packages are installed.
    * **Structure**:
        ```
        $boardpath/repos/
        └── my-custom.repo
        └── another-corp.repo
        ```

6.  **`overlay/` (Optional Directory)**
    * **Path**: `$boardpath/overlay/`
    * **Purpose**: Files and directories within `overlay/` are copied directly into the rootfs (`$rootfs`), overwriting existing files if they have the same name and path. This is useful for adding custom configuration files, scripts, or any other static assets.
    * **Structure**: The structure within `overlay/` mirrors the desired structure in the rootfs.
        ```
        boards/mycustomboard/overlay/
        ├── etc/
        │   └── custom_settings.conf
        │   └── systemd/
        │       └── system/
        │           └── my-custom.service
        └── usr/
            └── local/
                └── bin/
                    └── my_script.sh
        ```

7.  **`pre/` (Optional Directory)**
    * **Path**: `$boardpath/pre/`
    * **Purpose**: Contains executable shell scripts that are sourced (executed in the context of the main build script) before the `finalize` stage (fstab generation, dnf clean). These scripts can perform custom setup tasks within the chroot or modify the build environment.
        * **Note**: These scripts run *outside* the chroot, but common operations like `chroot_rootfs "some command"` can be called from them.

8.  **`post/` (Optional Directory)**
    * **Path**: `$boardpath/post/`
    * **Purpose**: Contains executable shell scripts that are sourced after `dnf clean all` but before the final image generation. Useful for last-minute modifications or cleanup within the chroot.
        * **Note**: Similar to `pre/` scripts, they run *outside* the chroot.

9.  **`genimage.cfg` (Required File)**
    * **Path**: `$boardpath/genimage.cfg`
    * **Format**: This file follows the configuration syntax required by the `genimage` tool.
    * **Purpose**: Defines how the final disk image is assembled from the partition images (`*.img` files created earlier) and any other required files (like bootloaders). The format and capabilities of this file are extensive and documented by the `genimage` project itself. The build script passes this file to `genimage-bin`.
    * **Example Snippet (illustrative)**:
        ```
        image sdcard.img {
        	hdimage {
        		partition-table-type = gpt
        	}
        	partition efi {
        		image = "efi.img"
        		partition-type-uuid = "U"
        	}
        	partition boot {
        		image = "boot.img"
        		partition-type-uuid = bc13c2ff-59e6-4262-a352-b275fd6f7172
        	}
        	partition rootfs {
        		image = "rootfs.img"
        		partition-type-uuid = "L"
        	}
        }
        ```
        *(Refer to official `genimage` documentation for full syntax)*
