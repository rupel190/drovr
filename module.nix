{
  pkgs,
  lib,
  inputs,
  config,
  ...
}:
let
  cfg = config.my.claude.workers;
  claude = inputs.claude-code.packages.${pkgs.stdenv.hostPlatform.system}.default;

  # Claude Code against DeepSeek's Anthropic-compatible endpoint. The key is read
  # at launch from agenix (modules/core/secrets.nix), never baked into the store.
  claude-ds = pkgs.writeShellApplication {
    name = "claude-ds";
    text = ''
      key=/run/agenix/deepseek-api-key
      [ -r "$key" ] || {
        echo "claude-ds: $key not readable (ragenix -e secrets/deepseek-api-key.age, then rebuild)" >&2
        exit 1
      }
      ANTHROPIC_AUTH_TOKEN="$(<"$key")"
      export ANTHROPIC_AUTH_TOKEN
      export ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic
      export ANTHROPIC_MODEL=deepseek-v4-pro
      export CLAUDE_WORKER=1
      exec ${claude}/bin/claude "$@"
    '';
  };

  cw = pkgs.writeShellApplication {
    name = "cw";
    runtimeInputs = [
      claude-ds
      pkgs.jq
      pkgs.git
      pkgs.coreutils
      pkgs.util-linux # setsid
    ];
    text = ''
      CW_ALLOWED=${lib.escapeShellArg (lib.concatLines cfg.allowedRepos)}
    ''
    + builtins.readFile ./claude-workers/cw.sh;
  };
in
{
  # Default-deny: everything a worker reads is sent to DeepSeek. List repos here.
  options.my.claude.workers.allowedRepos = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Repo roots (and everything under them) where `cw` may start DeepSeek workers.";
  };

  config.home.packages = [
    claude-ds
    cw
  ];

  # claude-sync excludes this path: the store symlink must not reach cordyceps.
  config.home.file.".claude/skills/claude-workers/SKILL.md".source = ./claude-workers/SKILL.md;
}
