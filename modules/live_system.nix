{ config, lib, ... }:

with lib;

let
  sys_cfg = config.settings.system;
in
{
  options.settings.live_system = {
    enable = mkEnableOption "the module for live systems.";
  };

  config = mkIf config.settings.live_system.enable {
    # The live disc overrides SSHd's wantedBy property to an empty value
    # with a priority of 50. We re-override it here.
    # See https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/profiles/installation-device.nix
    systemd.services.sshd.wantedBy = mkOverride 10 [ "multi-user.target" ];

    settings = {
      system = {
        isISO = true;
        # We do not overwrite the ISO partitions
        partitions = {
          forcePartitions = mkForce false;
          partitions = { };
        };
        copy_private_key_to_store = sys_cfg.isProdBuild;
        diskSwap.enable = false;
      };
      boot.mode = "none";
      maintenance.enable = false;
      reverse_tunnel.enable = true;
    };

    services.getty.helpLine = mkForce "";

    documentation.enable = mkOverride 10 false;
    documentation.nixos.enable = mkOverride 10 false;

    networking.wireless.enable = mkOverride 10 false;

    system.extraDependencies = mkOverride 10 [ ];
  };
}
