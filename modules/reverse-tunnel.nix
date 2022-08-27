{ config, pkgs, lib, ... }:

with lib;

let
  inherit (config.lib) ext_lib;

  cfg = config.settings.reverse_tunnel;
  sys_cfg = config.settings.system;

  reverseTunnelOpts = { name, ... }: {
    options = {
      name = mkOption {
        type = types.str;
      };
      prefix = mkOption {
        type = types.ints.between 0 5;
        description = ''
          Numerical prefix to be added to the main port.
        '';
      };
      forwarded_port = mkOption {
        type = types.port;
        description = ''
          The local port from this server to forward.
        '';
      };
    };

    config = {
      name = mkDefault name;
    };
  };

  tunnelOpts = { name, ... }: {
    options = {
      name = mkOption {
        type = ext_lib.host_name_type;
      };

      remote_forward_port = mkOption {
        type = with types; either (ints.between 0 0) (ints.between 2000 9999);
        description = "The port used for this server on the relay servers.";
      };

      # We allow the empty string to allow bootstrapping
      # an installation where the key has not yet been generated
      public_key = mkOption {
        type = types.either ext_lib.empty_str_type ext_lib.pub_key_type;
      };

      generate_secrets = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Setting used by the python scripts generating the secrets.
          Setting this option to false makes sure that no secrets get generated for this host.
        '';
      };

      copy_key_to_users = mkOption {
        type = with types; listOf str;
        default = [ ];
        description = ''
          A list of users to which this public key will be copied for SSH authentication.
        '';
      };

      reverse_tunnels = mkOption {
        type = with types; attrsOf (submodule reverseTunnelOpts);
        default = { };
      };
    };

    config = {
      name = mkDefault name;
    };
  };

  relayServerOpts = { name, ... }: {
    options = {
      name = mkOption {
        type = types.str;
      };

      addresses = mkOption {
        type = with types; listOf str;
      };

      public_key = mkOption {
        type = ext_lib.pub_key_type;
      };

      ports = mkOption {
        type = with types; listOf port;
        default = [ 22 80 443 ];
      };
    };

    config = {
      name = mkDefault name;
    };
  };
in
{

  options = {
    settings.reverse_tunnel = {
      enable = mkEnableOption "the reverse tunnel services";

      tunnels = mkOption {
        type = with types; attrsOf (submodule tunnelOpts);
      };

      relay_servers = mkOption {
        type = with types; attrsOf (submodule relayServerOpts);
      };

      relay = {
        enable = mkEnableOption "the relay server functionality";

        tunneller.keys = mkOption {
          type = with types; listOf str;
          default = [ ];
          description = "The list of keys which are allowed to access " +
            "the tunneller user to create tunnels.";
        };
      };
    };
  };

  config =
    let
      includeTunnel = tunnel: ext_lib.stringNotEmpty tunnel.public_key &&
        tunnel.remote_forward_port > 0;
      add_port_prefix = prefix: base_port: 10000 * prefix + base_port;
      extract_prefix = reverse_tunnel: reverse_tunnel.prefix;
      get_prefixes = mapAttrsToList (_: extract_prefix);
    in
    mkIf (cfg.enable || cfg.relay.enable) {

      assertions =
        let
          # Functions to detect duplicate prefixes in our tunnel config
          toDuplicatePrefixes = ext_lib.compose [
            ext_lib.find_duplicates
            get_prefixes
            (getAttr "reverse_tunnels")
          ];
          pretty_print_prefixes = host: prefixes:
            let
              sorted_prefixes = concatMapStringsSep ", " toString (naturalSort prefixes);
            in
            "${host}: ${sorted_prefixes}";

          mkDuplicatePrefixes = ext_lib.compose [
            # Pretty-print the results
            (mapAttrsToList pretty_print_prefixes)
            # Filter out the entries with duplicate prefixes
            (filterAttrs (_: prefixes: length prefixes != 0))
            # map tunnels configs to their duplicate prefixes
            (mapAttrs (_: toDuplicatePrefixes))
          ];
          duplicate_prefixes = mkDuplicatePrefixes cfg.tunnels;

          # Use the update_duplicates_set function to calculate
          # a set marking duplicate ports, filter out the duplicates,
          # and return the result as a list of port numbers.
          mkDuplicatePorts = ext_lib.compose [
            ext_lib.find_duplicates
            (filter (port: port != 0)) # Ignore entries with port set to zero
            (map (getAttr "remote_forward_port"))
            # select the port attribute
            attrValues # convert to a list of the tunnel definitions
          ];
          duplicate_ports = mkDuplicatePorts cfg.tunnels;
        in
        [
          {
            assertion = cfg.enable -> hasAttr config.networking.hostName cfg.tunnels;
            message = "Tunneling is enabled for this server but its hostname is " +
              "not included in ${toString sys_cfg.tunnels_json_dir_path}";
          }
          {
            assertion = length duplicate_prefixes == 0;
            message = "Duplicate prefixes defined! Details: " +
              concatStringsSep "; " duplicate_prefixes;
          }
          {
            assertion = length duplicate_ports == 0;
            message = "Duplicate tunnel ports defined! " +
              "Duplicates: " +
              concatStringsSep ", " duplicate_ports;
          }
          {
            assertion = cfg.relay.enable ->
              hasAttr config.networking.hostName cfg.relay_servers;
            message = "This host is set as a relay, " +
              "but its host name could not be found in the list of relays! " +
              "Defined relays: " +
              concatStringsSep ", " (attrNames cfg.relay_servers);
          }
        ];

      users =
        let
          tunneller = "tunneller";
        in
        {
          extraUsers = {
            tunnel =
              let
                prefixes = tunnel: get_prefixes tunnel.reverse_tunnels;
                mkLimitation = base_port: prefix:
                  ''restrict,port-forwarding,permitlisten="${toString (add_port_prefix prefix base_port)}"'';
                mkKeyConfig = tunnel: concatStringsSep " " [
                  (concatMapStringsSep "," (mkLimitation tunnel.remote_forward_port)
                    (prefixes tunnel))
                  tunnel.public_key
                  "tunnel@${tunnel.name}"
                ];
                mkKeyConfigs = ext_lib.compose [
                  naturalSort
                  (mapAttrsToList (_: mkKeyConfig))
                  (filterAttrs (_: includeTunnel))
                ];
              in
              {
                extraGroups = mkIf cfg.relay.enable [
                  config.settings.users.ssh-group
                  config.settings.users.rev-tunnel-group
                ];
                openssh.authorizedKeys.keys = mkIf cfg.relay.enable (mkKeyConfigs cfg.tunnels);
              };

            ${tunneller} = mkIf cfg.relay.enable {
              group = tunneller;
              isNormalUser = false;
              isSystemUser = true;
              shell = pkgs.shadow;
              # The fwd-tunnel-group is required to be able to proxy through the relay
              extraGroups = [
                config.settings.users.ssh-group
                config.settings.users.fwd-tunnel-group
              ];
              openssh.authorizedKeys.keys =
                let
                  addKeyLimitations = k: ''restrict,port-forwarding ${k}'';
                in
                map addKeyLimitations cfg.relay.tunneller.keys;
            };
          };

          groups = {
            ${tunneller} = { };
          };
        };

      # This line is very important, it ensures that the remote hosts can
      # set up their reverse tunnels without any issues with host keys
      programs.ssh.knownHosts =
        mapAttrs
          (_: conf: {
            hostNames = conf.addresses;
            publicKey = conf.public_key;
          })
          cfg.relay_servers;

      systemd.services =
        let
          make_tunnel_service = tunnel: relay: {
            enable = true;
            description = "AutoSSH reverse tunnel service to ensure resilient ssh access";
            wants = [ "network.target" ];
            after = [ "network.target" ];
            wantedBy = [ "multi-user.target" ];
            environment = {
              AUTOSSH_GATETIME = "0";
              AUTOSSH_PORT = "0";
              AUTOSSH_MAXSTART = "10";
            };
            serviceConfig = {
              User = "tunnel";
              Type = "simple";
              Restart = "always";
              RestartSec = "10min";
            };
            script =
              let
                mkRevTunLine = port: rev_tnl: concatStrings [
                  "-R "
                  (toString (add_port_prefix rev_tnl.prefix port))
                  ":localhost:"
                  (toString rev_tnl.forwarded_port)
                ];
                mkRevTunLines = port: ext_lib.compose [
                  (concatStringsSep " \\\n      ")
                  (mapAttrsToList (_: mkRevTunLine port))
                ];
                rev_tun_lines = mkRevTunLines tunnel.remote_forward_port
                  tunnel.reverse_tunnels;
              in
              ''
                for host in ${concatStringsSep " " relay.addresses}; do
                  for port in ${concatMapStringsSep " " toString relay.ports}; do
                    echo "Attempting to connect to ''${host} on port ''${port}"
                    ${pkgs.autossh}/bin/autossh \
                      -T -N \
                      -o "ExitOnForwardFailure=yes" \
                      -o "ServerAliveInterval=10" \
                      -o "ServerAliveCountMax=5" \
                      -o "ConnectTimeout=360" \
                      -o "UpdateHostKeys=no" \
                      -o "StrictHostKeyChecking=yes" \
                      -o "UserKnownHostsFile=/dev/null" \
                      -o "IdentitiesOnly=yes" \
                      -o "Compression=yes" \
                      -o "ControlMaster=no" \
                      ${rev_tun_lines} \
                      -i ${sys_cfg.private_key} \
                      -p ''${port} \
                      -l tunnel \
                      ''${host}
                  done
                done
              '';
          };

          make_tunnel_services = tunnel: relay_servers:
            optionalAttrs (includeTunnel current_host_tunnel) (
              mapAttrs'
                (_: relay: nameValuePair "autossh-reverse-tunnel-${relay.name}"
                  (make_tunnel_service tunnel relay))
                relay_servers
            );

          # Load the config of the host currently being built from the settings
          # Assertions are only checked after the config has been evaluated,
          # so we cannot be sure that the host is present at this point.
          current_host_tunnel = cfg.tunnels.${config.networking.hostName} or null;

          tunnel_services = optionalAttrs
            (cfg.enable &&
              current_host_tunnel != null)
            (make_tunnel_services current_host_tunnel
              cfg.relay_servers);

          monitoring_services = optionalAttrs cfg.relay.enable {
            port_monitor = {
              enable = true;
              serviceConfig = {
                User = "root";
                Type = "oneshot";
              };
              script = ''
                ${pkgs.iproute}/bin/ss -Htpln6 | ${pkgs.coreutils}/bin/sort -n
              '';
              # Every 5 min
              startAt = "*:0/5:00";
            };
          };
        in
        tunnel_services // monitoring_services;
    };
}

