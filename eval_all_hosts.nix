# This file can be used with nix-eval-jobs to evaluate all hosts.

{ nixpkgs ? import <nixpkgs> { }
, eval_nixos ? import <nixpkgs/nixos>
}:

with nixpkgs.lib;

let
  to_host_path = hostname:
    ./org-config/hosts/${hostname} + ".nix";

  build_host = hostname:
    # This call is the equivalent of
    #   nix-build <nixpkgs/nixos> -A config.system.build.toplevel -I nixos-config=<...>
    # with the <...> set to the result of the call to eval_host.nix below.
    (eval_nixos {
      configuration =
        import ./eval_host.nix { host_path = to_host_path hostname; };
    }).config.system.build.toplevel;

  hosts =
    map (removeSuffix ".nix")
      (attrNames
        (filterAttrs (name: type: type == "regular" && hasSuffix ".nix" name)
          (builtins.readDir ./org-config/hosts)));
in
genAttrs hosts build_host

