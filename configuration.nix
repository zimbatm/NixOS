{ config, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./settings.nix
    ./modules
  ];

  config = {
    settings.system.partitions = {
      # We need to force the partitions e.g. for AWS
      forcePartitions = true;

      partitions =
        let
          boot_cfg = config.settings.boot;
        in
        {
          "/" = {
            enable = true;
            device = "/dev/disk/by-label/nixos_root";
            fsType = "ext4";
            options = [ "defaults" "noatime" "acl" ];
            autoResize = true;
          };
          "/boot" = {
            enable = boot_cfg.separate_partition;
            device = "/dev/disk/by-label/nixos_boot";
            fsType = "ext4";
            options = [ "defaults" "noatime" "nosuid" "nodev" "noexec" ];
            autoResize = true;
          };
          "/boot/efi" = {
            enable = boot_cfg.mode == boot_cfg.modes.uefi;
            device = "/dev/disk/by-label/EFI";
            fsType = "vfat";
          };
        };
    };

    # This value determines the NixOS release with which your system is to be
    # compatible, in order to avoid breaking some software such as database
    # servers. You should change this only after NixOS release notes say you
    # should.
    system.stateVersion = "18.03"; # Did you read the comment?
  };
}

