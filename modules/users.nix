{ config, lib, pkgs, ... }:

with lib;

let
  inherit (config.lib) ext_lib;

  cfg     = config.settings.users;
  sys_cfg = config.settings.system;

  userOpts = { name, config, ... }: {
    options = {
      name = mkOption {
        type = types.str;
      };

      enable = mkEnableOption "the user";

      sshAllowed = mkOption {
        type    = types.bool;
        default = false;
      };

      extraGroups = mkOption {
        type    = with types; listOf str;
        default = [];
      };

      hasShell = mkOption {
        type    = types.bool;
        default = false;
      };

      canTunnel = mkOption {
        type    = types.bool;
        default = false;
      };

      public_keys = mkOption {
        type    = with types; listOf ext_lib.pub_key_type;
        default = [];
      };

      forceCommand = mkOption {
        type    = with types; nullOr str;
        default = null;
      };
    };
    config = {
      name = mkDefault name;
    };
  };

  whitelistOpts = { name, config, ... }: {
    options = {
      enable = mkEnableOption "the whitelist";

      group = mkOption {
        type = types.str;
      };

      commands = mkOption {
        type    = with types; listOf str;
        default = [ ];
      };
    };
    config = {
      group = mkDefault name;
    };
  };

in {

  options = {
    settings.users = {
      users = mkOption {
        type    = with types; attrsOf (submodule userOpts);
        default = {};
      };

      whitelistGroups = mkOption {
        type    = with types; attrsOf (submodule whitelistOpts);
        default = {};
      };

      shell-user-group = mkOption {
        type     = types.str;
        default  = "shell-users";
        readOnly = true;
      };

      ssh-group = mkOption {
        type     = types.str;
        default  = "ssh-users";
        readOnly = true;
        description = ''
          Group to tag users who are allowed log in via SSH
          (either for shell or for tunnel access).
        '';
      };

      fwd-tunnel-group = mkOption {
        type     = types.str;
        default  = "ssh-fwd-tun-users";
        readOnly = true;
      };

      rev-tunnel-group = mkOption {
        type     = types.str;
        default  = "ssh-rev-tun-users";
        readOnly = true;
      };
    };
  };

  config = let
    public_keys_for = user: map (key: "${key} ${user.name}")
                                user.public_keys;
  in {
    settings.users.users = let
      # Build an attrset of all public keys defined for tunnels that need to be
      # copied to users.
      # See settings.reverse_tunnel.tunnels.*.copy_key_to_user
      keysToCopy = let
        tunnels = config.settings.reverse_tunnel.tunnels;

        # Convert a tunnel definition to a partial user definition with its pubkeys
        # We collect for every user the keys to be copied into a set
        # We cannot use a list directly since recursiveMerge only merges attrsets
        tunnelToUsers = t: map (u: {
          ${u} = optionalAttrs (ext_lib.stringNotEmpty t.public_key) {
            public_keys = { ${t.public_key} = true; };
          };
        }) t.copy_key_to_users;

        tunnelsToUsers = ext_lib.compose [
          # Convert the attrsets containing the keys into lists
          (mapAttrs (_: u: { public_keys = attrNames u.public_keys; }))
          # Merge all definitions together
          ext_lib.recursiveMerge
          # Apply the function converting tunnel definitions to user definitions
          (concatMap tunnelToUsers)
          attrValues
        ];
      in tunnelsToUsers tunnels;
    in keysToCopy;

    users = {
      mutableUsers = false;

      # !! These lines are very important !!
      # Without it, the ssh groups are not created
      # and no-one has SSH access to the system!
      groups = ext_lib.recursiveMerge [
        {
          ${cfg.ssh-group}        = { };
          ${cfg.fwd-tunnel-group} = { };
          ${cfg.rev-tunnel-group} = { };
          ${cfg.shell-user-group} = { };
        }
        # Create the groups that are used for whitelisting sudo commands
        (ext_lib.compose [ (mapAttrs (_: _: {}))
                           ext_lib.filterEnabled ]
                         cfg.whitelistGroups)
        # Create a group per user
        (ext_lib.compose [ (mapAttrs' (_: u: nameValuePair u.name {}))
                           ext_lib.filterEnabled ]
                         cfg.users)
      ];

      users = let
        isRelay = config.settings.reverse_tunnel.relay.enable;

        hasForceCommand = user: ! isNull user.forceCommand;

        hasShell = user: user.hasShell || (hasForceCommand user && isRelay);

        mkUser = _: user: {
          name         = user.name;
          isNormalUser = user.hasShell;
          isSystemUser = ! user.hasShell;
          group        = user.name;
          extraGroups  = user.extraGroups ++
                         (optional (user.sshAllowed || user.canTunnel) cfg.ssh-group) ++
                         (optional user.canTunnel cfg.fwd-tunnel-group) ++
                         (optional user.hasShell  cfg.shell-user-group) ++
                         (optional user.hasShell  "users");
          shell        = if (hasShell user) then config.users.defaultUserShell else pkgs.shadow;
          openssh.authorizedKeys.keys = public_keys_for user;
        };

        mkUsers = ext_lib.compose [ (mapAttrs mkUser)
                                    ext_lib.filterEnabled ];
      in mkUsers cfg.users;
    };

    settings.reverse_tunnel.relay.tunneller.keys = let
      mkKeys = ext_lib.compose [ # Filter out any duplicates
                                 unique
                                 # Flatten this list of lists to get
                                 # a list containing all keys
                                 flatten
                                 # Map every user to a list of its public keys
                                 (mapAttrsToList (_: user: public_keys_for user)) ];
    in mkKeys cfg.users;

    security.sudo.extraRules = let
      addDenyAll = cmds: [ "!ALL" ] ++ cmds;
      mkRule = name: opts: { groups = [ opts.group ];
                             runAs = "root";
                             commands = map (command: { inherit command;
                                                        options = [ "SETENV" "NOPASSWD" ]; })
                                            (addDenyAll opts.commands); };
    in ext_lib.compose [ (mapAttrsToList mkRule)
                         ext_lib.filterEnabled ]
                       cfg.whitelistGroups;
  };
}

