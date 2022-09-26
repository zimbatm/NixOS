{ modulesPath, config, pkgs, lib, ... }:

with lib;

let
  sys_cfg = config.settings.system;
in
{

  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
    "${modulesPath}/installer/cd-dvd/channel.nix"
    ../modules
  ];

  # The live disc overrides SSHd's wantedBy property to an empty value
  # with a priority of 50. We re-override it here.
  # See https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/profiles/installation-device.nix
  systemd.services.sshd.wantedBy = mkOverride 10 [ "multi-user.target" ];

  settings = {
    network.host_name = "rescue-iso";
    system = {
      isISO = true;
      # We do not overwrite the ISO partitions
      partitions = {
        forcePartitions = mkForce false;
        partitions = { };
      };
      private_key_source = ../local/id_tunnel_iso;
      copy_private_key_to_store = sys_cfg.isProdBuild;
      diskSwap.enable = false;
    };
    boot.mode = "none";
    maintenance.enable = false;
    reverse_tunnel.enable = true;
  };

  boot.supportedFilesystems = mkOverride 10 [
    "vfat"
    "tmpfs"
    "auto"
    "squashfs"
    "tmpfs"
    "overlay"
  ];

  services.getty.helpLine = mkForce "";

  documentation.enable = mkOverride 10 false;
  documentation.nixos.enable = mkOverride 10 false;

  networking.wireless.enable = mkOverride 10 false;

  system.extraDependencies = mkOverride 10 [ ];

  isoImage = {
    isoName = mkForce (
      (concatStringsSep "-" [
        sys_cfg.org.iso.file_label
        config.isoImage.isoBaseName
        config.system.nixos.label
        pkgs.stdenv.hostPlatform.system
      ]) + ".iso"
    );
    appendToMenuLabel = " ${sys_cfg.org.iso.menu_label}";
  };
}

