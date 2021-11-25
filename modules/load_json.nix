{ config, lib, ...}:

with lib;
with (import ../msf_lib.nix);

{
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
        remoteTunnel    = msf_lib.user_roles.remoteTunnel;
        keys_json_path  = sys_cfg.keys_json_path;
        keys_json_data  = msf_lib.traceImportJSON keys_json_path;

        /*
          Load the list at path in an attribute set and convert it to
          an attribute set with every list element as a key and the value
          set to a given constant value.
          If the given path cannot be found in the loaded JSON structure,
          then the value of onAbsent will be used as input instead.

          Example:
            listToAttrs_const [ "per-host" "benuc002" "enable" ]
                              val
                              []
                              { per-host.benuc002.enable = [ "foo", "bar" ]; }
            => { foo = val; bar = val; }
        */
        listToAttrs_const = path: value: onAbsent:
          msf_lib.compose [ (flip genAttrs (const value))
                            (attrByPath path onAbsent) ];

        remoteTunnelUsers = listToAttrs_const [ "users" "remote_tunnel" ]
                                              remoteTunnel
                                              [] users_json_data;
        enabledUsers      = listToAttrs_const [ "users" "per-host" hostName "enable" ]
                                              { enable = true; }
                                              [] users_json_data;

        enabledUsersByRoles = let
          # Given the host name and the json data,
          # retrieve the enabled roles for the given host
          enabledRoles = hostName:
            attrByPath [ "users" "per-host" hostName "enable_roles" ] [];
          onRoleAbsent = role: hostName:
            abort ''The role "${role}" which was enabled for host "${hostName}" is not defined.'';
          # Activate the users in the given role
          activateRole = hostName: role: let
            role_data = attrByPath [ "users" "roles" role ]
                                   (onRoleAbsent role hostName)
                                   users_json_data;
            direct = listToAttrs_const [ "enable" ]
                                       { enable = true; }
                                       []
                                       role_data;
            nested = activateRoles hostName
                                   (attrByPath [ "enable_roles" ] [] role_data);
            enabled_users = msf_lib.recursiveMerge ([ direct ] ++ nested);

            # TODO: Backwards compat, to be removed
            compat_enabled_users = listToAttrs_const [ "users" "roles" role ]
                                                     { enable = true; }
                                                     (onRoleAbsent role hostName)
                                                     users_json_data;
          in if isAttrs role_data
             then enabled_users
             else trace ''Warning: role ${role} is using a legacy format that will soon not be supported anymore!''
                        compat_enabled_users;

          activateRoles = hostName: map (activateRole hostName);
        in activateRoles hostName (enabledRoles hostName users_json_data);
      in msf_lib.recursiveMerge ([ remoteTunnelUsers
                                   enabledUsers
                                   keys_json_data.keys ] ++
                                   enabledUsersByRoles);

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

