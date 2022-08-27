{ config, lib, ... }:

with lib;

let
  inherit (config.lib) ext_lib;

  cfg = config.settings.network;

  ifaceOpts = { name, ... }: {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
      };

      iface = mkOption {
        type = types.str;
        description = ''
          Interface name, defaults to the name of this entry in the attribute set.
        '';
      };

      fallback = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Select this static config only as a fallback in case DHCP fails.
          No DHCP request will be send out when this option is set to false!
        '';
      };

      address = mkOption {
        type = types.str;
      };

      prefix_length = mkOption {
        type = types.ints.between 0 32;
      };

      gateway = mkOption {
        type = types.str;
      };

      nameservers = mkOption {
        type = with types; listOf str;
        default = [ ];
        description = ''
          DNS servers which will be configured only when this static configuration is selected.
        '';
      };
    };

    config = {
      iface = mkDefault name;
    };
  };
in
{
  options = {
    settings.network = {
      host_name = mkOption {
        type = ext_lib.host_name_type;
      };

      static_ifaces = mkOption {
        type = with types; attrsOf (submodule ifaceOpts);
        default = { };
      };

      nameservers = mkOption {
        type = with types; listOf str;
        default = [ ];
        description = "Globally defined DNS servers, in addition to those obtained by DHCP.";
      };
    };
  };

  config = {
    networking = {
      hostName = mkForce cfg.host_name;
      # All non-manually configured interfaces are configured by DHCP.
      useDHCP = true;
      dhcpcd = {
        persistent = true;
        # Per the manpage, interfaces matching these but also
        # matching a pattern in denyInterfaces, are still denied
        allowInterfaces = [ "en*" "wl*" ];
        # See: https://wiki.archlinux.org/index.php/Dhcpcd#dhcpcd_and_systemd_network_interfaces
        # We also ignore veth interfaces and the docker bridge, these are managed by Docker
        denyInterfaces = [ "eth*" "wlan*" "veth*" "docker*" ];
        extraConfig =
          let
            format_name_servers = concatStringsSep " ";
            mkConfig = _: conf:
              if conf.fallback then ''
                profile static_${conf.iface}
                static ip_address=${conf.address}/${toString conf.prefix_length}
                static routers=${conf.gateway}
                static domain_name_servers=${format_name_servers conf.nameservers}

                # fallback to static profile on ${conf.iface}
                interface ${conf.iface}
                fallback static_${conf.iface}
              '' else ''
                interface ${conf.iface}
                static ip_address=${conf.address}/${toString conf.prefix_length}
                static routers=${conf.gateway}
                static domain_name_servers=${format_name_servers conf.nameservers}
              '';
            mkConfigs = ext_lib.compose [
              (concatStringsSep "\n\n")
              (mapAttrsToList mkConfig)
              ext_lib.filterEnabled
            ];
          in
          mkConfigs cfg.static_ifaces;
      };
      nameservers = cfg.nameservers;
    };
  };
}

