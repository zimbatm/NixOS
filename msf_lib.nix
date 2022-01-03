# Usage:
#   with (import ../msf_lib.nix);
#   msf_lib.<identifier>

with (import <nixpkgs> {});
with lib;

{
  msf_lib = let

    # compose [ f g h ] x == f (g (h x))
    compose = let
      apply = f: x: f x;
    in flip (foldr apply);

    applyN = n: f: compose (genList (const f) n);

    applyTwice = applyN 2;

    filterEnabled = filterAttrs (_: conf: conf.enable);

    /* Find duplicate elements in a list in O(n) time

       Example:
         find_duplicates [ 1 2 2 3 4 4 4 5 ]
         => [ 2 4 ]
    */
    find_duplicates = let
      /* Function to use with foldr
         Given an element and a set mapping elements (as Strings) to booleans,
         it will add the element to the set with a value of:
           - false if the element was not previously there, and
           - true  if the element had been added already
         The result after folding, is a set mapping duplicate elements to true.
      */
      update_duplicates_set = el: set: let
        is_duplicate = el: hasAttr (toString el);
      in set // { ${toString el} = is_duplicate el set; };
    in compose [
      attrNames                        # return the name only
      (filterAttrs (flip const))       # filter on trueness of the value
      (foldr update_duplicates_set {}) # fold to create the duplicates set
    ];

    # recursiveUpdate merges the two resulting attribute sets recursively
    recursiveMerge = foldr recursiveUpdate {};

    /* A type for host names, host names consist of:
        * a first character which is an upper or lower case ascii character
        * followed by zero or more of: dash (-), upper case ascii, lower case ascii, digit
        * followed by an upper or lower case ascii character or a digit
    */
    host_name_type =
      types.strMatching "^[[:upper:][:lower:]][-[:upper:][:lower:][:digit:]]*[[:upper:][:lower:][:digit:]]$";
    empty_str_type = types.strMatching "^$" // {
      description = "empty string";
    };
    pub_key_type   = let
      key_data_pattern = "[[:lower:][:upper:][:digit:]\\/+]";
      key_patterns     = {
        ssh-ed25519         = "^ssh-ed25519 ${key_data_pattern}{68}$";
        ecdsa-sha2-nistp256 = "^ecdsa-sha2-nistp256 ${key_data_pattern}{139}=$";
        ssh-rsa             = "^ssh-rsa ${key_data_pattern}{372,}={0,2}$";
      };
      pub_key_pattern  = concatStringsSep "|" (attrValues key_patterns);
      description      =
        ''valid ${concatStringsSep " or " (attrNames key_patterns)} key, '' +
        ''meaning a string matching the pattern ${pub_key_pattern}'';
    in types.strMatching pub_key_pattern // { inherit description; };

    ifPathExists = path: optional (builtins.pathExists path) path;

    traceImportJSON = compose [
      (filterAttrsRecursive (k: _: k != "_comment"))
      importJSON
      (traceValFn (f: "Loading file ${toString f}..."))
    ];

    # Compatibility layer around
    # https://nixos.org/manual/nixos/stable/index.html#sec-settings-nix-representable
    # To be deleted when we upgraded all servers to 20.09.
    formats.compat = {
      yaml = const {
        type = types.attrs;
        generate = name: value: pkgs.writeText name (builtins.toJSON value);
      };
    };

    # Prepend a string with a given number of spaces
    # indentStr :: Int -> String -> String
    indentStr = n: str: let
      spacesN = compose [ concatStrings (genList (const " ")) ];
    in (spacesN n) + str;

    reset_git = { url
                , branch
                , git_options
                , indent ? 0 }: let
      git = "${pkgs.git}/bin/git";
      mkOptionsStr = concatStringsSep " ";
      mkGitCommand = git_options: cmd: "${git} ${mkOptionsStr git_options} ${cmd}";
      mkGitCommandIndented = indent: git_options:
        compose [ (indentStr indent) (mkGitCommand git_options) ];
    in concatMapStringsSep "\n" (mkGitCommandIndented indent git_options) [
      ''remote set-url origin "${url}"''
      # The following line is only used to avoid the warning emitted by git.
      # We will reset the local repo anyway and remove all local changes.
      ''config pull.rebase true''
      ''fetch origin ${branch}''
      ''checkout ${branch} --''
      ''reset --hard origin/${branch}''
      ''clean -d --force''
      ''pull''
    ];

    clone_and_reset_git = { config
                          , clone_dir
                          , github_repo
                          , branch
                          , git_options ? []
                          , indent ? 0 }: let
        repo_url = config.settings.system.org.repo_to_url github_repo;
      in optionalString (config != null) ''
        if [ ! -d "${clone_dir}" ] || [ ! -d "${clone_dir}/.git" ]; then
          if [ -d "${clone_dir}" ]; then
            # The directory exists but is not a git clone
            ${pkgs.coreutils}/bin/rm --recursive --force "${clone_dir}"
          fi
          ${pkgs.coreutils}/bin/mkdir --parent "${clone_dir}"
          ${pkgs.git}/bin/git clone "${repo_url}" "${clone_dir}"
        fi
        ${reset_git { inherit branch indent;
                      url = repo_url;
                      git_options = git_options ++ [ "-C" ''"${clone_dir}"'' ]; }}
    '';

    mkDeploymentService = { config
                          , deploy_dir_name
                          , github_repo
                          , git_branch ? "main"
                          , pre-compose_script ? "deploy/pre-compose.sh"
                          , extra_script ? ""
                          , restart ? false
                          , force_build ? false
                          , docker_compose_files ? [ "docker-compose.yml" ] }: let
      secrets_dir = config.settings.system.secrets.dest_directory;
      deploy_dir = "/opt/${deploy_dir_name}";
      pre-compose_script_path = "${deploy_dir}/${pre-compose_script}";
    in {
      serviceConfig.Type = "oneshot";

      # We need to explicitly set the docker runtime dependency
      # since docker-compose does not depend on docker.
      #
      # nix is included so that nix-shell can be used in the external scripts
      # called dynamically by this function
      path = with pkgs; [ nix docker ];

      environment = let
        inherit (config.settings.system) private_key;
        inherit (config.settings.system.org) env_var_prefix;
      in {
        # We need to set the NIX_PATH env var so that we can resolve <nixpkgs>
        # references when using nix-shell.
        inherit (config.environment.sessionVariables) NIX_PATH;
        GIT_SSH_COMMAND = concatStringsSep " " [
          "${pkgs.openssh}/bin/ssh"
          "-F /etc/ssh/ssh_config"
          "-i ${private_key}"
          "-o IdentitiesOnly=yes"
          "-o StrictHostKeyChecking=yes"
        ];
        "${env_var_prefix}_SECRETS_DIRECTORY" = secrets_dir;
        "${env_var_prefix}_DEPLOY_DIR" = deploy_dir;
      };
      script = let
        docker_credentials_file = "${secrets_dir}/docker_private_repo_creds";
      in ''
        ${clone_and_reset_git { inherit config github_repo;
                                clone_dir = deploy_dir;
                                branch = git_branch; }}

        # Login to our private docker repo (hosted on github)
        if [ -f ${docker_credentials_file} ]; then
          # Load private repo variables
          source ${docker_credentials_file}

          echo ''${DOCKER_PRIVATE_REPO_PASS} | \
          ${pkgs.docker}/bin/docker login \
            --username "''${DOCKER_PRIVATE_REPO_USER}" \
            --password-stdin \
            "''${DOCKER_PRIVATE_REPO_URL}"

          docker_login_successful=true
        else
          echo "No docker credentials file found, skipping docker login."
        fi

        if [ -x "${pre-compose_script_path}" ]; then
          "${pre-compose_script_path}"
        else
          echo "Pre-compose script (${pre-compose_script_path}) does not exist or is not executable, skipping."
        fi

        ${extra_script}

        ${pkgs.docker-compose}/bin/docker-compose \
          --project-directory "${deploy_dir}" \
          ${concatMapStringsSep " " (s: ''--file "${deploy_dir}/${s}"'') docker_compose_files} \
          --ansi never \
          ${if restart
            then "restart"
            else ''up --detach --remove-orphans ${optionalString force_build "--build"}''
          }

        if [ "''${docker_login_successful}" = true ]; then
          ${pkgs.docker}/bin/docker logout "''${DOCKER_PRIVATE_REPO_URL}"
        fi
      '';
    };
  in {
    inherit compose applyTwice filterEnabled find_duplicates recursiveMerge
            ifPathExists traceImportJSON
            host_name_type empty_str_type pub_key_type
            user_roles formats
            indentStr reset_git clone_and_reset_git mkDeploymentService;
  };
}

