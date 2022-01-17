{ config, lib, ...}:

with lib;
with (import ../ext_lib.nix);

{

  options.settings.users.available_permission_profiles = mkOption {
    type = types.attrs;
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

      get_json_contents = dir: ext_lib.compose [
        (map ext_lib.traceImportJSON)
        (mapAttrsToList (name: _: dir + ("/" + name)))
        (filterAttrs (name: type: type == "regular" && hasSuffix ".json" name))
        builtins.readDir
      ] dir;

    in ext_lib.compose [
      (map get_tunnels_set)
      get_json_contents
    ];

    tunnel_json = get_tunnel_contents sys_cfg.tunnels_json_dir_path;
  in {

    assertions = let
      mkDuplicates = ext_lib.compose [
        ext_lib.find_duplicates
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
        users_json_data = ext_lib.traceImportJSON users_json_path;
        keys_json_path  = sys_cfg.keys_json_path;
        keys_json_data  = ext_lib.traceImportJSON keys_json_path;

        hostPath = [ "users" "per-host" ];
        rolePath = [ "users" "roles" ];
        permissionProfiles = config.settings.users.available_permission_profiles;

        pathToString = concatStringsSep ".";

        onRoleAbsent = path: abort ''
          The role "${pathToString path}" which was enabled for host "${hostName}" is not defined.'';

        onCycle = entriesSeen: abort ''
          Cycle detected while resolving roles: ${concatMapStringsSep " -> " pathToString entriesSeen}'';

        onProfileNotFound = p: abort ''
          Permissions profile '${p}' not found in file '${toString users_json_path}', available profiles:
            ${concatStringsSep ", " (attrNames permissionProfiles)}'';

        # Given an attrset linking users to their permission profile,
        # resolve the permission profiles and activate the users
        # to obtain an attrset of activated users with the requested permissions
        activateUsers = let
          enableProfile = p: p // { enable = true; };
          retrieveProfile = p: if hasAttr p permissionProfiles
                               then enableProfile(permissionProfiles.${p})
                               else onProfileNotFound p;
        in mapAttrs (_: retrieveProfile);

        # Activate an 'entry' which is either the top-level definition for a host,
        # or a role. For every such entry we activate the users given in the
        # 'enable' property and we recurse into the roles given in the
        # 'enable_roles' property.
        #
        # We maintain a list of the visited entries to be able to detect and report
        # any cycles during role resolution.
        # This structure cannot be an attribute set (which would be more efficient)
        # since attribute sets do not preserve insertion order.
        activateEntry = onEntryAbsent: entriesSeen: path: entry: let
          entryPath = path ++ [ entry ];
          entriesSeen' = entriesSeen ++ [ entryPath ];
          entryData = attrByPath entryPath (onEntryAbsent entryPath) users_json_data;
          direct = activateUsers (attrByPath [ "enable" ] {} entryData);
          # Note: we pass onRoleAbsent instead of onEntryAbsent in the line below
          #       this ensures that an error is thrown if we encounter a
          #       non-existing role
          nested = activateEntries onRoleAbsent entriesSeen' rolePath
                                   (attrByPath [ "enable_roles" ] [] entryData);
        in if (elem entryPath entriesSeen)
           then onCycle entriesSeen'
           else recursiveUpdate direct nested;

        activateEntries = onEntryAbsent: entriesSeen: path: ext_lib.compose [
          # Merge all the results together
          ext_lib.recursiveMerge
          # Activate every entry with the given parameters
          (map (activateEntry onEntryAbsent entriesSeen path))
        ];

        enabledUsers = let
          # We do not abort if a host is not found,
          # in that case we simply do not activate any user for that host.
          onHostAbsent = const {};
        in activateEntry onHostAbsent [] hostPath hostName;
      in recursiveUpdate keys_json_data.keys enabledUsers;

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
        load_tunnel_files = ext_lib.compose [
          addSshTunnels
          # We check in an assertion above that the two attrsets have an
          # empty intersection, so we do not need to worry about the order
          # in which we merge them here.
          ext_lib.recursiveMerge
        ];
      in load_tunnel_files tunnel_json;
    };
  };
}

