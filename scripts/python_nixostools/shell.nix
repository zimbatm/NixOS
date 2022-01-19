{ pkgs ? import <nixpkgs> {}
, doCheck ? true
}:

pkgs.mkShell {
  nativeBuildInputs =
    let scripts_pkg = pkgs.callPackage ./default.nix { inherit doCheck; };
    in [ scripts_pkg ];
}

