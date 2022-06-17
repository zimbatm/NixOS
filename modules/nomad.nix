{ config, lib, ... }:

with lib;

let
  cfg = config.settings.services.nomad;
in

{
  options.settings.services.nomad = {
    enable = mkEnableOption "the Nomad service";

    datacenter = mkOption {
      type = types.str;
    };

    cluster_size = mkOption {
      type = types.int;
    };
  };

  config = mkIf cfg.enable {
    services.nomad = {
      enable = cfg.enable;
      settings = {
        datacenter = cfg.datacenter;
        server = {
          enabled = true;
          bootstrap_expect = cfg.cluster_size;
        };
      };
    };
  };
}

