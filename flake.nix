{
  description = "soft-narrow - Emacs package to imitate narrow-to-region with more eye-candy";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      eachSystem =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          let
            pkgs = nixpkgs.legacyPackages.${system};
            emacs = pkgs.emacs;
            emacsWithPkgLint = (pkgs.emacsPackagesFor emacs).emacsWithPackages (epkgs: [
              epkgs.package-lint
            ]);
          in
          f { inherit pkgs emacs emacsWithPkgLint; }
        );
    in
    {
      devShells = eachSystem (
        { pkgs, emacsWithPkgLint, ... }: {
          default = pkgs.mkShell {
            packages = [
              emacsWithPkgLint
            ];

            shellHook = ''
              echo "soft-narrow development environment loaded"
              echo "  emacs: $(emacs --version | head -1)"
              echo ""
              echo "=== Automated checks ==="
              echo "  make compile            Byte-compile with warnings as errors"
              echo "  make test               Run ERT test suite"
              echo "  make lint               Run checkdoc"
              echo "  make package-lint       Run package-lint"
              echo "  nix run .#compile       Byte-compile (standalone)"
              echo "  nix run .#test          Run tests (standalone)"
              echo "  nix run .#lint          Run checkdoc (standalone)"
              echo "  nix run .#package-lint  Run package-lint (standalone)"
              echo "  nix flake check         Run all checks (sandboxed)"
              echo ""
              echo "=== Manual testing ==="
              echo "  emacs -Q -L . -l soft-narrow-autoloads --eval '(soft-narrow-mode 1)' example/sample.el"
              echo "    1. C-x n d         Narrow to defun at point"
              echo "    2. C-x n w         Widen back"
              echo "    3. Select region -> C-x n n  Narrow to region"
              echo "    4. C-x n w         Widen back"
              echo ""
              echo "  emacs -Q -L . -l soft-narrow-autoloads --eval '(soft-narrow-mode 1)' example/sample.org"
              echo "    1. C-x n s         Narrow to org subtree"
              echo "    2. C-x n e         Narrow to org element"
              echo "    3. C-x n b         Narrow to org block (inside src block)"
              echo "    4. C-x n w         Widen (stackable, repeat to fully widen)"
              echo ""
            '';
          };
        }
      );

      apps = eachSystem (
        {
          pkgs,
          emacs,
          emacsWithPkgLint,
        }:
        let
          make = "${pkgs.gnumake}/bin/make";
          mkApp = emacsPkg: target: {
            type = "app";
            program = toString (
              pkgs.writeShellScript "soft-narrow-${target}" ''
                EMACS=${pkgs.lib.getExe emacsPkg} ${make} ${target}
              ''
            );
            meta.description = "Run the soft-narrow ${target} check";
          };
        in
        {
          compile = mkApp emacs "compile";
          test = mkApp emacs "test";
          lint = mkApp emacs "lint";
          package-lint = mkApp emacsWithPkgLint "package-lint";
        }
      );

      checks = eachSystem (
        {
          pkgs,
          emacs,
          emacsWithPkgLint,
        }:
        let
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
        }
      );
    };
}
