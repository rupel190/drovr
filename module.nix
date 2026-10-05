# drovr — hand tasks from your Claude session to headless Claude Code workers on
# cheaper Anthropic-compatible backends. Each editing worker gets its own git
# worktree; a repo must be allowlisted and carry a DROVR.md, or the worker gets
# only a prepared scratch folder. The answer comes back as one message.
{
  pkgs,
  lib,
  inputs,
  config,
  ...
}:
let
  cfg = config.my.claude.drovr;
  claude = inputs.claude-code.packages.${pkgs.stdenv.hostPlatform.system}.default;

  # One `claude-<name>` per provider: Claude Code pointed at that endpoint. Keys
  # are read at launch from agenix (modules/core/secrets.nix), never baked in.
  mkWrapper =
    name: p:
    pkgs.writeShellApplication {
      name = "claude-${name}";
      text = ''
        key=/run/agenix/${p.secret}
        [ -r "$key" ] || {
          echo "claude-${name}: $key not readable (ragenix -e secrets/${p.secret}.age, then rebuild)" >&2
          exit 1
        }
        ${p.authVar}="$(<"$key")"
        export ${p.authVar}
        export ANTHROPIC_BASE_URL=${lib.escapeShellArg p.baseUrl}
        export ANTHROPIC_MODEL=${lib.escapeShellArg p.model}
        ${lib.optionalString (p.smallModel != null) ''
          export ANTHROPIC_DEFAULT_HAIKU_MODEL=${lib.escapeShellArg p.smallModel}
        ''}
        export CLAUDE_WORKER=1
        exec ${claude}/bin/claude "$@"
      '';
    };

  wrappers = lib.mapAttrsToList mkWrapper cfg.providers;

  drovr = pkgs.writeShellApplication {
    name = "drovr";
    runtimeInputs = wrappers ++ [
      pkgs.jq
      pkgs.git
      pkgs.coreutils
      pkgs.gnused
      pkgs.util-linux # setsid
    ];
    text = ''
      DROVR_ALLOWED=${lib.escapeShellArg (lib.concatLines cfg.allowedRepos)}
      DROVR_PROVIDERS=${lib.escapeShellArg (lib.concatStringsSep " " (lib.attrNames cfg.providers))}
      DROVR_DEFAULT=${lib.escapeShellArg cfg.defaultProvider}
    ''
    + builtins.readFile ./drovr/drovr.sh;
  };

  provider = lib.types.submodule {
    options = {
      baseUrl = lib.mkOption {
        type = lib.types.str;
        description = "Anthropic-compatible endpoint (ANTHROPIC_BASE_URL).";
      };
      model = lib.mkOption {
        type = lib.types.str;
        description = "Main model id (ANTHROPIC_MODEL).";
      };
      smallModel = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Background-task model (ANTHROPIC_DEFAULT_HAIKU_MODEL); null keeps the endpoint's own mapping.";
      };
      secret = lib.mkOption {
        type = lib.types.str;
        description = "agenix secret name; read from /run/agenix/<secret>.";
      };
      authVar = lib.mkOption {
        type = lib.types.str;
        default = "ANTHROPIC_AUTH_TOKEN";
        description = "Variable the key goes into (ANTHROPIC_AUTH_TOKEN sends a Bearer header, ANTHROPIC_API_KEY sends x-api-key).";
      };
    };
  };
in
{
  options.my.claude.drovr = {
    # Default-deny: everything a worker reads is sent to its provider.
    allowedRepos = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Repo roots (and everything under them) where drovr may start workers.";
    };

    providers = lib.mkOption {
      type = lib.types.attrsOf provider;
      default = { };
      description = "Anthropic-compatible backends; each becomes a claude-<name> wrapper.";
    };

    defaultProvider = lib.mkOption {
      type = lib.types.str;
      default = "deepseek";
    };
  };

  config = {
    # DeepSeek maps claude-opus to v4-pro and haiku/sonnet to flash on its side,
    # so background calls need no smallModel.
    my.claude.drovr.providers.deepseek = {
      baseUrl = "https://api.deepseek.com/anthropic";
      model = "deepseek-v4-pro";
      secret = "deepseek-api-key";
    };

    assertions = [
      {
        assertion = cfg.providers ? ${cfg.defaultProvider};
        message = "my.claude.drovr.defaultProvider '${cfg.defaultProvider}' is not in my.claude.drovr.providers";
      }
    ];

    home.packages = wrappers ++ [ drovr ];

    # claude-sync excludes this path: the store symlink must not reach cordyceps.
    home.file.".claude/skills/drovr/SKILL.md".source = ./drovr/SKILL.md;
  };
}
