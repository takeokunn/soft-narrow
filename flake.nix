{
  description = "soft-narrow - Emacs package to imitate narrow-to-region with more eye-candy";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      eachSystem = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = eachSystem (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.emacs
          ];

          shellHook = ''
            echo "soft-narrow development environment loaded"
            echo "  emacs: $(emacs --version | head -1)"
            echo ""
            echo "Available commands:"
            echo "  make compile       Byte-compile all source files"
            echo "  make test          Run ERT tests"
            echo "  make lint          Run checkdoc"
            echo "  make package-lint  Run package-lint"
            echo "  nix flake check    Run all checks"
            echo ""
          '';
        };
      });

      checks = eachSystem (pkgs:
        let
          emacs = pkgs.emacs;
          emacsWithPkgLint = (pkgs.emacsPackagesFor emacs).emacsWithPackages (epkgs: [
            epkgs.package-lint
          ]);
          src = pkgs.lib.cleanSource ./.;
        in
        {
          compile = pkgs.stdenvNoCC.mkDerivation {
            name = "soft-narrow-compile";
            inherit src;
            nativeBuildInputs = [ emacs ];
            env.EMACS = pkgs.lib.getExe emacs;
            buildPhase = ''
              make compile
            '';
            installPhase = ''
              touch $out
            '';
          };

          test = pkgs.stdenvNoCC.mkDerivation {
            name = "soft-narrow-test";
            inherit src;
            nativeBuildInputs = [ emacs ];
            env.EMACS = pkgs.lib.getExe emacs;
            buildPhase = ''
              make test
            '';
            installPhase = ''
              touch $out
            '';
          };

          lint = pkgs.stdenvNoCC.mkDerivation {
            name = "soft-narrow-lint";
            inherit src;
            nativeBuildInputs = [ emacs ];
            env.EMACS = pkgs.lib.getExe emacs;
            buildPhase = ''
              make lint
            '';
            installPhase = ''
              touch $out
            '';
          };

          package-lint = pkgs.stdenvNoCC.mkDerivation {
            name = "soft-narrow-package-lint";
            inherit src;
            nativeBuildInputs = [ emacsWithPkgLint ];
            env.EMACS = pkgs.lib.getExe emacsWithPkgLint;
            buildPhase = ''
              make package-lint
            '';
            installPhase = ''
              touch $out
            '';
          };
        });
    };
}
