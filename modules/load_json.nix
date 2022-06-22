{ config, lib, ...}:

with lib;

let
  inherit (config.lib) ext_lib;
in

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

    pathToString = concatStringsSep ".";

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
                      pathToString tunnels_json_path;
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
                    generators.toPretty {} duplicates;
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

        onRoleAbsent = path: let
          formatRoles = ext_lib.compose [
            (map (r: pathToString (rolePath ++ [r])))
            attrNames
            (attrByPath rolePath {})
          ];
        in abort (''The role "${pathToString path}" which was '' +
                  ''enabled for host "${hostName}", is not defined. '' +
                  "Available roles: " +
                  generators.toPretty {} (formatRoles users_json_data));

        onCycle = entriesSeen: abort ("Cycle detected while resolving roles: " +
                                      generators.toPretty {} (map pathToString entriesSeen));

        onProfileNotFound = p: abort (''Permission profile "${p}", mentioned in '' +
                                      ''file "${toString users_json_path}", '' +
                                      "could not be found. " +
                                      "Available profiles: \n" +
                                      generators.toPretty {} (attrNames permissionProfiles));

        # Given an attrset mapping users to their permission profile,
        # resolve the permission profiles and activate the users
        # to obtain an attrset of activated users with the requested permissions.
        # This function return the attrset to be included in the final config.
        activateUsers = let
          enableProfile = p: recursiveUpdate p { enable = true; };
          retrieveProfile = p: if hasAttr p permissionProfiles
                               then enableProfile permissionProfiles.${p}
                               else onProfileNotFound p;
        in mapAttrs (_: retrieveProfile);

        # Resolve an 'entry' which is either the top-level definition for a host,
        # or a role. For every such entry we resolve the users given in the
        # 'enable' property and we recurse into the roles given in the
        # 'enable_roles' property.
        # The result is a mapping of every user to its permissions profile.
        #
        # We maintain a list of the visited entries to be able to detect and report
        # any cycles during role resolution.
        # This structure cannot be an attribute set (which would be more efficient)
        # since attribute sets do not preserve insertion order and if there is a cycle,
        # we want to be able to print it as part of the error message.
        resolveEntry = onEntryAbsent: entriesSeen: path: entry: let
          entryPath = path ++ [ entry ];
          entriesSeen' = entriesSeen ++ [ entryPath ];
          entryData = attrByPath entryPath (onEntryAbsent entryPath) users_json_data;

          direct = attrByPath [ "enable" ] {} entryData;

          # We pass onRoleAbsent instead of onEntryAbsent in the recursive calls below,
          # this ensures that an error is thrown if we encounter a non-existing role.
          nested = resolveEntries onRoleAbsent entriesSeen' rolePath
                                  (attrByPath [ "enable_roles" ] [] entryData);

          # The property "enable_roles_with_profile" allows to enable a role but
          # to set the permission profile of all members of the role to a fixed
          # value.
          # We do mostly the same as for "enable_roles" above,
          # but before returning the result we replace the permission profile.
          nested_with_profile =
            resolveEntriesWithProfiles onRoleAbsent entriesSeen' rolePath
                                       (attrByPath [ "enable_roles_with_profile" ]
                                                   {} entryData);

        in if (elem entryPath entriesSeen)
           then onCycle entriesSeen'
           else [ direct ] ++ nested ++ nested_with_profile;

        resolveEntries = onEntryAbsent: entriesSeen: path:
          concatMap (resolveEntry onEntryAbsent entriesSeen path);

        resolveEntriesWithProfiles = onEntryAbsent: entriesSeen: path: let
          doResolve = resolveEntry onRoleAbsent entriesSeen rolePath;
          replaceProfilesWith = profile: map (mapAttrs (_: _: profile));
          resolveWithProfile  = role: profile: replaceProfilesWith profile
                                                                   (doResolve role);
        in ext_lib.concatMapAttrsToList resolveWithProfile;

        ensure_no_duplicates = attrsets: let
          duplicates = ext_lib.find_duplicate_mappings attrsets;
          msg = "Duplicate permission profiles found for users: " +
                  generators.toPretty {} duplicates;
        in if length (attrNames duplicates) == 0
           then attrsets
           else abort msg;

        enabledUsersForHost = let
          # We do not abort if a host is not found,
          # in that case we simply do not activate any user for that host.
          onHostAbsent = const {};
        in ext_lib.compose [
          activateUsers          # Activate all users
          ext_lib.recursiveMerge # Merge everything together
          ensure_no_duplicates   # Detect any users with multiple permissions
          (resolveEntry onHostAbsent [] hostPath) # resolve the entry for the current server
        ];

        enabledUsers = enabledUsersForHost hostName;

      # Take all enabled users and merge them with
      # the attrset defining their public keys.
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

