{ config, pkgs, lib, ... }:

with lib;

let
  inherit (config.lib) ext_lib;

  cfg = config.settings.sshd;
  cfg_users = config.settings.users.users;
  cfg_rev_tun = config.settings.reverse_tunnel;
in


{
  options = {
    settings = {
      fail2ban.enable = mkOption {
        type = types.bool;
        default = !config.settings.sshguard.enable;
      };
      sshguard.enable = mkOption {
        type = types.bool;
        default = true;
      };
    };
  };

  config = {
    services = {
      openssh =
        let
          # We define a function to build the Match section defining the
          # configured ForceCommand settings.
          # For users having a ForceCommand configured, we group together all users
          # having the same ForceCommand and then generate a Match section for every
          # such group of users.
          buildForceCommandSection =
            let
              hasForceCommand = _: user: user.enable && ! (isNull user.forceCommand);

              filterForceCommand = filterAttrs hasForceCommand;

              # Nix strings that refer to store paths, like the string holding the
              # ForceCommand in this case, carry a context that tracks the
              # dependencies that need to be present in the store in order for this
              # string to actually make sense. So in the case of the ForceCommand
              # here, the context would track the executables present in the command
              # string, like e.g.  ${pkgs.docker}/bin/docker}.
              # If Nix did not do this, then it could not guarantee that executables
              # mentioned in the string, will actually be present in the store of
              # the resulting system.
              #
              # However, Nix does not allow for strings carrying such contexts to be
              # used as keys to attribute sets (the reason for this seems to be
              # related to how attribute sets are internally represented).
              # And therefore the groupBy command cannot use the forceCommand string
              # as a key to group by.
              #
              # So, we need to use unsafeDiscardStringContext which discards the
              # string's context, after which Nix allows us to use the string as
              # a key in an attribute set.
              # We need to be careful though, since this means that the keys do not
              # carry any dependency information anymore and so if we would use these
              # keys to construct the resulting sshd_config file, then the dependencies
              # would not actually be included in the Nix store.
              # We therefore hash the string, which ensures that it can only be used
              # as a key but does not actually contain usable content anymore.
              # By doing so, we make sure that to build the final sshd_config file,
              # we need to grab the original string, with dependency context included,
              # from the users in the group.
              hashCommand = ext_lib.compose [
                (builtins.hashString "sha256")
                (builtins.unsafeDiscardStringContext)
              ];

              # As explained above, we cannot use the key of the groupBy result.
              # Instead we get the forceCommand, including dependency context, from
              # the actual users.
              # Since we grouped the users by command, they are guaranteed to all
              # have the same forceCommand value and we can simply look at the first
              # one in the list (which is also guaranteed to be non empty).
              cleanResults = mapAttrs (_: users: {
                inherit (builtins.head users) forceCommand;
                users = map (user: user.name) users;
              });

              groupByCommand =
                let
                  doGroupByCommand = groupBy (user: hashCommand user.forceCommand);
                in
                ext_lib.compose [
                  cleanResults
                  doGroupByCommand
                  attrValues
                ];

              toCfgs = mapAttrsToList (_: res: ''
                Match User ${concatStringsSep "," res.users}
                PermitTTY no
                ForceCommand ${pkgs.writeShellScript "ssh_force_command" res.forceCommand}
              '');

            in
            ext_lib.compose [
              (concatStringsSep "\n")
              toCfgs
              groupByCommand
              filterForceCommand
            ];
        in
        {
          enable = true;
          # Ignore the authorized_keys files in the users' home directories,
          # keys should be added through the config.
          authorizedKeysFiles = mkForce [ "/etc/ssh/authorized_keys.d/%u" ];
          permitRootLogin = mkDefault "no";
          forwardX11 = false;
          passwordAuthentication = false;
          challengeResponseAuthentication = false;
          #TODO: replace previous line by the following once all systems
          #      have been upgraded to NixOS 22.05
          #kbdInteractiveAuthentication = false;
          allowSFTP = true;
          ports =
            let
              host_name = config.networking.hostName;
              relay_ports = cfg_rev_tun.relay_servers.${host_name}.ports;
            in
            mkIf cfg_rev_tun.relay.enable relay_ports;
          kexAlgorithms = [
            "sntrup761x25519-sha512@openssh.com"
            "curve25519-sha256@libssh.org"
          ];
          ciphers = [
            "aes256-gcm@openssh.com"
            "chacha20-poly1305@openssh.com"
          ];
          macs = [
            "hmac-sha2-512-etm@openssh.com"
            "hmac-sha2-256-etm@openssh.com"
            "umac-128-etm@openssh.com"
          ];
          extraConfig = ''
            StrictModes yes
            AllowAgentForwarding no
            TCPKeepAlive yes
            ClientAliveInterval 10
            ClientAliveCountMax 5
            GSSAPIAuthentication no
            KerberosAuthentication no

            AllowGroups wheel ${config.settings.users.ssh-group}

            AllowTcpForwarding no
            AllowAgentForwarding no

            Match Group wheel
              AllowTcpForwarding yes

            Match Group ${config.settings.users.rev-tunnel-group},!wheel
              AllowTcpForwarding remote

            Match Group ${config.settings.users.fwd-tunnel-group},!wheel
              AllowTcpForwarding local

            ${buildForceCommandSection cfg_users}
          '';
        };

      fail2ban = mkIf config.settings.fail2ban.enable {
        inherit (config.settings.fail2ban) enable;
        jails.ssh-iptables = lib.mkForce "";
        jails.ssh-iptables-extra = ''
          action   = iptables-multiport[name=SSH, port="${
            concatMapStringsSep "," toString config.services.openssh.ports
          }", protocol=tcp]
          maxretry = 3
          findtime = 3600
          bantime  = 3600
          filter   = sshd[mode=extra]
        '';
      };

      sshguard = mkIf config.settings.sshguard.enable {
        inherit (config.settings.sshguard) enable;
        # We are a bit more strict on the relays
        attack_threshold =
          if cfg_rev_tun.relay.enable
          then 40 else 80;
        blocktime = 10 * 60;
        detection_time = 7 * 24 * 60 * 60;
        whitelist = [ "localhost" ];
      };
    };
  };

}

