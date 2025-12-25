{
  description = "ChainBridge - Reproducible Nix Build";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = { allowUnfree = true; };
        };

        version = "1.1.5";
        go = pkgs.go_1_24;

        chainbridge = pkgs.buildGoModule.override { go = go; } {
          pname = "chainbridge";
          inherit version;
          src = ./.;

          vendorHash = "sha256-rhGsyu0qfwxv20iKGXrGA1fEC70CpYq+i830IOLi/ak=";

          subPackages = ["./cmd/chainbridge"];

          ldflags = [
            "-X main.Version=${version}"
          ];

          doCheck = false;

          meta = with pkgs.lib; {
            description = "ChainBridge multi-directional blockchain bridge";
            homepage = "https://github.com/ChainSafe/ChainBridge";
            license = licenses.lgpl3;
            mainProgram = "chainbridge";
          };
        };

        dockerImage = pkgs.dockerTools.buildImage {
          name = "chainbridge";
          tag = version;
          copyToRoot = pkgs.buildEnv {
            name = "chainbridge-root";
            paths = [ chainbridge pkgs.cacert ];
            pathsToLink = ["/bin" "/etc"];
          };
          config = {
            Entrypoint = ["${chainbridge}/bin/chainbridge"];
            Env = [ "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" ];
          };
        };

        testScript = pkgs.writeShellScriptBin "run-tests" ''
          set -e
          export GOPATH="$HOME/go"
          export GOCACHE="$HOME/.cache/go-build"
          echo "Running ChainBridge unit tests..."
          cd ${./.}
          ${go}/bin/go test -v ./... 2>&1 | head -200 || true
        '';

        testArtifactScript = pkgs.writeShellScriptBin "test-artifact" ''
          set -e
          BINARY="${chainbridge}/bin/chainbridge"
          echo "Testing ChainBridge artifact: $BINARY"
          echo "========================================"
          echo ""
          echo "1. Binary exists and is executable:"
          ls -la "$BINARY"
          echo ""
          echo "2. Version check:"
          "$BINARY" --help 2>&1 | head -20 || true
          echo ""
          echo "3. Binary file info:"
          ${pkgs.file}/bin/file "$BINARY"
          echo ""
          echo "Artifact tests completed!"
        '';

        verifySignatureScript = pkgs.writeShellScriptBin "verify-signature" ''
          set -e
          echo "Verifying Git commit signature..."
          if [ ! -e ".git" ]; then
            echo "ERROR: Not a git repository! Run this from the project directory."
            exit 1
          fi
          echo "Importing ChainSafe GPG keys..."
          ${pkgs.curl}/bin/curl -sfL https://github.com/ChainSafe.gpg | ${pkgs.gnupg}/bin/gpg --import 2>/dev/null || true
          COMMIT=$(${pkgs.git}/bin/git rev-parse HEAD)
          echo "Commit: $COMMIT"
          ${pkgs.git}/bin/git verify-commit HEAD 2>&1 || { echo "Signature verification failed!"; exit 1; }
          echo "Commit signature is VALID!"
        '';

        generateSbomScript = pkgs.writeShellScriptBin "generate-sbom" ''
          set -e
          echo "Generating SBOM for ChainBridge..."
          echo "==================================="
          OUTDIR="''${1:-.}"
          BINARY="${chainbridge}/bin/chainbridge"
          echo ""
          echo "Scanning binary: $BINARY"
          ${pkgs.syft}/bin/syft "$BINARY" -o spdx-json="$OUTDIR/chainbridge-sbom.spdx.json"
          ${pkgs.syft}/bin/syft "$BINARY" -o cyclonedx-json="$OUTDIR/chainbridge-sbom.cdx.json"
          echo ""
          echo "Also scanning Go modules..."
          ${pkgs.syft}/bin/syft dir:${./.} -o spdx-json="$OUTDIR/chainbridge-source-sbom.spdx.json"
          echo ""
          echo "SBOMs generated:"
          ls -la "$OUTDIR"/*-sbom*.json
        '';

        scanVulnsScript = pkgs.writeShellScriptBin "scan-vulns" ''
          set -e
          echo "Scanning ChainBridge for vulnerabilities..."
          echo "============================================"
          echo ""
          echo "1. Scanning binary with grype..."
          BINARY="${chainbridge}/bin/chainbridge"
          ${pkgs.grype}/bin/grype "$BINARY" 2>&1 | head -50 || true
          echo ""
          echo "2. Scanning Go modules with govulncheck..."
          cd ${./.}
          export GOPATH="$HOME/go"
          export GOCACHE="$HOME/.cache/go-build"
          ${pkgs.govulncheck}/bin/govulncheck ./... 2>&1 | head -100 || true
        '';

      in {
        packages = {
          default = chainbridge;
          inherit chainbridge dockerImage;
          run-tests = testScript;
          test-artifact = testArtifactScript;
          verify-signature = verifySignatureScript;
          generate-sbom = generateSbomScript;
          scan-vulns = scanVulnsScript;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [ go pkgs.git pkgs.jq pkgs.curl pkgs.gnupg pkgs.syft pkgs.grype pkgs.govulncheck ];
          shellHook = ''
            echo "ChainBridge Development Shell"
            echo "Go: $(go version)"
          '';
        };

        apps = {
          default = { type = "app"; program = "${chainbridge}/bin/chainbridge"; };
          run-tests = { type = "app"; program = "${testScript}/bin/run-tests"; };
          test-artifact = { type = "app"; program = "${testArtifactScript}/bin/test-artifact"; };
          verify-signature = { type = "app"; program = "${verifySignatureScript}/bin/verify-signature"; };
          generate-sbom = { type = "app"; program = "${generateSbomScript}/bin/generate-sbom"; };
          scan-vulns = { type = "app"; program = "${scanVulnsScript}/bin/scan-vulns"; };
        };
      }
    );
}
