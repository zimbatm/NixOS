{ config, lib, ...}:

with lib;
with (import ../msf_lib.nix);

{

  options.settings.users.available_permission_profiles = mkOption {
    type = types.attrs;
    # TODO: remove this default
    default = msf_lib.user_roles;
    description = ''
      Attribute set of the permission profiles that can be defined through JSON.
    '';
  };

  config = let
    sys_cfg  = config.settings.system;
    hostName = config.settings.network.host_name;

    get_tunnel_contents = let

      /*
        Note: if a json value is extracted multiple times, the warning only gets
        printed once per file.
        Since the value of the default expression does not depend on the input
        argument to the function, Nix memoizes the result of the trace call and
        the side-effect only occurs once.
      */
      get_tunnels_set = let
        tunnels_json_path = [ "tunnels" "per-host" ];
        warn_string = "ERROR: JSON structure does not contain the attribute " +
                      concatStringsSep "." tunnels_json_path;
      in attrByPath tunnels_json_path (abort warn_string);

      get_json_contents = dir: msf_lib.compose [
        (map msf_lib.traceImportJSON)
        (mapAttrsToList (name: _: dir + ("/" + name)))
        (filterAttrs (name: type: type == "regular" && hasSuffix ".json" name))
        builtins.readDir
      ] dir;

    in msf_lib.compose [
      (map get_tunnels_set)
      get_json_contents
    ];

    tunnel_json = get_tunnel_contents sys_cfg.tunnels_json_dir_path;
  in {

    assertions = let
      mkDuplicates = msf_lib.compose [
        msf_lib.find_duplicates
        (concatMap attrNames) # map the JSON files to the server names
      ];
      duplicates = mkDuplicates tunnel_json;
    in [
      {
        assertion = length duplicates == 0;
        message   = "Duplicate entries found in the tunnel definitions. " +
                    "Duplicates: " +
                    concatStringsSep ", " duplicates;
      }
    ];

    settings = {
      users.users = let
        users_json_path = sys_cfg.users_json_path;
        users_json_data = msf_lib.traceImportJSON users_json_path;
        keys_json_path  = sys_cfg.keys_json_path;
        keys_json_data  = msf_lib.traceImportJSON keys_json_path;

        #TODO: remove the deprecated version which is only there for
        # backwards compatibility while migrating to the new API
        activateUsers = users: let
          f = if isAttrs users
              then new_activateUsers
              else deprecated_activateUsers;
        in f users;

        new_activateUsers = mapAttrs (_: perms:
          (config.settings.users.available_permission_profiles.${perms}) //
          { enable = true; }
        );

        deprecated_activateUsers = flip genAttrs (const { enable = true; });

        enabledUsers = activateUsers (attrByPath [ "users" "per-host" hostName "enable" ]
                                                 {}
                                                 users_json_data);

        # We maintain a list of the visited roles to be able to detect and report
        # any cycles during role resolution.
        # This structure cannot be an attribute set (which would be more efficient)
        # since attribute sets do not preserve insertion order.
        enabledUsersByRoles = let
          # Given the host name and the json data,
          # retrieve the enabled roles for the given host
          enabledRoles = hostName:
            attrByPath [ "users" "per-host" hostName "enable_roles" ] [];

          onRoleAbsent = role: hostName: abort ''
            The role "${role}" which was enabled for host "${hostName}" is not defined.
          '';

          onCycle = rolesSeen: abort ''
            Cycle detected while resolving roles: ${concatStringsSep ", " rolesSeen}
          '';

          # Activate the users in the given role, recursing into nested subroles
          activateRole = hostName: rolesSeen: role: let
            rolesSeen' = rolesSeen ++ [ role ];
            roleData = attrByPath [ "users" "roles" role ]
                                  (onRoleAbsent role hostName)
                                  users_json_data;
            direct = activateUsers (attrByPath [ "enable" ] {} roleData);
            nested = activateRoles hostName rolesSeen'
                                   (attrByPath [ "enable_roles" ] [] roleData);
          in if (elem role rolesSeen)
             then onCycle rolesSeen'
             else recursiveUpdate direct nested;

          activateRoles = hostName: rolesSeen: msf_lib.compose [
            msf_lib.recursiveMerge
            (map (activateRole hostName rolesSeen))
          ];

        in activateRoles hostName [] (enabledRoles hostName users_json_data);
      in msf_lib.recursiveMerge [ enabledUsers
                                  keys_json_data.keys
                                  enabledUsersByRoles ];

      reverse_tunnel.tunnels = let
        # We add the SSH tunnel by default
        addSshTunnel  = tunnel: let
          ssh_tunnel = {
            reverse_tunnels = {
              ssh = {
                prefix = 0;
                forwarded_port = 22;
              };
            };
          };
        in recursiveUpdate tunnel ssh_tunnel;
        addSshTunnels = mapAttrs (_: addSshTunnel);
        load_tunnel_files = msf_lib.compose [
          addSshTunnels
          # We check in an assertion above that the two attrsets have an
          # empty intersection, so we do not need to worry about the order
          # in which we merge them here.
          msf_lib.recursiveMerge
        ];
      in load_tunnel_files tunnel_json;
    };
  };
}

